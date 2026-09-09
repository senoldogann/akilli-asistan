import Foundation

protocol MCPClient: Sendable {
    func listTools() async throws -> [MCPDiscoveredTool]
    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolResult
}
