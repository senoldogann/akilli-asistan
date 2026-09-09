import Foundation

enum ToolFabricError: Error, Equatable {
    case unknownTool(ToolID)
    case staleRegistryRevision(expected: UInt64, actual: UInt64)
    case staleDescriptorRevision(expected: UInt64, actual: UInt64)
    case schemaDigestMismatch(expected: String, actual: String)
    case missingLogicalOperationKey
    case policyDenied(PolicyDenialReason)
}

actor ToolFabric {
    private let registry: ToolRegistry
    private let policy: PolicyEvaluating
    private let credentialBroker: CredentialBrokering
    private let providersByID: [String: ToolProviding]
    private var authorityMode: AuthorityMode

    init(
        registry: ToolRegistry,
        policy: PolicyEvaluating,
        credentialBroker: CredentialBrokering,
        providers: [ToolProviding],
        authorityMode: AuthorityMode
    ) {
        self.registry = registry
        self.policy = policy
        self.credentialBroker = credentialBroker
        self.providersByID = Dictionary(
            providers.map { ($0.providerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.authorityMode = authorityMode
    }

    func setAuthorityMode(_ mode: AuthorityMode) {
        authorityMode = mode
    }

    func execute(_ invocation: ToolInvocation) async throws -> ToolExecutionReceipt {
        let snapshot = await registry.snapshot()

        guard snapshot.revision == invocation.registryRevision else {
            throw ToolFabricError.staleRegistryRevision(
                expected: snapshot.revision,
                actual: invocation.registryRevision
            )
        }

        guard let descriptor = snapshot.descriptors[invocation.toolID], descriptor.enabled else {
            throw ToolFabricError.unknownTool(invocation.toolID)
        }

        guard descriptor.descriptorRevision == invocation.descriptorRevision else {
            throw ToolFabricError.staleDescriptorRevision(
                expected: descriptor.descriptorRevision,
                actual: invocation.descriptorRevision
            )
        }

        guard descriptor.schemaDigest == invocation.schemaDigest else {
            throw ToolFabricError.schemaDigestMismatch(
                expected: descriptor.schemaDigest,
                actual: invocation.schemaDigest
            )
        }

        if descriptor.idempotency == .logicalOperationKeyRequired {
            guard let logicalOperationKey = invocation.logicalOperationKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !logicalOperationKey.isEmpty else {
                throw ToolFabricError.missingLogicalOperationKey
            }
        }

        let provider = providersByID[descriptor.providerID]
        let requiredScopes = descriptor.requiredCredentialScopes.sorted()

        var credentialScopeSatisfied = true
        for rawScope in requiredScopes {
            let availability = await credentialBroker.availability(
                for: CredentialScope(rawValue: rawScope)
            )
            if !availability.available {
                credentialScopeSatisfied = false
                break
            }
        }

        let decision = await policy.evaluate(
            PolicyContext(
                authorityMode: authorityMode,
                declaredRisk: descriptor.declaredRisk,
                effectClass: descriptor.effectClass,
                capabilityKnown: provider != nil,
                credentialScopeSatisfied: credentialScopeSatisfied,
                tainted: false,
                toolID: descriptor.id.rawValue,
                taskID: nil,
                destination: nil,
                argumentsDigest: nil
            )
        )

        switch decision {
        case .allow:
            break
        case .deny(let reason):
            throw ToolFabricError.policyDenied(reason)
        }

        guard let provider else {
            throw ToolFabricError.policyDenied(.unknownCapability)
        }

        var handles: [CredentialHandle] = []
        handles.reserveCapacity(requiredScopes.count)
        for rawScope in requiredScopes {
            handles.append(
                try await credentialBroker.issueHandle(
                    for: CredentialScope(rawValue: rawScope)
                )
            )
        }

        return try await provider.execute(
            descriptor: descriptor,
            invocation: invocation,
            credentialHandles: handles
        )
    }
}
