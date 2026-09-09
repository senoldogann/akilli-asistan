enum PolicyDenialReason: String, Sendable, Equatable {
    case unknownCapability
    case credentialScopeMissing
    case approvalRequired
    case hardPolicyDenied
}

enum PolicyDecision: Sendable, Equatable {
    case allow
    case deny(reason: PolicyDenialReason)
}

protocol PolicyEvaluating: Sendable {
    func evaluate(_ context: PolicyContext) async -> PolicyDecision
}

struct DefaultPolicyKernel: PolicyEvaluating {
    func evaluate(_ context: PolicyContext) async -> PolicyDecision {
        guard context.capabilityKnown else {
            return .deny(reason: .unknownCapability)
        }

        guard context.credentialScopeSatisfied else {
            return .deny(reason: .credentialScopeMissing)
        }

        let effectiveRisk = max(context.declaredRisk, context.effectClass.riskFloor)

        switch effectiveRisk {
        case .readOnly:
            return .allow
        case .reversibleLocalMutation:
            return context.authorityMode == .manual
                ? .deny(reason: .approvalRequired)
                : .allow
        case .externalCommunication:
            return context.authorityMode == .autonomous || context.authorityMode == .fullAccess
                ? .allow
                : .deny(reason: .approvalRequired)
        case .highImpactExternalMutation:
            return context.authorityMode == .fullAccess
                ? .allow
                : .deny(reason: .approvalRequired)
        case .irreversible:
            return .deny(reason: .hardPolicyDenied)
        }
    }
}

private extension EffectClass {
    var riskFloor: RiskLevel {
        switch self {
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
}
