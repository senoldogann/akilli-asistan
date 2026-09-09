enum MutationReconciliationPolicy: Sendable {
    case failClosedForUnknownHighRisk
}

enum MutationReconciliationDecision: Sendable, Equatable {
    case alreadyApplied
    case retryPermitted
    case requiresReobservation
    case requiresManualResolution
}

struct MutationReconciler: Sendable {
    let policy: MutationReconciliationPolicy

    func decide(record: ExternalMutationRecord) async -> MutationReconciliationDecision {
        switch record.externalState {
        case .alreadyApplied:
            return .alreadyApplied
        case .notApplied:
            return .retryPermitted
        case .unknown:
            switch policy {
            case .failClosedForUnknownHighRisk:
                if record.risk >= .highImpactExternalMutation {
                    return .requiresManualResolution
                }
                return .requiresReobservation
            }
        }
    }
}
