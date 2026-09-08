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
    private let stabilityDetector: UIStabilityDetector
    private let maxStabilitySamples: Int
    private let initialRuntimeState: ExamRuntimeState
    private let eventSink: AgentEventSinking
    private let dryRun: Bool
    private let maxCycles: Int
    private let maxNonProgress: Int
    private let prepareForInput: (ScreenFrame) async throws -> Void
    private let intermediateClickSettler: () async throws -> Void
    private let postActionSettler: () async throws -> Void
    private let stabilitySettler: () async throws -> Void
    private let shouldStop: () -> Bool

    public init(
        capture: ScreenCapturing,
        visionAgent: VisionAgent,
        policy: ActionBatchPolicy = ActionBatchPolicy(),
        executor: ActionBatchExecutor,
        detector: VisualChangeDetector = VisualChangeDetector(),
        structuralDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.08),
        stabilityDetector: UIStabilityDetector = UIStabilityDetector(),
        maxStabilitySamples: Int = 4,
        initialRuntimeState: ExamRuntimeState = ExamRuntimeState(),
        eventSink: AgentEventSinking = NullAgentEventSink(),
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
        stabilitySettler: @escaping () async throws -> Void = {
            try await Task.sleep(nanoseconds: 150_000_000)
        },
        shouldStop: @escaping () -> Bool = { false }
    ) {
        self.capture = capture
        self.visionAgent = visionAgent
        self.policy = policy
        self.executor = executor
        self.detector = detector
        self.structuralDetector = structuralDetector
        self.stabilityDetector = stabilityDetector
        self.maxStabilitySamples = max(1, maxStabilitySamples)
        self.initialRuntimeState = initialRuntimeState
        self.eventSink = eventSink
        self.dryRun = dryRun
        self.maxCycles = maxCycles
        self.maxNonProgress = maxNonProgress
        self.prepareForInput = prepareForInput
        self.intermediateClickSettler = intermediateClickSettler
        self.postActionSettler = postActionSettler
        self.stabilitySettler = stabilitySettler
        self.shouldStop = shouldStop
    }

    public func run() async -> ExamRunResult {
        var cycles = 0
        var nonProgressCount = 0
        var lastSummary: String?
        var runtimeState = initialRuntimeState
        var pendingTransitionFrame: ScreenFrame?

        while cycles < maxCycles {
            if shouldStop() {
                return .stopped(cycles: cycles)
            }

            do {
                let before: ScreenFrame
                if let pending = pendingTransitionFrame {
                    var previous = pending
                    var stableFrame: ScreenFrame?

                    for _ in 0..<maxStabilitySamples {
                        if shouldStop() {
                            return .stopped(cycles: cycles)
                        }

                        try await stabilitySettler()
                        if shouldStop() {
                            return .stopped(cycles: cycles)
                        }

                        let current = try await capture.capture()
                        if stabilityDetector.isStable(previous: previous.image, current: current.image) {
                            stableFrame = current
                            break
                        }

                        recordEvent(
                            .stabilityWaiting,
                            cycle: cycles,
                            state: runtimeState,
                            detail: "ui_still_transitioning"
                        )
                        previous = current
                    }

                    guard let stableFrame else {
                        pendingTransitionFrame = previous
                        nonProgressCount += 1
                        recordEvent(
                            .stabilityWaiting,
                            cycle: cycles,
                            state: runtimeState,
                            detail: "stability_sample_budget_exhausted"
                        )
                        if nonProgressCount >= maxNonProgress {
                            return .nonProgress(cycles: cycles)
                        }
                        continue
                    }

                    runtimeState.completeBoundaryTransition()
                    recordEvent(
                        .boundaryTransitionCompleted,
                        cycle: cycles,
                        state: runtimeState,
                        detail: "ui_stable"
                    )
                    pendingTransitionFrame = nil
                    nonProgressCount = 0
                    before = stableFrame
                } else {
                    before = try await capture.capture()
                }

                cycles += 1
                runtimeState.acceptObservation()
                recordEvent(
                    .observationAccepted,
                    cycle: cycles,
                    state: runtimeState,
                    detail: "observation_accepted"
                )

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
                recordEvent(
                    .proposalReceived,
                    cycle: cycles,
                    state: runtimeState,
                    detail: "proposal_received"
                )

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
                    let detail: String
                    if error == .protectedBoundaryBeforeAnswer {
                        nonProgressCount = 0
                        detail = "protected_boundary_before_answer"
                    } else {
                        detail = "action_validation_failed"
                    }
                    recordEvent(
                        .policyDenied,
                        cycle: cycles,
                        state: runtimeState,
                        detail: detail
                    )
                    continue
                }

                recordEvent(
                    .batchValidated,
                    cycle: cycles,
                    state: runtimeState,
                    detail: batch.deferredProtectedBoundary ? "protected_boundary_deferred" : "batch_validated"
                )

                if dryRun {
                    return .dryRunPlanned(summary: batch.summary, actionCount: batch.actions.count)
                }

                guard batch.stateVersion == runtimeState.stateVersion else {
                    recordEvent(
                        .policyDenied,
                        cycle: cycles,
                        state: runtimeState,
                        detail: "stale_state_version"
                    )
                    continue
                }

                try await prepareForInput(before)
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                guard batch.stateVersion == runtimeState.stateVersion else {
                    recordEvent(
                        .policyDenied,
                        cycle: cycles,
                        state: runtimeState,
                        detail: "stale_state_after_focus_preparation"
                    )
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
                    nonProgressCount = 0
                    recordEvent(
                        .verificationFailed,
                        cycle: cycles,
                        state: runtimeState,
                        detail: "batch_interrupted_for_ui_change"
                    )
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
                        runtimeState.beginBoundaryTransition()
                        recordEvent(
                            .boundaryTransitionStarted,
                            cycle: cycles,
                            state: runtimeState,
                            detail: "protected_boundary_changed_ui"
                        )
                        pendingTransitionFrame = after
                    } else if batch.hasPotentialAnswerMutation {
                        runtimeState.recordAnswerVerified()
                        recordEvent(
                            .answerVerified,
                            cycle: cycles,
                            state: runtimeState,
                            detail: "answer_mutation_verified"
                        )
                    }
                } else {
                    nonProgressCount += 1
                    recordEvent(
                        .verificationFailed,
                        cycle: cycles,
                        state: runtimeState,
                        detail: "expected_visual_change_missing"
                    )
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

    private func recordEvent(
        _ kind: AgentEventKind,
        cycle: Int,
        state: ExamRuntimeState,
        detail: String
    ) {
        eventSink.record(
            AgentEvent(
                kind: kind,
                cycle: cycle,
                stateVersion: state.stateVersion,
                questionGeneration: state.questionGeneration,
                detail: detail
            )
        )
    }
}
