import Foundation

public enum ExamRunResult: Equatable {
    case finished(cycles: Int)
    case nonProgress(cycles: Int)
    case dryRunPlanned(summary: String, actionCount: Int)
    case stopped(cycles: Int)
    case maxCycles(cycles: Int)
    case failed(cycles: Int, message: String)
}

public final class ExamLoop {
    private let capture: ScreenCapturing
    private let visionAgent: VisionAgent
    private let policy: ActionBatchPolicy
    private let executor: ActionBatchExecutor
    private let detector: VisualChangeDetector
    private let structuralDetector: VisualChangeDetector
    private let dryRun: Bool
    private let maxCycles: Int
    private let maxNonProgress: Int
    private let prepareForInput: (ScreenFrame) async throws -> Void
    private let intermediateClickSettler: () async throws -> Void
    private let postActionSettler: () async throws -> Void
    private let shouldStop: () -> Bool

    public init(
        capture: ScreenCapturing,
        visionAgent: VisionAgent,
        policy: ActionBatchPolicy = ActionBatchPolicy(),
        executor: ActionBatchExecutor,
        detector: VisualChangeDetector = VisualChangeDetector(),
        structuralDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.08),
        dryRun: Bool,
        maxCycles: Int = 200,
        maxNonProgress: Int = 3,
        prepareForInput: @escaping (ScreenFrame) async throws -> Void = { _ in },
        intermediateClickSettler: @escaping () async throws -> Void = {
            try await Task.sleep(nanoseconds: 220_000_000)
        },
        postActionSettler: @escaping () async throws -> Void = {
            try await Task.sleep(nanoseconds: 450_000_000)
        },
        shouldStop: @escaping () -> Bool = { false }
    ) {
        self.capture = capture
        self.visionAgent = visionAgent
        self.policy = policy
        self.executor = executor
        self.detector = detector
        self.structuralDetector = structuralDetector
        self.dryRun = dryRun
        self.maxCycles = maxCycles
        self.maxNonProgress = maxNonProgress
        self.prepareForInput = prepareForInput
        self.intermediateClickSettler = intermediateClickSettler
        self.postActionSettler = postActionSettler
        self.shouldStop = shouldStop
    }

    public func run() async -> ExamRunResult {
        var cycles = 0
        var nonProgressCount = 0
        var lastSummary: String?

        while cycles < maxCycles {
            if shouldStop() {
                return .stopped(cycles: cycles)
            }

            do {
                let before = try await capture.capture()
                cycles += 1

                let state = ExamObservationState(
                    cycle: cycles,
                    nonProgressCount: nonProgressCount,
                    lastSummary: lastSummary
                )
                let decision = try await visionAgent.decide(frame: before, state: state)
                lastSummary = decision.summary

                let batch: ValidatedBatch
                do {
                    batch = try policy.validate(decision, screenBounds: before.screenBounds)
                } catch is ActionValidationError {
                    // A bad coordinate or unsafe-sized batch must never reach physical input.
                    // Re-observe the fresh UI instead of trying to repair guessed coordinates locally.
                    continue
                }

                if dryRun {
                    return .dryRunPlanned(summary: batch.summary, actionCount: batch.actions.count)
                }

                // Re-activate the exact Chrome process that produced this observation before
                // posting any global HID events. Dry-run exits above and never changes focus.
                try await prepareForInput(before)
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                // The model's boundary flag is advisory, not a security boundary. After any
                // non-boundary click that still has actions behind it, take a cheap local
                // screenshot and stop the batch if the page changed structurally. This keeps
                // small checkbox/radio updates batchable while preventing stale actions from
                // running after a misclassified Next/Submit/navigation click.
                var structuralBaseline = before.image
                let execution = try await executor.execute(
                    batch,
                    dryRun: false,
                    shouldStop: shouldStop,
                    afterAction: { action, hasRemainingActions in
                        guard hasRemainingActions,
                              action.kind == .moveClick,
                              !action.boundary else {
                            return true
                        }

                        try await self.intermediateClickSettler()
                        if self.shouldStop() {
                            return false
                        }

                        let interim = try await self.capture.capture()
                        let changedStructurally = self.structuralDetector.hasMeaningfulChange(
                            before: structuralBaseline,
                            after: interim.image
                        )
                        structuralBaseline = interim.image
                        return !changedStructurally
                    }
                )
                if execution.cancelled || shouldStop() {
                    return .stopped(cycles: cycles)
                }
                if execution.finished {
                    return .finished(cycles: cycles)
                }
                if execution.interruptedForUIChange {
                    // The intermediate guard already observed a materially different UI.
                    // Discard every stale action after the click and reason again from a
                    // fresh screenshot on the next cycle rather than counting non-progress.
                    nonProgressCount = 0
                    continue
                }

                guard batch.expectsVisualChange else {
                    nonProgressCount = 0
                    continue
                }

                // Give browser selection state, editor rendering, navigation and test output
                // a short bounded chance to settle before deciding whether the action worked.
                // The closure is injectable so tests stay fast and deterministic.
                try await postActionSettler()
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                let after = try await capture.capture()
                if detector.hasMeaningfulChange(before: before.image, after: after.image) {
                    nonProgressCount = 0
                } else {
                    // Do not replay guessed nearby coordinates from this stale observation.
                    // A successful navigation can produce a visually similar next question;
                    // another blind click could immediately skip that question. The next loop
                    // iteration captures a fresh frame and asks the vision agent to reassess
                    // the current question and coordinates.
                    nonProgressCount += 1
                    if nonProgressCount >= maxNonProgress {
                        return .nonProgress(cycles: cycles)
                    }
                }
            } catch {
                return .failed(cycles: cycles, message: error.localizedDescription)
            }
        }

        return .maxCycles(cycles: cycles)
    }
}
