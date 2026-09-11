import Foundation

enum MemoryScope: Hashable, Codable, Sendable {
    case session(SessionID)
    case goal(GoalID)
    case workspace(String)
    case application(String)
    case user

    var storageKey: String {
        switch self {
        case .session(let sessionID):
            return "session:\(sessionID.rawValue)"
        case .goal(let goalID):
            return "goal:\(goalID.rawValue)"
        case .workspace(let workspaceID):
            return "workspace:\(workspaceID)"
        case .application(let applicationID):
            return "application:\(applicationID)"
        case .user:
            return "user"
        }
    }
}

enum MemoryProvenance: String, Codable, Sendable {
    case user
    case runtimeEvidence
    case externalDocument
    case toolResult
    case derived
}

struct MemoryCandidate: Sendable, Equatable {
    let content: String
    let scope: MemoryScope
    let provenance: MemoryProvenance
    let confidence: Double
    let tainted: Bool
    let sourceEvidenceID: String?
}

struct EpisodicMemoryRecord: Codable, Sendable, Equatable {
    let id: String
    let scope: MemoryScope
    let summary: String
    let confidence: Double
    let provenance: MemoryProvenance
    let tainted: Bool
    let createdAt: Date
    let confirmedAt: Date?
    let invalidatedAt: Date?
}

struct SemanticMemoryRecord: Codable, Sendable, Equatable {
    let id: String
    let scope: MemoryScope
    let fact: String
    let confidence: Double
    let provenance: MemoryProvenance
    let tainted: Bool
    let createdAt: Date
    let confirmedAt: Date?
    let invalidatedAt: Date?
}

struct ProceduralMemoryRecord: Codable, Sendable, Equatable {
    let id: String
    let scope: MemoryScope
    let strategyID: String
    let successes: Int
    let failures: Int
    let confidence: Double
    let provenance: MemoryProvenance
    let tainted: Bool
    let createdAt: Date
    let confirmedAt: Date?
    let invalidatedAt: Date?
}

enum MemoryRecord: Codable, Sendable, Equatable {
    case episodic(EpisodicMemoryRecord)
    case semantic(SemanticMemoryRecord)
    case procedural(ProceduralMemoryRecord)

    var id: String {
        switch self {
        case .episodic(let record): record.id
        case .semantic(let record): record.id
        case .procedural(let record): record.id
        }
    }

    var scope: MemoryScope {
        switch self {
        case .episodic(let record): record.scope
        case .semantic(let record): record.scope
        case .procedural(let record): record.scope
        }
    }

    var kind: String {
        switch self {
        case .episodic: "episodic"
        case .semantic: "semantic"
        case .procedural: "procedural"
        }
    }
}
