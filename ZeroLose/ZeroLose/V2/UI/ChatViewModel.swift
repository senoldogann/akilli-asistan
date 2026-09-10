import Foundation
import Observation

struct ChatPresentation: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    let isUser: Bool
}

struct ChatProjectionSnapshot: Sendable, Equatable {
    let messages: [ChatPresentation]
}

@MainActor
@Observable
final class ChatViewModel {
    private(set) var messages: [ChatPresentation] = []
    private let commandSender: any ApplicationCommandSending

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: ChatProjectionSnapshot) {
        messages = snapshot.messages
    }

    func submit(_ text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try await commandSender.send(.sendChatMessage(normalized))
    }
}
