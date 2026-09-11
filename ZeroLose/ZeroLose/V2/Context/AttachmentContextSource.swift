import Foundation

nonisolated struct AttachmentContextSnapshot: Sendable, Equatable {
    let id: String
    let displayName: String
    let extractedText: String
    let recordedAt: Date
}

nonisolated protocol AttachmentContextProviding: Sendable {
    func attachments(conversationID: String) async -> [AttachmentContextSnapshot]
}

nonisolated struct AttachmentContextSource: ContextSource {
    let kind: ContextSourceKind = .attachment

    private let provider: any AttachmentContextProviding

    init(provider: any AttachmentContextProviding) {
        self.provider = provider
    }

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        let snapshots = await provider.attachments(conversationID: query.conversationID)

        return try snapshots.map { snapshot in
            try ContextItem.validated(
                content: snapshot.extractedText,
                provenance: ContextProvenance(
                    sourceID: "attachment:\(snapshot.id)",
                    kind: .attachment,
                    timestamp: snapshot.recordedAt,
                    tainted: true,
                    sensitivity: .privateContent
                ),
                mandatory: false,
                sourceScore: 0
            )
        }
    }
}
