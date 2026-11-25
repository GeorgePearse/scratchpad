import Foundation
import Observation

/// Decides when a model gets to look at the canvas.
///
/// The loop is change-driven: it runs a pass only after the user has changed something, never on a
/// timer, so an idle canvas costs nothing. One pass is in flight at a time. Changes that arrive during
/// a pass are not lost and do not cancel it; they trigger the next pass as soon as this one lands.
@MainActor
@Observable
public final class ModelLoop {
    public enum Phase: Equatable, Sendable {
        /// Switched off.
        case off
        /// On, with nothing new to look at.
        case idle
        /// A change is waiting for the pencil to lift and the settle time to pass.
        case waiting
        /// A pass is in flight.
        case running
    }

    public struct Timing: Equatable, Sendable {
        /// How long the canvas must be quiet after a change before a pass starts.
        public var settle: Duration
        /// The least time between the starts of two passes.
        public var minimumInterval: Duration

        public init(settle: Duration = .milliseconds(500), minimumInterval: Duration = .zero) {
            self.settle = settle
            self.minimumInterval = minimumInterval
        }
    }

    /// One pass: what to send, and what to do with the answer.
    public struct Job {
        public var input: ModelInput
        public var complete: @MainActor (ModelOutput) -> Void

        public init(input: ModelInput, complete: @escaping @MainActor (ModelOutput) -> Void) {
            self.input = input
            self.complete = complete
        }
    }

    public private(set) var phase: Phase = .off
    public private(set) var isEnabled = false
    /// True when a pass was due but `makeModel` had nothing to offer (no API key yet).
    public private(set) var needsSetup = false
    public private(set) var lastError: String?
    public private(set) var lastLatency: Duration?
    public private(set) var lastEditCount: Int?
    public private(set) var runCount = 0

    /// Read before every pass, so changes take effect immediately.
    @ObservationIgnored public var timing: @MainActor () -> Timing = { Timing() }
    /// The model to use for the next pass, or nil if none is configured.
    @ObservationIgnored public var makeModel: @MainActor () -> (any DiagramModel)? = { nil }
    /// Captures the canvas for a pass, or nil if there is nothing worth sending.
    @ObservationIgnored public var capture: @MainActor () -> Job? = { nil }

    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var penIsDown = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastChange: ContinuousClock.Instant
    @ObservationIgnored private var lastStart: ContinuousClock.Instant?
    @ObservationIgnored private var notBefore: ContinuousClock.Instant?
    @ObservationIgnored private var backoff: Duration = .zero
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init() {
        lastChange = clock.now
    }

    // MARK: Inputs

    /// - Parameter lookNow: Whether switching on should run a pass over what is already on the canvas,
    ///   rather than wait for the next change.
    public func setEnabled(_ enabled: Bool, lookNow: Bool = true) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            if lookNow {
                dirty = true
                lastChange = clock.now
            }
            clearFailure()
        }
        reschedule()
    }

    /// The user changed something the model should see.
    public func noteChange() {
        dirty = true
        lastChange = clock.now
        reschedule()
    }

    public func penDown() {
        penIsDown = true
        reschedule()
    }

    public func penUp() {
        penIsDown = false
        if dirty { lastChange = clock.now }
        reschedule()
    }

    /// Forget any failure and try again now. Call after the configuration changes.
    public func retry() {
        clearFailure()
        reschedule()
    }

    private func clearFailure() {
        lastError = nil
        needsSetup = false
        backoff = .zero
        notBefore = nil
    }

    // MARK: Scheduling

    private func reschedule() {
        timer?.cancel()
        timer = nil

        guard isEnabled else { phase = .off; return }
        guard !inFlight else { phase = .running; return }
        guard dirty else { phase = .idle; return }
        phase = .waiting
        guard !penIsDown else { return }

        let timing = timing()
        var fireAt = lastChange.advanced(by: timing.settle)
        if let lastStart { fireAt = max(fireAt, lastStart.advanced(by: timing.minimumInterval)) }
        if let notBefore { fireAt = max(fireAt, notBefore) }

        timer = Task { [weak self, clock] in
            try? await clock.sleep(until: fireAt, tolerance: .zero)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        guard isEnabled, dirty, !inFlight, !penIsDown else { return }

        guard let model = makeModel() else {
            // Stay dirty, so the pass runs as soon as `retry()` says a model is available.
            needsSetup = true
            return
        }
        needsSetup = false

        guard let job = capture() else {
            dirty = false
            phase = .idle
            return
        }

        dirty = false
        inFlight = true
        phase = .running
        let started = clock.now
        lastStart = started

        Task { [weak self] in
            let outcome: Result<ModelOutput, any Error>
            do {
                outcome = .success(try await model.edit(job.input))
            } catch {
                outcome = .failure(error)
            }
            self?.finish(outcome, job: job, started: started)
        }
    }

    private func finish(_ outcome: Result<ModelOutput, any Error>, job: Job, started: ContinuousClock.Instant) {
        inFlight = false

        switch outcome {
        case .success(let output):
            lastLatency = started.duration(to: clock.now)
            lastEditCount = output.ops.count
            runCount += 1
            lastError = nil
            backoff = .zero
            notBefore = nil
            // If the loop was switched off mid-flight, the user no longer wants this answer.
            if isEnabled { job.complete(output) }

        case .failure(let error):
            guard !(error is CancellationError) else { break }
            let modelError = error as? ModelError
            lastError = error.localizedDescription

            if modelError?.stopsLoop == true {
                isEnabled = false
            } else if modelError?.isRetryable ?? true {
                // Same snapshot, later. Back off so an outage doesn't turn into a request storm.
                dirty = true
                backoff = min(max(backoff * 2, .seconds(1)), .seconds(30))
                notBefore = clock.now.advanced(by: max(backoff, modelError?.retryAfter ?? .zero))
            }
            // A refusal or an unreadable reply is not retried: the next stroke gives the model a fresh look.
        }

        reschedule()
    }
}
