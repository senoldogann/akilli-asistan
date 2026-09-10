import Foundation
import ComputerAgentCore

public enum ExamRunResult: Equatable {
    case finished(cycles: Int)
    case nonProgress(cycles: Int, reason: AgentFailureReason = .unknown)
    case dryRunPlanned(summary: String, actionCount: Int)
    case stopped(cycles: Int)
    case maxCycles(cycles: Int)
    case failed(cycles: Int, message: String)
}

private struct PendingTransitionVerification {
    let beforeFrame: ScreenFrame
    let intent: AgentIntentFingerprint
}

private final class ExamLoopRunState {
    var nonProgressCount = 0
    var pendingTransitionFrame: ScreenFrame?
    var pendingTransitionVerification: PendingTransitionVerification?
}

public final class ExamLoop {
    private let capture: ScreenCapturing
    private let visionAgent: VisionAgent
    private let policy: ActionBatchPolicy
    private let executor: ActionBatchExecutor
    private let detector: VisualChangeDetector
    private let structuralDetector: VisualChangeDetector
    private let outcomeVerifier: OutcomeVerifying
    private let stabilityDetector: UIStabilityDetector
    private let recoveryEngine: RecoveryEngine
    private let maxStabilitySamples: Int
    private let session: ComputerAgentSession
    private let eventSink: AgentEventSinking
    private let dryRun: Bool
    private let maxCycles: Int
    private let maxNonProgress: Int
    private let prepareForInput: (ScreenFrame) async throws -> Void
    private let intermediateClickSettler: () async throws -> Void
    private let postActionSettler: () async throws -> Void
    private let stabilitySettler: () async throws -> Void
    private let shouldStop: () -> Bool
    private var lastNonProgressReason: AgentFailureReason = .unknown

    public init(
        capture: ScreenCapturing,
        visionAgent: VisionAgent,
        policy: ActionBatchPolicy = ActionBatchPolicy(),
        executor: ActionBatchExecutor,
        detector: VisualChangeDetector = VisualChangeDetector(),
        structuralDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.08),
        outcomeVerifier: OutcomeVerifying? = nil,
        stabilityDetector: UIStabilityDetector = UIStabilityDetector(),
        recoveryEngine: RecoveryEngine = RecoveryEngine(),
        maxStabilitySamples: Int = 4,
        initialRuntimeState: ExamRuntimeState = ExamRuntimeState(),
        session: ComputerAgentSession? = nil,
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
        self.outcomeVerifier = outcomeVerifier ?? OutcomeVerifier(
            progressDetector: detector,
            structuralDetector: structuralDetector
        )
        self.stabilityDetector = stabilityDetector
        self.recoveryEngine = recoveryEngine
        self.maxStabilitySamples = max(1, maxStabilitySamples)
        self.session = session ?? ComputerAgentSession(
            goal: "Complete the authorized ExamPilot task",
            initialRuntimeState: initialRuntimeState
        )
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
        lastNonProgressReason = .unknown
        let runState = ExamLoopRunState()
        let runtime = ComputerAgentRuntime<ExamRunResult>(
            maxCycles: maxCycles,
            shouldStop: shouldStop,
            step: { context in
                try await self.runCycle(context: context, runState: runState)
            },
            stoppedResult: { .stopped(cycles: $0) },
            maxCyclesResult: { .maxCycles(cycles: $0) },
            failureResult: { cycles, error in
                .failed(cycles: cycles, message: error.localizedDescription)
            }
        )

