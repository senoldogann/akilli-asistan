import Foundation

struct VaultSearchEngine {
    enum ResultKind: Hashable, Sendable {
        case category
        case item
    }

    struct Result: Identifiable, Hashable, Sendable {
        let kind: ResultKind
        let categoryID: UUID
        let itemID: UUID?
        let categoryTitle: String
        let title: String
        let subtitle: String
        let score: Double

        var id: String {
            if let itemID {
                return itemID.uuidString
            }
            return "category-\(categoryID.uuidString)"
        }
    }

    struct Index: Sendable {
        let categories: [VaultInterviewCategory]
        let itemEntries: [ItemEntry]

        static let empty = Index(categories: [], itemEntries: [])

        var isEmpty: Bool {
            categories.isEmpty && itemEntries.isEmpty
        }
    }

    struct ItemEntry: Sendable {
        let category: VaultInterviewCategory
        let item: VaultInterviewItem
        let record: InterviewKnowledgeRecord
    }

    nonisolated static func makeIndex(categories: [VaultInterviewCategory]) -> Index {
        let itemEntries = categories.flatMap { category in
            category.items.map { item in
                ItemEntry(
                    category: category,
                    item: item,
                    record: InterviewKnowledgeRecord(
                        category: category.title,
                        question: item.question,
                        answer: item.answerFinnish,
                        keyPoints: item.keyPoints,
                        aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                            question: item.question,
                            answer: item.answerFinnish,
                            translation: item.translationTr,
                            keyPoints: item.keyPoints,
                            category: category.title
                        )
                    )
                )
            }
        }

