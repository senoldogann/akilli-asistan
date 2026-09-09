import Foundation

struct RuntimeCheckpoint: Codable, Sendable, Equatable {
    let streamID: String
    let eventSequence: UInt64
    let taskGraphRevision: UInt64
    let taskGraphSnapshot: Data
    let lifecycleSnapshot: Data
    let budgetSnapshot: Data
    let boundedWorkingMemory: Data
    let providerContinuationMetadata: Data?
    let createdAt: Date

    func restoredRuntimeState() -> RestoredRuntimeState {
        RestoredRuntimeState(
            lifecycle: .paused,
            requiresReconciliation: true
        )
    }
}

enum RestoredRuntimeLifecycle: String, Codable, Sendable, Equatable {
    case paused
}

struct RestoredRuntimeState: Sendable, Equatable {
    let lifecycle: RestoredRuntimeLifecycle
    let requiresReconciliation: Bool
}
