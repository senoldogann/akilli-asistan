import Foundation

public enum AgentEventKind: String, Codable, Equatable {
    case observationAccepted
    case proposalReceived
    case policyDenied
    case batchValidated
    case actionExecuted
    case answerVerified
    case outcomeVerified
    case outcomePending
    case boundaryTransitionStarted
    case boundaryTransitionCompleted
    case verificationFailed
    case stabilityWaiting
    case recoveryPlanned
    case recoveryExhausted
}

public struct AgentEvent: Codable, Equatable {
    public let kind: AgentEventKind
    public let cycle: Int
    public let stateVersion: UInt64
    public let questionGeneration: UInt64
    public let detail: String

    public init(
        kind: AgentEventKind,
        cycle: Int,
        stateVersion: UInt64,
        questionGeneration: UInt64,
        detail: String
    ) {
        self.kind = kind
        self.cycle = cycle
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.detail = detail
    }
}

public protocol AgentEventSinking: AnyObject {
    func record(_ event: AgentEvent)
}

public final class NullAgentEventSink: AgentEventSinking {
    public init() {}

    public func record(_ event: AgentEvent) {}
}
