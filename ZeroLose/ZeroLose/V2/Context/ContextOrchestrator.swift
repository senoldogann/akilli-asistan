import Foundation

nonisolated struct ContextPolicy: Sendable, Equatable {
    let maxCharacters: Int
    let minimumRelevance: Double

    init(maxCharacters: Int, minimumRelevance: Double) {
        self.maxCharacters = max(0, maxCharacters)
        self.minimumRelevance = min(1, max(0, minimumRelevance))
    }
}

nonisolated struct ContextExclusion: Sendable, Equatable {
    nonisolated enum Reason: String, Sendable, Equatable {
        case belowThreshold
        case duplicate
        case budgetExceeded
        case credentialMaterial
        case empty
        case sourceFailure
    }

    let sourceID: String
    let reason: Reason
}

nonisolated struct ContextBundle: Sendable, Equatable {
    let items: [ContextItem]
    let excluded: [ContextExclusion]
    let usedCharacters: Int
}

nonisolated struct ContextOrchestrator: Sendable {
    private let sources: [any ContextSource]
    private let policy: ContextPolicy
    private let scorer: ContextScorer

    init(
        sources: [any ContextSource],
        policy: ContextPolicy,
        scorer: ContextScorer = ContextScorer()
    ) {
        self.sources = sources
        self.policy = policy
        self.scorer = scorer
    }

    func buildContext(for query: ContextQuery) async throws -> ContextBundle {
        var candidates: [ScoredContextCandidate] = []
        var excluded: [ContextExclusion] = []

        for source in sources {
            do {
                let sourceCandidates = try await source.candidates(for: query)
                candidates.append(contentsOf: sourceCandidates.map { item in
                    ScoredContextCandidate(
                        item: item,
                        finalScore: max(
                            item.sourceScore,
                            scorer.lexicalOverlap(query: query.text, candidate: item.content)
                        )
                    )
                })
            } catch {
                excluded.append(
                    ContextExclusion(
                        sourceID: "source:\(source.kind.rawValue)",
                        reason: .sourceFailure
                    )
                )
            }
        }

        let ranked = candidates.sorted(by: ranksBefore)
        var seenContent = Set<String>()
        var unique: [ScoredContextCandidate] = []

        for candidate in ranked {
            let key = normalizedContent(candidate.item.content)
            guard seenContent.insert(key).inserted else {
                excluded.append(
                    ContextExclusion(
                        sourceID: candidate.item.provenance.sourceID,
                        reason: .duplicate
                    )
                )
                continue
            }
            unique.append(candidate)
        }

        var selected: [ContextItem] = []
        var usedCharacters = 0

        for candidate in unique {
            let item = candidate.item

            if !item.mandatory && candidate.finalScore < policy.minimumRelevance {
                excluded.append(
                    ContextExclusion(
                        sourceID: item.provenance.sourceID,
                        reason: .belowThreshold
                    )
                )
                continue
            }

            let remaining = policy.maxCharacters - usedCharacters
            guard remaining > 0 else {
                excluded.append(
                    ContextExclusion(
                        sourceID: item.provenance.sourceID,
                        reason: .budgetExceeded
                    )
                )
                continue
            }

            if item.content.count <= remaining {
                selected.append(item)
                usedCharacters += item.content.count
                continue
            }

            excluded.append(
                ContextExclusion(
                    sourceID: item.provenance.sourceID,
                    reason: .budgetExceeded
                )
            )

            guard item.mandatory else {
                continue
            }

            let truncatedContent = String(item.content.prefix(remaining))
            guard !truncatedContent.isEmpty else {
                continue
            }

            let truncated = try ContextItem.validated(
                content: truncatedContent,
                provenance: item.provenance,
                mandatory: true,
                sourceScore: item.sourceScore
            )
            selected.append(truncated)
            usedCharacters += truncated.content.count
        }

        return ContextBundle(
            items: selected,
            excluded: excluded,
            usedCharacters: usedCharacters
        )
    }

    private func ranksBefore(_ lhs: ScoredContextCandidate, _ rhs: ScoredContextCandidate) -> Bool {
        if lhs.item.mandatory != rhs.item.mandatory {
            return lhs.item.mandatory
        }

        if lhs.finalScore != rhs.finalScore {
            return lhs.finalScore > rhs.finalScore
        }

        let lhsPriority = sourcePriority(lhs.item.provenance.kind)
        let rhsPriority = sourcePriority(rhs.item.provenance.kind)
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }

        switch (lhs.item.provenance.timestamp, rhs.item.provenance.timestamp) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        return lhs.item.provenance.sourceID < rhs.item.provenance.sourceID
    }

    private func sourcePriority(_ kind: ContextSourceKind) -> Int {
        switch kind {
        case .activeTask: 5
        case .runtimeEvidence: 4
        case .attachment: 3
        case .conversation: 2
        case .memory: 1
        }
    }

    private func normalizedContent(_ content: String) -> String {
        ContextScorer.tokens(content).joined(separator: " ")
    }
}

private nonisolated struct ScoredContextCandidate: Sendable {
    let item: ContextItem
    let finalScore: Double
}
