public struct ComputerAgentSession: Sendable {
    public let sessionID: String
    public let goalID: String
    public let taskID: String
    public let goal: String
    public let profileID: String

    public private(set) var stateVersion: UInt64
    public private(set) var currentObservationID: String?

    public init(
        sessionID: String,
        goalID: String,
        taskID: String,
        goal: String,
        profileID: String
    ) {
        self.sessionID = sessionID
        self.goalID = goalID
        self.taskID = taskID
        self.goal = goal
        self.profileID = profileID
        stateVersion = 0
        currentObservationID = nil
    }

    @discardableResult
    public mutating func acceptObservation(id: String) -> ComputerObservation {
        stateVersion += 1
        currentObservationID = id
        return ComputerObservation(observationID: id, stateVersion: stateVersion)
    }

    public func isCurrent(observationID: String, stateVersion: UInt64) -> Bool {
        currentObservationID == observationID && self.stateVersion == stateVersion
    }
}
