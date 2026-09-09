import Foundation

enum PluginToolProviderError: Error, Equatable {
    case invalidDescriptor
    case undeclaredCapability(String)
    case credentialScopeMismatch
}

struct PluginToolProvider: ToolProviding {
    let providerID: String

    private let manifest: PluginManifest
    private let boundary: PluginExecutionBoundary

    init(manifest: PluginManifest, boundary: PluginExecutionBoundary) {
        self.manifest = manifest
        self.boundary = boundary
        self.providerID = "plugin.\(manifest.id)"
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
            throw PluginToolProviderError.invalidDescriptor
        }

        let capability = String(descriptor.id.rawValue.dropFirst(namespacePrefix.count))
        guard !capability.isEmpty,
              manifest.capabilities.contains(capability) else {
            throw PluginToolProviderError.undeclaredCapability(capability)
        }

        let manifestScopes = Set(manifest.credentialScopes)
        guard descriptor.requiredCredentialScopes == manifestScopes else {
            throw PluginToolProviderError.credentialScopeMismatch
        }

        let handleScopes = Set(credentialHandles.map(\.scope.rawValue))
        guard handleScopes == manifestScopes else {
            throw PluginToolProviderError.credentialScopeMismatch
        }

        let startedAt = Date()
        _ = try await boundary.invoke(
            pluginID: manifest.id,
            capability: capability,
            argumentsJSON: invocation.argumentsJSON
        )
        let completedAt = Date()

        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: startedAt,
            completedAt: completedAt,
            providerReference: "plugin:\(manifest.id)@\(manifest.version)"
        )
    }
}
