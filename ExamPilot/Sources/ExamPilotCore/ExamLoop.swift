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
    private let initialRuntimeState: ExamRuntimeState
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
        initialRuntimeState: ExamRuntimeState = ExamRuntimeState(),
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
        self.initialRuntimeState = initialRuntimeState
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
        var runtimeState = initialRuntimeState

        while cycles < maxCycles {
            if shouldStop() {
                return .stopped(cycles: cycles)
            }

            do {
                let before = try await capture.capture()
                cycles += 1
                runtimeState.acceptObservation()

                let state = ExamObservationState(
                    cycle: cycles,
                    nonProgressCount: nonProgressCount,
                    lastSummary: lastSummary,
                    stateVersion: runtimeState.stateVersion,
                    questionGeneration: runtimeState.questionGeneration,
                    answerVerified: runtimeState.answerState == .verified,
                    uiPhase: runtimeState.uiPhase
                )
                let decision = try await visionAgent.decide(frame: before, state: state)
                lastSummary = decision.summary

                let batch: ValidatedBatch
                do {
                    batch = try policy.validate(
                        decision,
                        screenBounds: before.screenBounds,
                        context: ActionPolicyContext(
                            stateVersion: runtimeState.stateVersion,
                            navigationAllowed: runtimeState.navigationAllowed
                        )
                    )
                } catch let error as ActionValidationError {
                    if error == .protectedBoundaryBeforeAnswer {
                        nonProgressCount = 0
                    }
                    // Invalid or lifecycle-illegal proposals never reach physical input.
                    // Re-observe rather than guessing a replacement coordinate locally.
                    continue
                }

                if dryRun {
                    return .dryRunPlanned(summary: batch.summary, actionCount: batch.actions.count)
                }

                // Every proposal is bound to the exact accepted observation that produced it.
                // Any runtime state transition invalidates the stale batch before physical input.
                guard batch.stateVersion == runtimeState.stateVersion else {
                    continue
                }

                try await prepareForInput(before)
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                guard batch.stateVersion == runtimeState.stateVersion else {
                    continue
                }

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
                    // The observed state changed during a multi-action proposal. Remaining
                    // actions are stale. Do not infer answer verification from an interrupted
                    // batch; the next observation must establish the new state.
                    nonProgressCount = 0
                    continue
                }

                guard batch.expectsVisualChange else {
                    nonProgressCount = 0
                    continue
                }

                try await postActionSettler()
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                let after = try await capture.capture()
                if detector.hasMeaningfulChange(before: before.image, after: after.image) {
                    nonProgressCount = 0

                    if batch.containsProtectedBoundary {
                        // Slice 1 records the semantic lifecycle reset immediately after a
                        // verified boundary change. Task 4 replaces this immediate completion
                        // with bounded consecutive-frame UI-stability gating.
                        runtimeState.beginBoundaryTransition()
                        runtimeState.completeBoundaryTransition()
                    } else if batch.hasPotentialAnswerMutation {
                        // A model assertion is not evidence. Only a physically executed
                        // answer-like mutation followed by an observed visual change can make
                        // navigation legal for this question generation.
                        runtimeState.recordAnswerVerified()
                    }
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
