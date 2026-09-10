import Observation

struct ToolPresentation: Identifiable, Sendable, Equatable {
    var id: String { toolID.rawValue }
    let toolID: ToolID
    let enabled: Bool

    init(id: ToolID, enabled: Bool) {
        self.toolID = id
        self.enabled = enabled
    }
}

struct ToolManagementProjectionSnapshot: Sendable, Equatable {
    let tools: [ToolPresentation]
}

@MainActor
@Observable
final class ToolManagementViewModel {
    private(set) var tools: [ToolPresentation] = []
    private let commandSender: any ApplicationCommandSending

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: ToolManagementProjectionSnapshot) {
        tools = snapshot.tools
    }

    func enable(_ toolID: ToolID) async throws {
        try await commandSender.send(.enableTool(toolID))
    }

    func disable(_ toolID: ToolID) async throws {
        try await commandSender.send(.disableTool(toolID))
    }

    func setMCPServer(_ serverID: String, enabled: Bool) async throws {
        try await commandSender.send(enabled ? .enableMCPServer(serverID) : .disableMCPServer(serverID))
    }
}
