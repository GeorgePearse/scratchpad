import Foundation
import Observation
import PencilKit
import ScratchKit
import UIKit

/// The store's handle on the live ink, which is owned by the PKCanvasView.
@MainActor
protocol InkSurface: AnyObject {
    var drawing: PKDrawing { get set }
}

/// Everything on the pad: the clean diagram, the ink, undo history, and the model loop that edits them.
@MainActor
@Observable
final class PadStore {
    enum Tool {
        case pen, eraser
    }

    private(set) var diagram = Diagram()
    private(set) var strokeCount = 0
    private(set) var canUndo = false
    var tool: Tool = .pen {
        didSet { Trace.log("tool is now \(tool)") }
    }
    /// Stands in for the configured Claude model. The demo and the UI tests set this.
    var modelOverride: (any DiagramModel)?

    let settings = PadSettings()
    let loop = ModelLoop()

    /// Size of the canvas in points. Set by the canvas view as it lays out.
    @ObservationIgnored var canvasSize: CGSize = .zero
    /// The canvas view, once it exists. Until then the store's own copy of the ink stands in.
    @ObservationIgnored weak var ink: (any InkSurface)? {
        didSet { ink?.drawing = drawing }
    }
    /// Off in the scripted demo, so it never overwrites a real pad.
    @ObservationIgnored var persists = true

    @ObservationIgnored private var drawing = PKDrawing()
    @ObservationIgnored private var history: [(diagram: Diagram, drawing: PKDrawing)] = []
    @ObservationIgnored private var penIsDown = false
    @ObservationIgnored private var eraseIsRecorded = false
    @ObservationIgnored private var deferredWork: [() -> Void] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var isBlank: Bool { diagram.isEmpty && strokeCount == 0 }

    /// True when the loop has nothing to run on until the user supplies a key.
    var needsAPIKey: Bool { modelOverride == nil && settings.apiKey.isEmpty }

    /// What is on the canvas, in words. This is the canvas's accessibility value.
    var summary: String {
        guard !isBlank else { return "Empty" }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [
            count(diagram.nodes.count, "shape"),
            count(diagram.edges.count, "connector"),
            count(strokeCount, "ink stroke"),
        ].joined(separator: ", ")
    }

    init() {
        load()
        loop.timing = { [settings] in
            ModelLoop.Timing(settle: .seconds(settings.settleSeconds))
        }
        loop.makeModel = { [weak self, settings] in
            if let override = self?.modelOverride { return override }
            guard !settings.apiKey.isEmpty else { return nil }
            return ClaudeModel(apiKey: settings.apiKey, model: settings.modelID, effort: settings.effort)
        }
        loop.capture = { [weak self] in self?.makeJob() }
        // Ink left over from last time has already been looked at, so wait for a fresh stroke.
        loop.setEnabled(settings.loopEnabled, lookNow: false)
    }

    func setLoopEnabled(_ enabled: Bool) {
        settings.loopEnabled = enabled
        loop.setEnabled(enabled)
    }

    // MARK: Ink, as changed by the user

    /// The canvas reports a new drawing. Echoes of our own programmatic changes are ignored.
    func canvasInkChanged(_ new: PKDrawing) {
        guard new != drawing else { return }
        Trace.log("ink changed: \(drawing.strokes.count) -> \(new.strokes.count) strokes")
        pushHistory()
        drawing = new
        strokeCount = new.strokes.count
        loop.noteChange()
        scheduleSave()
    }

    func penDown() {
        Trace.log("tool down (\(tool))")
        penIsDown = true
        loop.penDown()
    }

