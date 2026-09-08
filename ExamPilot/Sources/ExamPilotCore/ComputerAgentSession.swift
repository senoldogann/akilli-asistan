import Foundation

public enum ComputerAgentTaskProfile: String, Codable, Equatable {
    case exam
}

public struct ProviderConversationState: Codable, Equatable {
    public private(set) var previousResponseID: String?

    public init(previousResponseID: String? = nil) {
        self.previousResponseID = previousResponseID
    }

    fileprivate mutating func updatePreviousResponseID(_ value: String?) {
        previousResponseID = value
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

    private var memorySequence: UInt64

    public init(
        id: String = UUID().uuidString,
        goal: String,
        taskProfile: ComputerAgentTaskProfile = .exam,
        initialRuntimeState: ExamRuntimeState = ExamRuntimeState(),
        workingMemory: AgentWorkingMemory = AgentWorkingMemory(),
        providerConversationState: ProviderConversationState = ProviderConversationState(),
        stopState: AgentStopState = .running
    ) {
        self.id = id
        self.goal = goal
        self.taskProfile = taskProfile
        self.runtimeState = initialRuntimeState
        self.workingMemory = workingMemory
        self.providerConversationState = providerConversationState
        self.stopState = stopState
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

    public func updatePreviousResponseID(_ value: String?) {
        providerConversationState.updatePreviousResponseID(value)
    }

    public func requestStop() {
        guard stopState == .running else { return }
        stopState = .stopRequested
    }

    public func markStopped() {
        stopState = .stopped
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

    private func nextMemorySequence() -> UInt64 {
        if memorySequence < UInt64.max {
            memorySequence += 1
        }
        return memorySequence
    }
}
