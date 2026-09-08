import Foundation

public enum ComputerAgentTaskProfile: String, Codable, Equatable {
    case exam
}

public struct ProviderConversationState: Codable, Equatable {
    public private(set) var previousResponseID: String?
    public private(set) var pendingComputerCallID: String?

    public init(
        previousResponseID: String? = nil,
        pendingComputerCallID: String? = nil
    ) {
        self.previousResponseID = previousResponseID
        self.pendingComputerCallID = pendingComputerCallID
    }

    fileprivate mutating func updatePreviousResponseID(_ value: String?) {
        previousResponseID = value
    }

    fileprivate mutating func apply(turn: ComputerAgentProviderTurn) {
        previousResponseID = turn.responseID
        pendingComputerCallID = turn.computerCallID
    }
}

public enum AgentStopState: String, Codable, Equatable {
    case running
    case stopRequested
    case stopped
}

public final class ComputerAgentSession {
    public let id: String
    public let goal: String
    public let taskProfile: ComputerAgentTaskProfile
    public let workingMemory: AgentWorkingMemory

    public private(set) var runtimeState: ExamRuntimeState
    public private(set) var providerConversationState: ProviderConversationState
    public private(set) var stopState: AgentStopState
    public private(set) var lastPlannerSummary: String?

    private var memorySequence: UInt64

    public init(
        id: String = UUID().uuidString,
        goal: String,
        taskProfile: ComputerAgentTaskProfile = .exam,
        initialRuntimeState: ExamRuntimeState = ExamRuntimeState(),
        workingMemory: AgentWorkingMemory = AgentWorkingMemory(),
        providerConversationState: ProviderConversationState = ProviderConversationState(),
        stopState: AgentStopState = .running,
        lastPlannerSummary: String? = nil
    ) {
        self.id = id
        self.goal = goal
        self.taskProfile = taskProfile
        self.runtimeState = initialRuntimeState
        self.workingMemory = workingMemory
        self.providerConversationState = providerConversationState
        self.stopState = stopState
        self.lastPlannerSummary = lastPlannerSummary
        self.memorySequence = 0
    }

    public func acceptObservation() {
        runtimeState.acceptObservation()
    }

    public func recordAnswerVerified() {
        runtimeState.recordAnswerVerified()
    }

    public func beginBoundaryTransition() {
        runtimeState.beginBoundaryTransition()
    }

    public func completeBoundaryTransition() {
        runtimeState.completeBoundaryTransition()
    }

    public func failBoundaryTransition() {
        runtimeState.failBoundaryTransition()
    }

    public func cancelBoundaryTransition() {
        runtimeState.cancelBoundaryTransition()
    }

    public func recordPlannerSummary(_ summary: String?) {
        lastPlannerSummary = summary
    }

    public func updatePreviousResponseID(_ value: String?) {
        providerConversationState.updatePreviousResponseID(value)
    }

    public func applyProviderTurn(_ turn: ComputerAgentProviderTurn) {
        providerConversationState.apply(turn: turn)
    }

    public func computerProviderState() -> ComputerAgentProviderState {
        ComputerAgentProviderState(
            sessionID: id,
            goal: goal,
            stateVersion: runtimeState.stateVersion,
            questionGeneration: runtimeState.questionGeneration,
            answerVerified: runtimeState.answerState == .verified,
            uiPhase: runtimeState.uiPhase,
            workingMemory: workingMemory.snapshot(),
            previousResponseID: providerConversationState.previousResponseID,
            pendingComputerCallID: providerConversationState.pendingComputerCallID
        )
    }

    public func requestStop() {
        guard stopState == .running else { return }
        stopState = .stopRequested
    }

    public func markStopped() {
        stopState = .stopped
    }

    public func recordAction(_ intent: AgentIntentFingerprint) {
        workingMemory.recordAction(
            intent,
            sequence: nextMemorySequence(),
            stateVersion: runtimeState.stateVersion,
            questionGeneration: runtimeState.questionGeneration
        )
    }

    public func recordFailure(
        _ reason: AgentFailureReason,
        recoveryStrategy: RecoveryStrategy?
    ) {
        workingMemory.recordFailure(
            reason,
            recoveryStrategy: recoveryStrategy,
            sequence: nextMemorySequence(),
            stateVersion: runtimeState.stateVersion,
            questionGeneration: runtimeState.questionGeneration
        )
    }

    public func recordEvidence(_ outcome: ExpectedOutcomeKind) {
        workingMemory.recordEvidence(
            outcome,
            sequence: nextMemorySequence(),
            stateVersion: runtimeState.stateVersion,
            questionGeneration: runtimeState.questionGeneration
        )
    }

    public func setCurrentRecoveryStrategy(_ strategy: RecoveryStrategy?) {
        workingMemory.setCurrentRecoveryStrategy(strategy)
    }

    private func nextMemorySequence() -> UInt64 {
        if memorySequence < UInt64.max {
            memorySequence += 1
        }
        return memorySequence
    }
}
