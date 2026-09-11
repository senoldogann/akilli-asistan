import Foundation

nonisolated protocol MutableAttachmentContextProviding: AttachmentContextProviding {
    func replaceAttachments(
        _ snapshots: [AttachmentContextSnapshot],
        conversationID: String
    ) async
    func clearAttachments(conversationID: String) async
}

actor AttachmentContextBuffer: MutableAttachmentContextProviding {
    private var snapshotsByConversation: [String: [AttachmentContextSnapshot]] = [:]

    func attachments(conversationID: String) async -> [AttachmentContextSnapshot] {
        snapshotsByConversation[conversationID] ?? []
    }

    func replaceAttachments(
        _ snapshots: [AttachmentContextSnapshot],
        conversationID: String
    ) async {
        if snapshots.isEmpty {
            snapshotsByConversation.removeValue(forKey: conversationID)
        } else {
            snapshotsByConversation[conversationID] = snapshots
        }
    }

    func clearAttachments(conversationID: String) async {
        snapshotsByConversation.removeValue(forKey: conversationID)
    }
}
