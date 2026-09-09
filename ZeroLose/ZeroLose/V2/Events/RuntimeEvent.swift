import Foundation

enum RuntimeEventKind: String, Codable, Sendable {
    case goal
    case taskGraph
    case budget
    case observation
    case planning
    case tool
    case policy
    case approval
    case evidence
    case verification
    case recovery
    case memory
    case runtime
    case checkpoint
    case reconciliation
}

enum RedactionClass: String, Codable, Sendable {
    case normal
    case privateContent
    case credentialMaterial

    var isPersistable: Bool {
        self != .credentialMaterial
    }
}

struct RuntimeEvent: Codable, Sendable, Equatable {
    let eventID: RuntimeEventID
    let streamID: String
    let sequence: UInt64
    let schemaVersion: UInt32
    let goalID: GoalID?
    let taskID: TaskID?
    let sessionID: SessionID?
    let eventKind: RuntimeEventKind
    let causationID: String?
    let correlationID: String?
    let taskGraphRevision: UInt64?
    let toolRegistryRevision: UInt64?
    let policyRevision: UInt64?
    let payload: Data
    let redactionClass: RedactionClass
    let provenance: String?
    let tainted: Bool
    let recordedAt: Date
}
