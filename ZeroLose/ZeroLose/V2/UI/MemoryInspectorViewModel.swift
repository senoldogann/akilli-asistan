import Observation

struct MemoryPresentation: Identifiable, Sendable, Equatable {
    let id: String
    let summary: String
    let pinned: Bool
}

struct MemoryProjectionSnapshot: Sendable, Equatable {
    let entries: [MemoryPresentation]
}

@MainActor
@Observable
final class MemoryInspectorViewModel {
    private(set) var entries: [MemoryPresentation] = []
    private let commandSender: any ApplicationCommandSending

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: MemoryProjectionSnapshot) {
        entries = snapshot.entries
    }

    func pin(_ id: String) async throws {
        try await commandSender.send(.pinMemoryEntry(id))
    }

    func forget(_ id: String) async throws {
        try await commandSender.send(.forgetMemoryEntry(id))
    }
}
