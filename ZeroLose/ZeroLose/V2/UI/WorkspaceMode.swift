import Foundation

nonisolated enum WorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case chat = "Chat"
    case agent = "Agent"

    var id: Self { self }
}
