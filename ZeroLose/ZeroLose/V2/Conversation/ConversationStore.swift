import Foundation

enum ConversationRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case transcript
}

enum ConversationProvenanceSource: String, Codable, Sendable, Equatable {
    case legacyVectorStore
    case native
}

struct ConversationProvenance: Codable, Sendable, Equatable {
    let source: ConversationProvenanceSource
    let sourceRecordID: String?
    let sourceSessionID: String?

    nonisolated init(
        source: ConversationProvenanceSource,
        sourceRecordID: String? = nil,
        sourceSessionID: String? = nil
    ) {
        self.source = source
        self.sourceRecordID = sourceRecordID
        self.sourceSessionID = sourceSessionID
    }
}

struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let conversationID: String
    let role: ConversationRole
    let text: String
    let recordedAt: Date
    let provenance: ConversationProvenance
    let verifiedSemanticTruth: Bool

    nonisolated init(
        id: String,
        conversationID: String,
        role: ConversationRole,
        text: String,
        recordedAt: Date,
        provenance: ConversationProvenance,
        verifiedSemanticTruth: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.recordedAt = recordedAt
        self.provenance = provenance
        self.verifiedSemanticTruth = verifiedSemanticTruth
    }
}

protocol ConversationStoring: Sendable {
    func save(_ message: ConversationMessage) async throws
    func message(id: String) async throws -> ConversationMessage?
    func messages(conversationID: String) async throws -> [ConversationMessage]
    func count() async throws -> Int
}
