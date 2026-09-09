public struct ComputerAgentProviderContinuation: Codable, Equatable, Sendable {
    public let previousResponseID: String?
    public let pendingComputerCallID: String?

    public init(
        previousResponseID: String? = nil,
        pendingComputerCallID: String? = nil
    ) {
        self.previousResponseID = previousResponseID
        self.pendingComputerCallID = pendingComputerCallID
    }
}

public struct ComputerAgentProviderContext: Codable, Equatable, Sendable {
    public let sessionID: String
    public let taskID: String
    public let goalID: String
    public let goal: String
    public let stateVersion: UInt64
    public let observationID: String
    public let workingMemory: [String]
    public let continuation: ComputerAgentProviderContinuation?

    public init(
        sessionID: String,
        taskID: String,
        goalID: String,
        goal: String,
        stateVersion: UInt64,
        observationID: String,
        workingMemory: [String],
        continuation: ComputerAgentProviderContinuation? = nil
    ) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.goalID = goalID
        self.goal = goal
        self.stateVersion = stateVersion
        self.observationID = observationID
        self.workingMemory = workingMemory
        self.continuation = continuation
    }
}

public struct ComputerAgentProposal: Codable, Equatable, Sendable {
    public let observationID: String
    public let stateVersion: UInt64
    public let continuation: ComputerAgentProviderContinuation?

    public init(
        observationID: String,
        stateVersion: UInt64,
        continuation: ComputerAgentProviderContinuation? = nil
    ) {
        self.observationID = observationID
        self.stateVersion = stateVersion
        self.continuation = continuation
    }
}

public protocol ComputerAgentProvider: Sendable {
    func propose(context: ComputerAgentProviderContext) async throws -> ComputerAgentProposal
}
