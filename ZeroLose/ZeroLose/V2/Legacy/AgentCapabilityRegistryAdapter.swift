import Foundation

struct AgentCapabilityRegistryAdapter {
    private let capabilities: [AgentCapability]

    init(capabilities: [AgentCapability] = AgentCapabilityRegistry.all) {
        self.capabilities = capabilities
    }

    func descriptors() -> [ToolDescriptor] {
        capabilities
            .map(Self.descriptor(for:))
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func descriptor(for capability: AgentCapability) -> ToolDescriptor {
        let effectClass = effectClass(for: capability)

        return ToolDescriptor(
            id: ToolID(rawValue: "builtin.legacy.\(capability.id)"),
            providerID: "legacy.inventory",
            provenance: "legacy.AgentCapabilityRegistry.inventory",
            descriptorRevision: 1,
            schemaDigest: "legacy-inventory-v1:opaque-object",
            inputSchemaJSON: Data(#"{"type":"object","additionalProperties":true}"#.utf8),
            outputSchemaJSON: nil,
            effectClass: effectClass,
            declaredRisk: risk(for: effectClass),
            requiredCredentialScopes: [],
            idempotency: idempotency(for: effectClass),
            concurrencyClass: concurrencyClass(for: effectClass),
            verificationContract: verificationContract(for: effectClass),
            enabled: false
        )
    }

    private static func effectClass(for capability: AgentCapability) -> EffectClass {
        if externalCommunicationActions.contains(capability.actionType) {
            return .externalCommunication
        }

        if readOnlyActions.contains(capability.actionType) {
            return .read
        }

        return .reversibleLocalMutation
    }

    private static func risk(for effectClass: EffectClass) -> RiskLevel {
        switch effectClass {
        case .read:
            return .readOnly
        case .reversibleLocalMutation:
            return .reversibleLocalMutation
        case .externalCommunication:
            return .externalCommunication
        case .highImpactExternalMutation:
            return .highImpactExternalMutation
        case .irreversible:
            return .irreversible
        }
    }

    private static func idempotency(for effectClass: EffectClass) -> IdempotencySemantics {
        switch effectClass {
        case .externalCommunication, .highImpactExternalMutation, .irreversible:
            return .logicalOperationKeyRequired
        case .read, .reversibleLocalMutation:
            return .none
        }
    }

    private static func concurrencyClass(for effectClass: EffectClass) -> ToolConcurrencyClass {
        switch effectClass {
        case .read:
            return .read
        case .reversibleLocalMutation, .externalCommunication, .highImpactExternalMutation, .irreversible:
            return .mutation
        }
    }

    private static func verificationContract(for effectClass: EffectClass) -> VerificationContract {
        switch effectClass {
        case .read:
            return VerificationContract(kind: "legacy.inventory.read-observation")
        case .reversibleLocalMutation:
            return VerificationContract(kind: "legacy.inventory.local-mutation-verification")
        case .externalCommunication, .highImpactExternalMutation, .irreversible:
            return VerificationContract(kind: "legacy.inventory.external-mutation-verification")
        }
    }

    private static let readOnlyActions: Set<String> = [
        "web_search",
        "shell",
        "screenshot",
        "audio",
        "clipboard",
        "system_status",
        "computer_list",
        "computer_status",
        "computer_snapshot",
        "computer_ocr",
        "computer_inspect",
        "browser_audit",
        "computer_wait"
    ]

    private static let externalCommunicationActions: Set<String> = [
        "computer_submit",
        "browser_click",
        "browser_navigate"
    ]
}