        return Index(categories: categories, itemEntries: itemEntries)
    }

    nonisolated static func rankedResults(
        query: String,
        categories: [VaultInterviewCategory],
        limit: Int = 6
    ) -> [Result] {
        rankedResults(query: query, index: makeIndex(categories: categories), limit: limit)
    }

    nonisolated static func rankedResults(
        query: String,
        index: Index,
        limit: Int = 6
    ) -> [Result] {
        let normalizedQuery = InterviewKnowledgeMatcher.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let semanticScores = Dictionary(
            uniqueKeysWithValues: InterviewKnowledgeMatcher.topMatches(
                query: query,
                records: index.itemEntries.map(\.record),
                maxResults: index.itemEntries.count,
                minimumScore: 0.04
            ).map { (semanticKey(for: $0.record), $0.score) }
        )

        var results: [Result] = []
        results.reserveCapacity(index.categories.count + index.itemEntries.count)

        for category in index.categories {
            let categoryScore = lexicalScore(query: normalizedQuery, text: category.title, weight: 90)
            guard categoryScore > 0 else { continue }
            results.append(
                Result(
                    kind: .category,
                    categoryID: category.id,
                    itemID: nil,
                    categoryTitle: category.title,
                    title: category.title,
                    subtitle: "\(category.items.count) soru",
                    score: categoryScore
                )
            )
        }

        for entry in index.itemEntries {
            let questionScore = lexicalScore(query: normalizedQuery, text: entry.item.question, weight: 420)
            let translationScore = lexicalScore(query: normalizedQuery, text: entry.item.translationTr, weight: 240)
            let answerScore = lexicalScore(query: normalizedQuery, text: entry.item.answerFinnish, weight: 130)
            let keyPointScore = lexicalScore(query: normalizedQuery, text: entry.item.keyPoints.joined(separator: " "), weight: 110)
            let categoryScore = lexicalScore(query: normalizedQuery, text: entry.category.title, weight: 55)
            let semanticScore = (semanticScores[semanticKey(for: entry.record)] ?? 0) * 520
            let totalScore = questionScore + translationScore + answerScore + keyPointScore + categoryScore + semanticScore

            guard totalScore >= 70 else { continue }
            results.append(
                Result(
                    kind: .item,
                    categoryID: entry.category.id,
                    itemID: entry.item.id,
                    categoryTitle: entry.category.title,
                    title: entry.item.question,
                    subtitle: bestSubtitle(for: entry.item, query: normalizedQuery),
                    score: totalScore
                )
            )
        }

        return results
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.001 {
                    return lhs.score > rhs.score
                }
                let lhsIsItem = lhs.itemID != nil
                let rhsIsItem = rhs.itemID != nil
                if lhsIsItem != rhsIsItem {
                    return lhsIsItem
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated private static func semanticKey(for record: InterviewKnowledgeRecord) -> String {
        [
            record.category,
            record.question,
            record.answer,
            record.keyPoints.joined(separator: "|"),
            record.aliases.joined(separator: "|")
        ].joined(separator: "||")
    }

    nonisolated private static func bestSubtitle(for item: VaultInterviewItem, query: String) -> String {
        let translationScore = lexicalScore(query: query, text: item.translationTr, weight: 1)
        let answerScore = lexicalScore(query: query, text: item.answerFinnish, weight: 1)
        let source = translationScore >= answerScore ? item.translationTr : item.answerFinnish
        let compact = source
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 96 {
            return compact
        }
        return String(compact.prefix(96)) + "..."
    }

    nonisolated private static func lexicalScore(query: String, text: String, weight: Double) -> Double {
        let normalizedText = InterviewKnowledgeMatcher.normalize(text)
        guard !normalizedText.isEmpty else { return 0 }

        if normalizedText == query {
            return weight + 240
        }
        if normalizedText.hasPrefix(query) {
            return weight + 170
        }
        if normalizedText.contains(query) {
            return weight + 120
        }

        let queryTokens = query.split(separator: " ").map(String.init)
        let textTokens = normalizedText.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty, !textTokens.isEmpty else { return 0 }

        var exactMatches = 0.0
        var prefixMatches = 0.0
        var fuzzyMatches = 0.0

        for queryToken in queryTokens {
            if textTokens.contains(queryToken) {
                exactMatches += 1
                continue
            }

            if let prefixedToken = textTokens.first(where: { $0.hasPrefix(queryToken) }) {
                let ratio = Double(queryToken.count) / Double(max(prefixedToken.count, 1))
                prefixMatches += max(0.55, min(1.0, ratio))
                continue
            }

            if queryToken.count >= 4,
               textTokens.contains(where: { normalizedSimilarity(queryToken, $0) >= 0.72 }) {
                fuzzyMatches += 0.45
            }
        }

        let coverage = (exactMatches + prefixMatches + fuzzyMatches) / Double(queryTokens.count)
        guard coverage > 0 else { return 0 }

        let startsWithLeadingToken = textTokens.first.map { first in
            queryTokens.first.map { first.hasPrefix($0) || $0.hasPrefix(first) } ?? false
        } ?? false
        let sequenceBonus = startsWithLeadingToken ? 38.0 : 0.0

        return (weight * min(1.0, coverage)) + sequenceBonus + (exactMatches * 18) + (prefixMatches * 12) + (fuzzyMatches * 8)
    }

    nonisolated private static func normalizedSimilarity(_ left: String, _ right: String) -> Double {
        let l = Array(left)
        let r = Array(right)
        let maxLen = max(l.count, r.count)
        guard maxLen > 0 else { return 1.0 }
        return max(0, 1.0 - (Double(levenshteinDistance(l, r)) / Double(maxLen)))
    }

    nonisolated private static func levenshteinDistance(_ left: [Character], _ right: [Character]) -> Int {
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var costs = Array(0...right.count)
        for i in 1...left.count {
            var previousCost = costs[0]
            costs[0] = i
            for j in 1...right.count {
                let currentCost = costs[j]
                if left[i - 1] == right[j - 1] {
                    costs[j] = previousCost
                } else {
                    costs[j] = min(costs[j - 1], costs[j], previousCost) + 1
                }
                previousCost = currentCost
            }
        }
        return costs[right.count]
    }
}