    func penUp() {
        Trace.log("tool up")
        penIsDown = false
        loop.penUp()
        // PencilKit commits the finished stroke just after this callback; let it land before touching the ink.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            flushDeferredWork()
        }
    }

    // MARK: Direct manipulation

    /// Starts dragging the node under `point`, if there is one.
    func beginMove(at point: CGPoint) -> String? {
        guard let node = diagram.node(at: point, slop: 10) else { return nil }
        pushHistory()
        return node.id
    }

    func move(_ id: String, by delta: CGPoint) {
        guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { return }
        var frame = diagram.nodes[index].frame.offsetBy(dx: delta.x, dy: delta.y)
        // Keep the centre on the canvas, so a node can't be dragged out of reach.
        if canvasSize != .zero {
            frame.origin.x = min(max(frame.origin.x, -frame.width / 2), canvasSize.width - frame.width / 2)
            frame.origin.y = min(max(frame.origin.y, -frame.height / 2), canvasSize.height - frame.height / 2)
        }
        diagram.nodes[index].frame = frame
    }

    func endMove() {
        scheduleSave()
    }

    // MARK: Erasing clean elements

    /// The eraser has touched down. PencilKit removes the ink it crosses; this handles shapes.
    func beginErasing() {
        eraseIsRecorded = false
    }

    /// Removes the shape or connector whose line is under the eraser at `point`.
    func erase(at point: CGPoint) {
        guard let id = diagram.elementID(touchedAt: point, tolerance: 14) else { return }
        Trace.log("eraser removed \(id)")
        // One undo step per sweep of the eraser, however many things it takes out.
        if !eraseIsRecorded {
            pushHistory()
            eraseIsRecorded = true
        }
        diagram.remove(id)
        scheduleSave()
    }

    // MARK: Whole-pad actions

    func undo() {
        guard let previous = history.popLast() else { return }
        canUndo = !history.isEmpty
        diagram = previous.diagram
        setDrawing(previous.drawing)
        scheduleSave()
    }

    func clear() {
        guard !isBlank else { return }
        pushHistory()
        diagram = Diagram()
        setDrawing(PKDrawing())
        scheduleSave()
    }

    /// Adds strokes as though the user had just drawn them. Used by the scripted demo.
    func userDrew(_ strokes: [PKStroke]) {
        pushHistory()
        var drawing = currentDrawing()
        drawing.strokes.append(contentsOf: strokes)
        setDrawing(drawing)
        loop.noteChange()
    }

    // MARK: Model passes

    private func makeJob() -> ModelLoop.Job? {
        let drawing = currentDrawing()
        // Ink is how the user addresses the model, so with no ink there is nothing to answer.
        guard !drawing.strokes.isEmpty,
              let snapshot = CanvasSnapshot.make(diagram: diagram, drawing: drawing, canvasSize: canvasSize) else { return nil }

        // What the model is answering. By the time it replies, the canvas may have moved on.
        let base = diagram
        let strokesSeen = Set(drawing.strokes.map(\.path.creationDate))

        let input = ModelInput(
            imagePNG: snapshot.png,
            imageSize: snapshot.pixelSize,
            diagram: diagram.scaled(by: snapshot.scale),
            instructions: settings.instructions
        )
        return ModelLoop.Job(input: input) { [weak self] output in
            guard let self else { return }
            let ops = output.ops.map { $0.scaled(by: 1 / snapshot.scale) }
            whenPenIsUp { self.apply(ops, base: base, strokesSeen: strokesSeen) }
        }
    }

    private func apply(_ ops: [EditOp], base: Diagram, strokesSeen: Set<Date>) {
        let result = diagram.merging(ops, base: base)
        Trace.log("model replied with \(ops.count) ops, \(result.appliedCount) applied")

        var drawing = currentDrawing()
        let strokeCount = drawing.strokes.count
        if !result.eraseRegions.isEmpty {
            // Only strokes the model actually saw can be erased; anything drawn since is safe.
            drawing.strokes.removeAll { stroke in
                strokesSeen.contains(stroke.path.creationDate)
                    && InkErasure.covers(strokeBounds: stroke.renderBounds, regions: result.eraseRegions)
            }
        }
        let inkChanged = drawing.strokes.count != strokeCount
        guard inkChanged || result.diagram != diagram else { return }

        pushHistory()
        diagram = result.diagram
        if inkChanged { setDrawing(drawing) }
        scheduleSave()
    }

    /// Changing the canvas's drawing mid-stroke would fight PencilKit, so edits wait for the pencil to lift.
    private func whenPenIsUp(_ work: @escaping () -> Void) {
        if penIsDown {
            deferredWork.append(work)
        } else {
            work()
        }
    }

    private func flushDeferredWork() {
        guard !penIsDown, !deferredWork.isEmpty else { return }
        let work = deferredWork
        deferredWork = []
        work.forEach { $0() }
    }

    // MARK: Ink plumbing

    private func currentDrawing() -> PKDrawing {
        ink?.drawing ?? drawing
    }

    private func setDrawing(_ new: PKDrawing) {
        drawing = new
        strokeCount = new.strokes.count
        ink?.drawing = new
    }

    /// Records the state before a change. This must be the store's own copy of the ink, not the
    /// canvas's: when the canvas reports a new stroke, its drawing already contains that stroke.
    private func pushHistory() {
        history.append((diagram, drawing))
        if history.count > 200 { history.removeFirst(history.count - 200) }
        canUndo = true
    }

    // MARK: Persistence

    private struct SavedPad: Codable {
        var diagram: Diagram
        var drawing: Data
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "pad.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode(SavedPad.self, from: data) else { return }
        diagram = saved.diagram
        drawing = (try? PKDrawing(data: saved.drawing)) ?? PKDrawing()
        strokeCount = drawing.strokes.count
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard persists else { return }
        let saved = SavedPad(diagram: diagram, drawing: currentDrawing().dataRepresentation())
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
