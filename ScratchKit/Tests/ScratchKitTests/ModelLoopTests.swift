import CoreGraphics
import Foundation
import Testing
@testable import ScratchKit

/// A model that records when it is called and answers from a script.
private actor ScriptedModel: DiagramModel {
    private(set) var calls = 0
    private var script: [Result<ModelOutput, ModelError>]
    private let latency: Duration

    init(_ script: [Result<ModelOutput, ModelError>] = [], latency: Duration = .milliseconds(20)) {
        self.script = script
        self.latency = latency
    }

    func edit(_ input: ModelInput) async throws -> ModelOutput {
        calls += 1
        try await Task.sleep(for: latency)
        let next = script.isEmpty ? .success(ModelOutput(ops: [])) : script.removeFirst()
        return try next.get()
    }
}

@MainActor
private final class Harness {
    let loop = ModelLoop()
    let model: ScriptedModel
    var completions = 0
    var hasInk = true

    init(_ model: ScriptedModel = ScriptedModel(), settle: Duration = .milliseconds(30)) {
        self.model = model
        loop.timing = { ModelLoop.Timing(settle: settle) }
        loop.makeModel = { model }
        loop.capture = { [unowned self] in
            guard hasInk else { return nil }
            let input = ModelInput(imagePNG: Data(), imageSize: CGSize(width: 10, height: 10), diagram: Diagram())
            return ModelLoop.Job(input: input) { _ in self.completions += 1 }
        }
    }

    /// Waits until the loop has gone quiet, or fails after a second.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(5))
            if loop.phase == .idle || loop.phase == .off { return }
        }
        Issue.record("Loop never settled; phase is \(loop.phase)", sourceLocation: sourceLocation)
    }
}

@MainActor
@Suite struct ModelLoopScheduling {
    @Test func staysQuietUntilSwitchedOn() async throws {
        let h = Harness()
        h.loop.noteChange()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await h.model.calls == 0)
        #expect(h.loop.phase == .off)
    }

    @Test func switchingOnLooksAtWhatIsAlreadyThere() async {
        let h = Harness()
        h.loop.setEnabled(true)
        #expect(h.loop.phase == .waiting)
        await h.settle()
        #expect(await h.model.calls == 1)
        #expect(h.completions == 1)
        #expect(h.loop.lastLatency != nil)
        #expect(h.loop.lastEditCount == 0)
    }

    @Test func aBurstOfStrokesBecomesOnePass() async throws {
        let h = Harness(settle: .milliseconds(60))
        h.loop.setEnabled(true)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(15))
            h.loop.noteChange()
        }
        await h.settle()
        #expect(await h.model.calls == 1)
    }

    @Test func waitsWhileThePencilIsDown() async throws {
        let h = Harness()
        h.loop.setEnabled(true)
        h.loop.penDown()
        try await Task.sleep(for: .milliseconds(120))
        #expect(await h.model.calls == 0)
        #expect(h.loop.phase == .waiting)

        h.loop.penUp()
        await h.settle()
        #expect(await h.model.calls == 1)
    }

    @Test func aChangeDuringAPassTriggersAnother() async throws {
        let h = Harness(ScriptedModel(latency: .milliseconds(80)))
        h.loop.setEnabled(true)
        try await Task.sleep(for: .milliseconds(60)) // the first pass is now in flight
        #expect(h.loop.phase == .running)
        h.loop.noteChange()
        await h.settle()
        #expect(await h.model.calls == 2)
        #expect(h.completions == 2)
    }

    @Test func sendsNothingWhenThereIsNothingToSee() async {
        let h = Harness()
        h.hasInk = false
        h.loop.setEnabled(true)
        await h.settle()
        #expect(await h.model.calls == 0)
    }

    @Test func discardsAnAnswerThatArrivesAfterSwitchingOff() async throws {
        let h = Harness(ScriptedModel(latency: .milliseconds(80)))
        h.loop.setEnabled(true)
        try await Task.sleep(for: .milliseconds(60))
        h.loop.setEnabled(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await h.model.calls == 1)
        #expect(h.completions == 0)
        #expect(h.loop.phase == .off)
    }
}

@MainActor
@Suite struct ModelLoopFailures {
    @Test func asksForSetupWhenThereIsNoModel() async throws {
        let h = Harness()
        h.loop.makeModel = { nil }
        h.loop.setEnabled(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.loop.needsSetup)

        // Once a model is configured, the pending pass runs without a new stroke.
        h.loop.makeModel = { [model = h.model] in model }
        h.loop.retry()
        await h.settle()
        #expect(!h.loop.needsSetup)
        #expect(await h.model.calls == 1)
    }

    @Test func retriesAnOutageWithTheSameSnapshot() async {
        let h = Harness(ScriptedModel([
            .failure(.unavailable(message: "Overloaded", retryAfter: nil)),
            .success(ModelOutput(ops: [.delete(id: "n1")])),
        ]))
        h.loop.setEnabled(true)
        // The retry waits out a one-second backoff.
        for _ in 0..<400 where h.completions == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.model.calls == 2)
        #expect(h.completions == 1)
        #expect(h.loop.lastError == nil)
        #expect(h.loop.lastEditCount == 1)
    }

    @Test func switchesOffWhenTheKeyIsRejected() async {
        let h = Harness(ScriptedModel([.failure(.unauthorized("invalid x-api-key"))]))
        h.loop.setEnabled(true)
        await h.settle()
        #expect(!h.loop.isEnabled)
        #expect(h.loop.phase == .off)
        #expect(h.loop.lastError?.contains("invalid x-api-key") == true)
        #expect(h.completions == 0)
    }

    @Test func doesNotRetryARefusal() async throws {
        let h = Harness(ScriptedModel([.failure(.refused(category: nil))]))
        h.loop.setEnabled(true)
        await h.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await h.model.calls == 1)
        #expect(h.loop.isEnabled)
        #expect(h.loop.lastError != nil)
    }
}
