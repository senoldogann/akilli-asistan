import Foundation

nonisolated struct VerifiedRuntimeEvidenceSnapshot: Sendable, Equatable {
    let evidenceID: String
    let summary: String
    let recordedAt: Date
    let tainted: Bool
    let sensitivity: ContextSensitivity
}

nonisolated protocol VerifiedRuntimeEvidenceProviding: Sendable {
    func verifiedEvidence(
        conversationID: String,
        activeGoalID: GoalID?
    ) async -> [VerifiedRuntimeEvidenceSnapshot]
}

nonisolated struct RuntimeEvidenceContextSource: ContextSource {
    let kind: ContextSourceKind = .runtimeEvidence

    private let provider: any VerifiedRuntimeEvidenceProviding

    init(provider: any VerifiedRuntimeEvidenceProviding) {
        self.provider = provider
    }

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        let snapshots = await provider.verifiedEvidence(
            conversationID: query.conversationID,
            activeGoalID: query.activeGoalID
        )

        return try snapshots.compactMap { snapshot in
            guard snapshot.sensitivity != .credentialMaterial else {
                return nil
            }

            return try ContextItem.validated(
                content: snapshot.summary,
                provenance: ContextProvenance(
                    sourceID: "runtime-evidence:\(snapshot.evidenceID)",
                    kind: .runtimeEvidence,
                    timestamp: snapshot.recordedAt,
                    tainted: snapshot.tainted,
                    sensitivity: snapshot.sensitivity
                ),
                mandatory: false,
                sourceScore: 0
            )
        }
    }
}