        return await runtime.run()
    }

    private func runCycle(
        context: ComputerAgentRuntime<ExamRunResult>.Context,
        runState: ExamLoopRunState
    ) async throws -> ComputerAgentRuntime<ExamRunResult>.StepResult {
        let before: ScreenFrame
        if let pending = runState.pendingTransitionFrame {
            var previous = pending
            var stableFrame: ScreenFrame?

            for _ in 0..<maxStabilitySamples {
                if shouldStop() {
                    return .complete(.stopped(cycles: context.cycles))
                }

                try await stabilitySettler()
                if shouldStop() {
                    return .complete(.stopped(cycles: context.cycles))
                }

                let current = try await capture.capture()
                if stabilityDetector.isStable(previous: previous.image, current: current.image) {
                    stableFrame = current
                    break
                }

                recordEvent(
                    .stabilityWaiting,
                    cycle: context.cycles,
                    detail: "ui_still_transitioning"
                )
                previous = current
            }

            guard let stableFrame else {
                runState.pendingTransitionFrame = previous
                runState.nonProgressCount += 1
                lastNonProgressReason = .transitionStillRunning
                recordEvent(
                    .stabilityWaiting,
                    cycle: context.cycles,
                    detail: "stability_sample_budget_exhausted"
                )

                if let verification = runState.pendingTransitionVerification {
                    let recovery = applyRecovery(
                        failure: .transitionStillRunning,
                        intent: verification.intent,
                        cycle: context.cycles
                    )
                    if case .exhausted = recovery {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                }

                if runState.nonProgressCount >= maxNonProgress {
                    return .complete(nonProgress(cycles: context.cycles))
                }
                return .continueRunning
            }

            if let verification = runState.pendingTransitionVerification {
                let outcome = outcomeVerifier.verify(
                    expected: .navigation,
                    before: verification.beforeFrame.image,
                    after: stableFrame.image,
                    uiStable: true
                )

                switch outcome {
                case .success(.navigation):
                    session.completeBoundaryTransition()
                    recoveryEngine.recordSuccess(intent: verification.intent)
                    session.setCurrentRecoveryStrategy(nil)
                    session.recordEvidence(.navigation)
                    recordEvent(
                        .outcomeVerified,
                        cycle: context.cycles,
                        detail: "navigation_verified"
                    )
                    recordEvent(
                        .boundaryTransitionCompleted,
                        cycle: context.cycles,
                        detail: "ui_stable"
                    )
                    runState.pendingTransitionFrame = nil
                    runState.pendingTransitionVerification = nil
                    runState.nonProgressCount = 0
                    before = stableFrame

                case .failure(.navigationIdentityUnchanged):
                    session.failBoundaryTransition()
                    recordEvent(
                        .verificationFailed,
                        cycle: context.cycles,
                        detail: "navigation_identity_unchanged"
                    )
                    let recovery = applyRecovery(
                        failure: .stateMismatch,
                        intent: verification.intent,
                        cycle: context.cycles
                    )
                    runState.pendingTransitionFrame = nil
                    runState.pendingTransitionVerification = nil
                    runState.nonProgressCount += 1
                    if case .exhausted = recovery {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    if runState.nonProgressCount >= maxNonProgress {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    before = stableFrame

                case .pending:
                    runState.pendingTransitionFrame = stableFrame
                    runState.nonProgressCount += 1
                    recordEvent(
                        .outcomePending,
                        cycle: context.cycles,
                        detail: "ui_transitioning"
                    )
                    let recovery = applyRecovery(
                        failure: .transitionStillRunning,
                        intent: verification.intent,
                        cycle: context.cycles
                    )
                    if case .exhausted = recovery {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    if runState.nonProgressCount >= maxNonProgress {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    return .continueRunning

                case .failure(.noVisibleEffect):
                    session.failBoundaryTransition()
                    recordEvent(
                        .verificationFailed,
                        cycle: context.cycles,
                        detail: "no_visible_effect"
                    )
                    let recovery = applyRecovery(
                        failure: .noVisibleEffect,
                        intent: verification.intent,
                        cycle: context.cycles
                    )
                    runState.pendingTransitionFrame = nil
                    runState.pendingTransitionVerification = nil
                    runState.nonProgressCount += 1
                    if case .exhausted = recovery {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    if runState.nonProgressCount >= maxNonProgress {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    before = stableFrame

                case .success:
                    session.failBoundaryTransition()
                    recordEvent(
                        .verificationFailed,
                        cycle: context.cycles,
                        detail: "navigation_verification_mismatch"
                    )
                    let recovery = applyRecovery(
                        failure: .stateMismatch,
                        intent: verification.intent,
                        cycle: context.cycles
                    )
                    runState.pendingTransitionFrame = nil
                    runState.pendingTransitionVerification = nil
                    runState.nonProgressCount += 1
                    if case .exhausted = recovery {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    if runState.nonProgressCount >= maxNonProgress {
                        return .complete(nonProgress(cycles: context.cycles))
                    }
                    before = stableFrame
                }
            } else {
                session.completeBoundaryTransition()
                recordEvent(
                    .boundaryTransitionCompleted,
                    cycle: context.cycles,
                    detail: "ui_stable"
                )
                runState.pendingTransitionFrame = nil
                runState.nonProgressCount = 0
                before = stableFrame
            }
        } else {
            before = try await capture.capture()
        }

        context.advanceCycle()
        session.acceptObservation()
        recordEvent(
            .observationAccepted,
            cycle: context.cycles,
            detail: "observation_accepted"
        )

        let runtimeState = session.runtimeState
        let state = ExamObservationState(
            cycle: context.cycles,
            nonProgressCount: runState.nonProgressCount,
            lastSummary: session.lastPlannerSummary,
            stateVersion: runtimeState.stateVersion,
            questionGeneration: runtimeState.questionGeneration,
            answerVerified: runtimeState.answerState == .verified,
            uiPhase: runtimeState.uiPhase,
            sessionID: session.id,
            workingMemory: session.workingMemory.snapshot(),
            providerContinuationAvailable: session.providerConversationState.previousResponseID != nil
        )
        let decision = try await visionAgent.decide(frame: before, state: state)
        let intent = AgentIntentFingerprint(
            decision: decision,
            questionGeneration: session.runtimeState.questionGeneration
        )
        session.recordAction(intent)
        session.recordPlannerSummary(decision.summary)
        recordEvent(
            .proposalReceived,
            cycle: context.cycles,
            detail: "proposal_received"
        )

        let batch: ValidatedBatch
        do {
            batch = try policy.validate(
                decision,
                screenBounds: before.screenBounds,
                context: ActionPolicyContext(
                    stateVersion: session.runtimeState.stateVersion,
                    navigationAllowed: session.runtimeState.navigationAllowed
                )
            )
        } catch let error as ActionValidationError {
            let detail = error == .protectedBoundaryBeforeAnswer
                ? "protected_boundary_before_answer"
                : "action_validation_failed"
            recordEvent(
                .policyDenied,
                cycle: context.cycles,
                detail: detail
            )
            let recovery = applyRecovery(
                failure: .invalidModelPlan,
                intent: intent,
                cycle: context.cycles
            )
            if case .exhausted = recovery {
                return .complete(nonProgress(cycles: context.cycles))
            }
            return .continueRunning
        }

        recordEvent(
            .batchValidated,
            cycle: context.cycles,
            detail: batch.deferredProtectedBoundary ? "protected_boundary_deferred" : "batch_validated"
        )

        if dryRun {
            return .complete(.dryRunPlanned(summary: batch.summary, actionCount: batch.actions.count))
        }

        guard batch.stateVersion == session.runtimeState.stateVersion else {
            recordEvent(
                .policyDenied,
                cycle: context.cycles,
                detail: "stale_state_version"
            )
            let recovery = applyRecovery(
                failure: .staleObservation,
                intent: intent,
                cycle: context.cycles
            )
            if case .exhausted = recovery {
                return .complete(nonProgress(cycles: context.cycles))
            }
            return .continueRunning
        }

        try await prepareForInput(before)
        if shouldStop() {
            return .complete(.stopped(cycles: context.cycles))
        }

        guard batch.stateVersion == session.runtimeState.stateVersion else {
            recordEvent(
                .policyDenied,
                cycle: context.cycles,
                detail: "stale_state_after_focus_preparation"
            )
            let recovery = applyRecovery(
                failure: .staleObservation,
                intent: intent,
                cycle: context.cycles
            )
            if case .exhausted = recovery {
                return .complete(nonProgress(cycles: context.cycles))
            }
            return .continueRunning
        }

        var structuralBaseline = before.image
        var interruptedTransitionFrame: ScreenFrame?
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
                if changedStructurally {
                    interruptedTransitionFrame = interim
                }
                return !changedStructurally
            }
        )

        for _ in execution.receipts {
            recordEvent(
                .actionExecuted,
                cycle: context.cycles,
                detail: "action_completed"
            )
        }

        if execution.cancelled || shouldStop() {
            return .complete(.stopped(cycles: context.cycles))
        }
        if execution.finished {
            recoveryEngine.recordSuccess(intent: intent)
            session.setCurrentRecoveryStrategy(nil)
            return .complete(.finished(cycles: context.cycles))
        }
        if execution.interruptedForUIChange {
            runState.nonProgressCount = 0
            recordEvent(
                .verificationFailed,
                cycle: context.cycles,
                detail: "batch_interrupted_for_ui_change"
            )
            if let interruptedTransitionFrame {
                session.beginBoundaryTransition()
                recordEvent(
                    .outcomePending,
                    cycle: context.cycles,
                    detail: "unexpected_structural_change"
                )
                recordEvent(
                    .boundaryTransitionStarted,
                    cycle: context.cycles,
                    detail: "unexpected_structural_change"
                )
                runState.pendingTransitionFrame = interruptedTransitionFrame
                runState.pendingTransitionVerification = PendingTransitionVerification(
                    beforeFrame: before,
                    intent: intent
                )
            }
            return .continueRunning
        }

        guard batch.expectsVisualChange else {
            recoveryEngine.recordSuccess(intent: intent)
            session.setCurrentRecoveryStrategy(nil)
            runState.nonProgressCount = 0
            return .continueRunning
        }

        try await postActionSettler()
        if shouldStop() {
            return .complete(.stopped(cycles: context.cycles))
        }

        let after = try await capture.capture()

        if batch.containsProtectedBoundary {
            session.beginBoundaryTransition()
            recordEvent(
                .outcomePending,
                cycle: context.cycles,
                detail: "ui_transitioning"
            )
            recordEvent(
                .boundaryTransitionStarted,
                cycle: context.cycles,
                detail: "protected_boundary_changed_ui"
            )
            runState.pendingTransitionFrame = after
            runState.pendingTransitionVerification = PendingTransitionVerification(
                beforeFrame: before,
                intent: intent
            )
            runState.nonProgressCount = 0
            return .continueRunning
        }

        let outcome = outcomeVerifier.verify(
            expected: batch.expectedOutcome,
            before: before.image,
            after: after.image,
            uiStable: true
        )

        switch outcome {
        case .success(.answerMutation):
            recoveryEngine.recordSuccess(intent: intent)
            session.setCurrentRecoveryStrategy(nil)
            runState.nonProgressCount = 0
            session.recordAnswerVerified()
            session.recordEvidence(.answerMutation)
            recordEvent(
                .answerVerified,
                cycle: context.cycles,
                detail: "answer_mutation_verified"
            )
            recordEvent(
                .outcomeVerified,
                cycle: context.cycles,
                detail: "answer_mutation_verified"
            )

        case .success(.viewportChange):
            recoveryEngine.recordSuccess(intent: intent)
            session.setCurrentRecoveryStrategy(nil)
            session.recordEvidence(.viewportChange)
            runState.nonProgressCount = 0
            recordEvent(
                .outcomeVerified,
                cycle: context.cycles,
                detail: "viewport_change_verified"
            )

        case .success(.none):
            recoveryEngine.recordSuccess(intent: intent)
            session.setCurrentRecoveryStrategy(nil)
            session.recordEvidence(.none)
            runState.nonProgressCount = 0
            recordEvent(
                .outcomeVerified,
                cycle: context.cycles,
                detail: "no_semantic_change_expected"
            )

        case .success(.navigation):
            session.beginBoundaryTransition()
            recordEvent(
                .outcomePending,
                cycle: context.cycles,
                detail: "ui_transitioning"
            )
            recordEvent(
                .boundaryTransitionStarted,
                cycle: context.cycles,
                detail: "unexpected_post_action_structural_change"
            )
            runState.pendingTransitionFrame = after
            runState.pendingTransitionVerification = PendingTransitionVerification(
                beforeFrame: before,
                intent: intent
            )
            runState.nonProgressCount = 0

        case .failure(.noVisibleEffect):
            runState.nonProgressCount += 1
            recordEvent(
                .verificationFailed,
                cycle: context.cycles,
                detail: "no_visible_effect"
            )
            let recovery = applyRecovery(
                failure: .noVisibleEffect,
                intent: intent,
                cycle: context.cycles
            )
            if case .exhausted = recovery {
                return .complete(nonProgress(cycles: context.cycles))
            }
            if runState.nonProgressCount >= maxNonProgress {
                return .complete(nonProgress(cycles: context.cycles))
            }

        case .failure(.navigationIdentityUnchanged):
            runState.nonProgressCount += 1
            recordEvent(
                .verificationFailed,
                cycle: context.cycles,
                detail: "navigation_identity_unchanged"
            )
            let recovery = applyRecovery(
                failure: .stateMismatch,
                intent: intent,
                cycle: context.cycles
            )
            if case .exhausted = recovery {
                return .complete(nonProgress(cycles: context.cycles))
            }
            if runState.nonProgressCount >= maxNonProgress {
                return .complete(nonProgress(cycles: context.cycles))
            }

        case .pending(.unexpectedStructuralChange), .pending(.uiTransitioning):
            session.beginBoundaryTransition()
            recordEvent(
                .outcomePending,
                cycle: context.cycles,
                detail: "unexpected_structural_change"
            )
            recordEvent(
                .boundaryTransitionStarted,
                cycle: context.cycles,
                detail: "unexpected_post_action_structural_change"
            )
            runState.pendingTransitionFrame = after
            runState.pendingTransitionVerification = PendingTransitionVerification(
                beforeFrame: before,
                intent: intent
            )
            runState.nonProgressCount = 0
        }
        return .continueRunning
    }

    private func applyRecovery(
        failure: AgentFailureReason,
        intent: AgentIntentFingerprint,
        cycle: Int
    ) -> RecoveryDecision {
        lastNonProgressReason = failure
        let decision = recoveryEngine.handle(failure: failure, intent: intent)
        switch decision {
        case .recover(let strategy, _):
            session.recordFailure(failure, recoveryStrategy: strategy)
            session.setCurrentRecoveryStrategy(strategy)
            recordEvent(
                .recoveryPlanned,
                cycle: cycle,
                detail: strategy == .waitForStability
                    ? "wait_for_stability"
                    : "reobserve_and_replan"
            )
        case .exhausted(let reason):
            lastNonProgressReason = reason
            session.recordFailure(failure, recoveryStrategy: nil)
            session.setCurrentRecoveryStrategy(nil)
            recordEvent(
                .recoveryExhausted,
                cycle: cycle,
                detail: "repeated_intent_loop"
            )
        }
        return decision
    }

    private func nonProgress(cycles: Int) -> ExamRunResult {
        .nonProgress(cycles: cycles, reason: lastNonProgressReason)
    }

    private func recordEvent(
        _ kind: AgentEventKind,
        cycle: Int,
        detail: String
    ) {
        let state = session.runtimeState
        eventSink.record(
            AgentEvent(
                sessionID: session.id,
                kind: kind,
                cycle: cycle,
                stateVersion: state.stateVersion,
                questionGeneration: state.questionGeneration,
                detail: detail
            )
        )
    }
}
