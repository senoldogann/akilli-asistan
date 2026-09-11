import Foundation

nonisolated struct MemoryContextSource: ContextSource {
    let kind: ContextSourceKind = .memory

    private let store: any MemoryStoring
    private let additionalScopes: [MemoryScope]

    init(store: any MemoryStoring, additionalScopes: [MemoryScope] = []) {
        self.store = store
        self.additionalScopes = additionalScopes.filter { scope in
            if case .application = scope {
                return true
            }
            return false
        }
    }

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        var scopes: [MemoryScope] = [.user]
        if let activeGoalID = query.activeGoalID {
            scopes.append(.goal(activeGoalID))
        }
        scopes.append(contentsOf: additionalScopes)

        var seenRecordIDs = Set<String>()
        var orderedRecords: [MemoryRecord] = []

        for scope in scopes {
            let records = try await store.records(scope: scope)
            for record in records where seenRecordIDs.insert(record.id).inserted {
                orderedRecords.append(record)
            }
        }

        return try orderedRecords.compactMap { record in
            try contextItem(from: record)
        }
    }

    private func contextItem(from record: MemoryRecord) throws -> ContextItem? {
        switch record {
        case .semantic(let memory):
            guard memory.invalidatedAt == nil else { return nil }
            return try makeItem(
                id: memory.id,
                content: memory.fact,
                confidence: memory.confidence,
                provenance: memory.provenance,
                tainted: memory.tainted,
                timestamp: memory.createdAt,
                confirmedAt: memory.confirmedAt
            )

        case .episodic(let memory):
            guard memory.invalidatedAt == nil else { return nil }
            return try makeItem(
                id: memory.id,
                content: memory.summary,
                confidence: memory.confidence,
                provenance: memory.provenance,
                tainted: memory.tainted,
                timestamp: memory.createdAt,
                confirmedAt: memory.confirmedAt
            )

        case .procedural:
            return nil
        }
    }

    private func makeItem(
        id: String,
        content: String,
        confidence: Double,
        provenance: MemoryProvenance,
        tainted: Bool,
        timestamp: Date,
        confirmedAt: Date?
    ) throws -> ContextItem {
        try ContextItem.validated(
            content: content,
            provenance: ContextProvenance(
                sourceID: "memory:\(id):\(provenance.rawValue)",
                kind: .memory,
                timestamp: timestamp,
                tainted: tainted,
                sensitivity: .privateContent
            ),
            mandatory: false,
            sourceScore: sourceScore(
                confidence: confidence,
                provenance: provenance,
                confirmedAt: confirmedAt
            )
        )
    }

    private func sourceScore(
        confidence: Double,
        provenance: MemoryProvenance,
        confirmedAt: Date?
    ) -> Double {
        let clampedConfidence = min(1, max(0, confidence))

        switch provenance {
        case .user where confirmedAt != nil:
            return 1
        case .derived where confirmedAt == nil:
            return min(clampedConfidence, 0.6)
        default:
            return clampedConfidence
        }
    }
}
