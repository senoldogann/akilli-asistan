import Foundation

public enum AgentPersistenceError: Error, Equatable, LocalizedError {
    case invalidSessionID
    case recordTooLarge
    case malformedRecord
    case storageFailure

    public var diagnosticID: String {
        switch self {
        case .invalidSessionID:
            return "invalid_session_id"
        case .recordTooLarge:
            return "record_too_large"
        case .malformedRecord:
            return "malformed_record"
        case .storageFailure:
            return "storage_failure"
        }
    }

    public var errorDescription: String? {
        "Agent persistence failed: \(diagnosticID)."
    }
}

public enum AgentPersistenceSanitizer {
    private static let allowedDetailCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-"
    )

    public static func detail(_ value: String) -> String {
        guard !value.isEmpty,
              value.count <= 64,
              value.unicodeScalars.allSatisfy({ allowedDetailCharacters.contains($0) }) else {
            return "redacted_detail"
        }
        return value
    }

    public static func event(_ event: AgentEvent) -> AgentEvent {
        AgentEvent(
            sessionID: event.sessionID,
            kind: event.kind,
            cycle: event.cycle,
            stateVersion: event.stateVersion,
            questionGeneration: event.questionGeneration,
            detail: detail(event.detail)
        )
    }
}

public struct StoredAgentEvent: Codable, Equatable {
    public let sequence: Int64
    public let event: AgentEvent

    public init(sequence: Int64, event: AgentEvent) {
        self.sequence = sequence
        self.event = AgentPersistenceSanitizer.event(event)
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case event
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        let decodedEvent = try container.decode(AgentEvent.self, forKey: .event)
        event = AgentPersistenceSanitizer.event(decodedEvent)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(event, forKey: .event)
    }
}

public struct AgentConversationRecord: Codable, Equatable {
    public let sessionID: String
    public let state: ProviderConversationState

    public init(sessionID: String, state: ProviderConversationState) {
        self.sessionID = sessionID
        self.state = state
    }
}

public struct AgentMemoryRecord: Codable, Equatable {
    public let sessionID: String
    public let snapshot: AgentWorkingMemorySnapshot

    public init(sessionID: String, snapshot: AgentWorkingMemorySnapshot) {
        self.sessionID = sessionID
        self.snapshot = snapshot
    }
}

public protocol AgentEventStore: AnyObject {
    @discardableResult
    func append(_ event: AgentEvent) throws -> StoredAgentEvent
    func events(sessionID: String) throws -> [StoredAgentEvent]
}

public protocol AgentConversationStore: AnyObject {
    func saveConversation(_ record: AgentConversationRecord) throws
    func conversation(sessionID: String) throws -> AgentConversationRecord?
}

public protocol AgentMemoryStore: AnyObject {
    func saveMemory(_ record: AgentMemoryRecord) throws
    func memory(sessionID: String) throws -> AgentMemoryRecord?
}
