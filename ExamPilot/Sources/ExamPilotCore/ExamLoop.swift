import Foundation

public enum ExamRunResult: Equatable {
    case finished(cycles: Int)
    case nonProgress(cycles: Int)
    case dryRunPlanned(summary: String, actionCount: Int)
    case stopped(cycles: Int)
    case maxCycles(cycles: Int)
    case failed(cycles: Int, message: String)
}

private struct PendingTransitionVerification {
    let beforeFrame: ScreenFrame
    let intent: AgentIntentFingerprint
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
        var cycles = 0
        var nonProgressCount = 0
        var pendingTransitionFrame: ScreenFrame?
        var pendingTransitionVerification: PendingTransitionVerification?

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
                            detail: "stability_sample_budget_exhausted"
                        )

                        if let verification = pendingTransitionVerification {
                            let recovery = applyRecovery(
                                failure: .transitionStillRunning,
                                intent: verification.intent,
                                cycle: cycles
                            )
                            if case .exhausted = recovery {
                                return .nonProgress(cycles: cycles)
                            }
                        }

                        if nonProgressCount >= maxNonProgress {
                            return .nonProgress(cycles: cycles)
                        }
                        continue
                    }

                    if let verification = pendingTransitionVerification {
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
                                cycle: cycles,
                                detail: "navigation_verified"
                            )
                            recordEvent(
                                .boundaryTransitionCompleted,
                                cycle: cycles,
                                detail: "ui_stable"
                            )
                            pendingTransitionFrame = nil
                            pendingTransitionVerification = nil
                            nonProgressCount = 0
                            before = stableFrame

                        case .failure(.navigationIdentityUnchanged):
                            session.failBoundaryTransition()
                            recordEvent(
                                .verificationFailed,
                                cycle: cycles,
                                detail: "navigation_identity_unchanged"
                            )
                            let recovery = applyRecovery(
                                failure: .stateMismatch,
                                intent: verification.intent,
                                cycle: cycles
                            )
                            pendingTransitionFrame = nil
                            pendingTransitionVerification = nil
                            nonProgressCount += 1
                            if case .exhausted = recovery {
                                return .nonProgress(cycles: cycles)
                            }
                            if nonProgressCount >= maxNonProgress {
                                return .nonProgress(cycles: cycles)
                            }
                            before = stableFrame

                        case .pending:
                            pendingTransitionFrame = stableFrame
                            nonProgressCount += 1
                            recordEvent(
                                .outcomePending,
                                cycle: cycles,
                                detail: "ui_transitioning"
                            )
                            let recovery = applyRecovery(
                                failure: .transitionStillRunning,
                                intent: verification.intent,
                                cycle: cycles
                            )
                            if case .exhausted = recovery {
                                return .nonProgress(cycles: cycles)
                            }
                            if nonProgressCount >= maxNonProgress {
                                return .nonProgress(cycles: cycles)
                            }
                            continue

                        case .failure(.noVisibleEffect):
                            session.failBoundaryTransition()
                            recordEvent(
                                .verificationFailed,
                                cycle: cycles,
                                detail: "no_visible_effect"
                            )
                            let recovery = applyRecovery(
                                failure: .noVisibleEffect,
                                intent: verification.intent,
                                cycle: cycles
                            )
                            pendingTransitionFrame = nil
                            pendingTransitionVerification = nil
                            nonProgressCount += 1
                            if case .exhausted = recovery {
                                return .nonProgress(cycles: cycles)
                            }
                            if nonProgressCount >= maxNonProgress {
                                return .nonProgress(cycles: cycles)
                            }
                            before = stableFrame

                        case .success:
                            session.failBoundaryTransition()
                            recordEvent(
                                .verificationFailed,
                                cycle: cycles,
                                detail: "navigation_verification_mismatch"
                            )
                            let recovery = applyRecovery(
                                failure: .stateMismatch,
                                intent: verification.intent,
                                cycle: cycles
                            )
                            pendingTransitionFrame = nil
                            pendingTransitionVerification = nil
                            nonProgressCount += 1
                            if case .exhausted = recovery {
                                return .nonProgress(cycles: cycles)
                            }
                            if nonProgressCount >= maxNonProgress {
                                return .nonProgress(cycles: cycles)
                            }
                            before = stableFrame
                        }
                    } else {
                        session.completeBoundaryTransition()
                        recordEvent(
                            .boundaryTransitionCompleted,
                            cycle: cycles,
                            detail: "ui_stable"
                        )
                        pendingTransitionFrame = nil
                        nonProgressCount = 0
                        before = stableFrame
                    }
                } else {
                    before = try await capture.capture()
                }

                cycles += 1
                session.acceptObservation()
                recordEvent(
                    .observationAccepted,
                    cycle: cycles,
                    detail: "observation_accepted"
                )

                let runtimeState = session.runtimeState
                let state = ExamObservationState(
                    cycle: cycles,
                    nonProgressCount: nonProgressCount,
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
                    cycle: cycles,
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
                        cycle: cycles,
                        detail: detail
                    )
                    let recovery = applyRecovery(
                        failure: .invalidModelPlan,
                        intent: intent,
                        cycle: cycles
                    )
                    if case .exhausted = recovery {
                        return .nonProgress(cycles: cycles)
                    }
                    continue
                }

                recordEvent(
                    .batchValidated,
                    cycle: cycles,
                    detail: batch.deferredProtectedBoundary ? "protected_boundary_deferred" : "batch_validated"
                )

                if dryRun {
                    return .dryRunPlanned(summary: batch.summary, actionCount: batch.actions.count)
                }

                guard batch.stateVersion == session.runtimeState.stateVersion else {
                    recordEvent(
                        .policyDenied,
                        cycle: cycles,
                        detail: "stale_state_version"
                    )
                    let recovery = applyRecovery(
                        failure: .staleObservation,
                        intent: intent,
                        cycle: cycles
                    )
                    if case .exhausted = recovery {
                        return .nonProgress(cycles: cycles)
                    }
                    continue
                }

                try await prepareForInput(before)
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                guard batch.stateVersion == session.runtimeState.stateVersion else {
                    recordEvent(
                        .policyDenied,
                        cycle: cycles,
                        detail: "stale_state_after_focus_preparation"
                    )
                    let recovery = applyRecovery(
                        failure: .staleObservation,
                        intent: intent,
                        cycle: cycles
                    )
                    if case .exhausted = recovery {
                        return .nonProgress(cycles: cycles)
                    }
                    continue
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
                        cycle: cycles,
                        detail: "action_completed"
                    )
                }

                if execution.cancelled || shouldStop() {
                    return .stopped(cycles: cycles)
                }
                if execution.finished {
                    recoveryEngine.recordSuccess(intent: intent)
                    session.setCurrentRecoveryStrategy(nil)
                    return .finished(cycles: cycles)
                }
                if execution.interruptedForUIChange {
                    nonProgressCount = 0
                    recordEvent(
                        .verificationFailed,
                        cycle: cycles,
                        detail: "batch_interrupted_for_ui_change"
                    )
                    if let interruptedTransitionFrame {
                        session.beginBoundaryTransition()
                        recordEvent(
                            .outcomePending,
                            cycle: cycles,
                            detail: "unexpected_structural_change"
                        )
                        recordEvent(
                            .boundaryTransitionStarted,
                            cycle: cycles,
                            detail: "unexpected_structural_change"
                        )
                        pendingTransitionFrame = interruptedTransitionFrame
                        pendingTransitionVerification = PendingTransitionVerification(
                            beforeFrame: before,
                            intent: intent
                        )
                    }
                    continue
                }

                guard batch.expectsVisualChange else {
                    recoveryEngine.recordSuccess(intent: intent)
                    session.setCurrentRecoveryStrategy(nil)
                    nonProgressCount = 0
                    continue
                }

                try await postActionSettler()
                if shouldStop() {
                    return .stopped(cycles: cycles)
                }

                let after = try await capture.capture()

                if batch.containsProtectedBoundary {
                    session.beginBoundaryTransition()
                    recordEvent(
                        .outcomePending,
                        cycle: cycles,
                        detail: "ui_transitioning"
                    )
                    recordEvent(
                        .boundaryTransitionStarted,
                        cycle: cycles,
                        detail: "protected_boundary_changed_ui"
                    )
                    pendingTransitionFrame = after
                    pendingTransitionVerification = PendingTransitionVerification(
                        beforeFrame: before,
                        intent: intent
                    )
                    nonProgressCount = 0
                    continue
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
                    nonProgressCount = 0
                    session.recordAnswerVerified()
                    session.recordEvidence(.answerMutation)
                    recordEvent(
                        .answerVerified,
                        cycle: cycles,
                        detail: "answer_mutation_verified"
                    )
                    recordEvent(
                        .outcomeVerified,
                        cycle: cycles,
                        detail: "answer_mutation_verified"
                    )

                case .success(.viewportChange):
                    recoveryEngine.recordSuccess(intent: intent)
                    session.setCurrentRecoveryStrategy(nil)
                    session.recordEvidence(.viewportChange)
                    nonProgressCount = 0
                    recordEvent(
                        .outcomeVerified,
                        cycle: cycles,
                        detail: "viewport_change_verified"
                    )

                case .success(.none):
                    recoveryEngine.recordSuccess(intent: intent)
                    session.setCurrentRecoveryStrategy(nil)
                    session.recordEvidence(.none)
                    nonProgressCount = 0
                    recordEvent(
                        .outcomeVerified,
                        cycle: cycles,
                        detail: "no_semantic_change_expected"
                    )

                case .success(.navigation):
                    session.beginBoundaryTransition()
                    recordEvent(
                        .outcomePending,
                        cycle: cycles,
                        detail: "ui_transitioning"
                    )
                    recordEvent(
                        .boundaryTransitionStarted,
                        cycle: cycles,
                        detail: "unexpected_post_action_structural_change"
                    )
                    pendingTransitionFrame = after
                    pendingTransitionVerification = PendingTransitionVerification(
                        beforeFrame: before,
                        intent: intent
                    )
                    nonProgressCount = 0

                case .failure(.noVisibleEffect):
                    nonProgressCount += 1
                    recordEvent(
                        .verificationFailed,
                        cycle: cycles,
                        detail: "no_visible_effect"
                    )
                    let recovery = applyRecovery(
                        failure: .noVisibleEffect,
                        intent: intent,
                        cycle: cycles
                    )
                    if case .exhausted = recovery {
                        return .nonProgress(cycles: cycles)
                    }
                    if nonProgressCount >= maxNonProgress {
                        return .nonProgress(cycles: cycles)
                    }

                case .failure(.navigationIdentityUnchanged):
                    nonProgressCount += 1
                    recordEvent(
                        .verificationFailed,
                        cycle: cycles,
                        detail: "navigation_identity_unchanged"
                    )
                    let recovery = applyRecovery(
                        failure: .stateMismatch,
                        intent: intent,
                        cycle: cycles
                    )
                    if case .exhausted = recovery {
                        return .nonProgress(cycles: cycles)
                    }
                    if nonProgressCount >= maxNonProgress {
                        return .nonProgress(cycles: cycles)
                    }

                case .pending(.unexpectedStructuralChange), .pending(.uiTransitioning):
                    session.beginBoundaryTransition()
                    recordEvent(
                        .outcomePending,
                        cycle: cycles,
                        detail: "unexpected_structural_change"
                    )
                    recordEvent(
                        .boundaryTransitionStarted,
                        cycle: cycles,
                        detail: "unexpected_post_action_structural_change"
                    )
                    pendingTransitionFrame = after
                    pendingTransitionVerification = PendingTransitionVerification(
                        beforeFrame: before,
                        intent: intent
                    )
                    nonProgressCount = 0
                }
            } catch {
                return .failed(cycles: cycles, message: error.localizedDescription)
            }
        }

        return .maxCycles(cycles: cycles)
    }

    private func applyRecovery(
        failure: AgentFailureReason,
        intent: AgentIntentFingerprint,
        cycle: Int
    ) -> RecoveryDecision {
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
        case .exhausted:
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
