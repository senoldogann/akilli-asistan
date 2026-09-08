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
    private let dryRun: Bool
    private let maxCycles: Int
    private let maxNonProgress: Int
    private let postActionSettler: () async throws -> Void
    private let shouldStop: () -> Bool

    public init(
        capture: ScreenCapturing,
        visionAgent: VisionAgent,
        policy: ActionBatchPolicy = ActionBatchPolicy(),
        executor: ActionBatchExecutor,
        detector: VisualChangeDetector = VisualChangeDetector(),
        dryRun: Bool,
        maxCycles: Int = 200,
        maxNonProgress: Int = 3,
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
        self.dryRun = dryRun
        self.maxCycles = maxCycles
        self.maxNonProgress = maxNonProgress
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

                let execution = try await executor.execute(batch, dryRun: false, shouldStop: shouldStop)
                if execution.cancelled {
                    return .stopped(cycles: cycles)
                }
                if execution.finished {
                    return .finished(cycles: cycles)
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
