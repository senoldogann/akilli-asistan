import Foundation

public enum PhysicalActionStatus: String, Codable, Equatable {
    case completed
}

public struct ActionExecutionReceipt: Codable, Equatable {
    public let actionIndex: Int
    public let kind: ExamActionKind
    public let stateVersion: UInt64
    public let startedAt: Date
    public let completedAt: Date
    public let status: PhysicalActionStatus

    public init(
        actionIndex: Int,
        kind: ExamActionKind,
        stateVersion: UInt64,
        startedAt: Date,
        completedAt: Date,
        status: PhysicalActionStatus
    ) {
        precondition(actionIndex >= 0, "actionIndex must be non-negative")
        self.actionIndex = actionIndex
        self.kind = kind
        self.stateVersion = stateVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
    }
}
