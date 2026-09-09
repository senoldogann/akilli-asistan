import Foundation

enum MCPToolProviderError: Error, Equatable {
    case invalidDescriptor
    case duplicateToolID(ToolID)
    case registryCollision(ToolID)
}

struct MCPToolProvider: ToolProviding {
    let providerID: String

    private let client: MCPClient
    private let registry: ToolRegistry
    private let mapper: MCPToolMapper

    init(serverID: String, client: MCPClient, registry: ToolRegistry) {
        self.providerID = "mcp.\(serverID)"
        self.client = client
        self.registry = registry
        self.mapper = MCPToolMapper(serverID: serverID)
    }

    func refresh() async throws {
        let discoveredTools = try await client.listTools()
        var toolsByID: [ToolID: MCPDiscoveredTool] = [:]

        for tool in discoveredTools {
            let descriptor = try mapper.descriptor(for: tool)
            guard toolsByID[descriptor.id] == nil else {
                throw MCPToolProviderError.duplicateToolID(descriptor.id)
            }
            toolsByID[descriptor.id] = tool
        }

        let snapshot = await registry.snapshot()

        for id in toolsByID.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let tool = toolsByID[id] else { continue }
            let existing = snapshot.descriptors[id]

            if let existing, existing.providerID != providerID {
                throw MCPToolProviderError.registryCollision(id)
            }

            let comparisonRevision = existing?.descriptorRevision ?? 1
            let comparableDescriptor = try mapper.descriptor(
                for: tool,
                descriptorRevision: comparisonRevision
            )

            if existing == comparableDescriptor {
                continue
            }

            let nextRevision = existing.map { $0.descriptorRevision &+ 1 } ?? 1
            let descriptor = try mapper.descriptor(
                for: tool,
                descriptorRevision: nextRevision
            )
            await registry.register(descriptor)
        }

        let currentProviderIDs = Set(
            snapshot.descriptors.values
                .filter { $0.providerID == providerID }
                .map(\.id)
        )
        let discoveredIDs = Set(toolsByID.keys)
        let removedIDs = currentProviderIDs.subtracting(discoveredIDs)

        for id in removedIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            await registry.revoke(id)
        }
    }

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        let namespacePrefix = "\(providerID)."
        guard descriptor.providerID == providerID,
              descriptor.id == invocation.toolID,
              descriptor.id.rawValue.hasPrefix(namespacePrefix) else {
            throw MCPToolProviderError.invalidDescriptor
        }

        let toolName = String(descriptor.id.rawValue.dropFirst(namespacePrefix.count))
        guard !toolName.isEmpty else {
            throw MCPToolProviderError.invalidDescriptor
        }

        let startedAt = Date()
        let result = try await client.callTool(
            name: toolName,
            argumentsJSON: invocation.argumentsJSON
        )
        let completedAt = Date()

        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: startedAt,
            completedAt: completedAt,
            providerReference: result.providerReference
        )
    }
}
