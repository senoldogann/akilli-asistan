import Foundation

nonisolated struct ConversationContextSource: ContextSource {
    let kind: ContextSourceKind = .conversation

    private let store: any ConversationStoring
    private let maxMessages: Int

    init(store: any ConversationStoring, maxMessages: Int = 12) {
        self.store = store
        self.maxMessages = max(0, maxMessages)
    }

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        guard maxMessages > 0 else { return [] }

        let messages = try await store.messages(conversationID: query.conversationID)
        let ordered = messages.sorted { lhs, rhs in
            if lhs.recordedAt == rhs.recordedAt {
                return lhs.id < rhs.id
            }
            return lhs.recordedAt < rhs.recordedAt
        }

        return try ordered.suffix(maxMessages).map { message in
            try ContextItem.validated(
                content: message.text,
                provenance: ContextProvenance(
                    sourceID: "conversation:\(message.id):\(message.provenance.source.rawValue)",
                    kind: .conversation,
                    timestamp: message.recordedAt,
                    tainted: false,
                    sensitivity: .privateContent
                ),
                mandatory: false,
                sourceScore: 0
            )
        }
    }
}
