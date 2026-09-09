import Foundation

struct MCPToolAnnotations: Sendable, Equatable, Codable {
    let readOnlyHint: Bool?
    let destructiveHint: Bool?
    let idempotentHint: Bool?
    let openWorldHint: Bool?
}

struct MCPDiscoveredTool: Sendable, Equatable {
    let name: String
    let description: String?
    let inputSchemaJSON: Data
    let outputSchemaJSON: Data?
    let annotations: MCPToolAnnotations
}

struct MCPToolResult: Sendable, Equatable {
    let contentJSON: Data
    let providerReference: String?
    let provenance: String
    let tainted: Bool
}
