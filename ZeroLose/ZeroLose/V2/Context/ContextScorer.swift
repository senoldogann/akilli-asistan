import Foundation

nonisolated struct ContextScorer: Sendable {
    static func tokens(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for component in text.split(whereSeparator: { $0.isWhitespace }) {
            let normalized = String(component)
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()

            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }

        return result
    }

    func lexicalOverlap(query: String, candidate: String) -> Double {
        let queryTokens = Self.tokens(query)
        guard !queryTokens.isEmpty else { return 0 }

        let candidateTokens = Set(Self.tokens(candidate))
        let matches = queryTokens.reduce(into: 0) { count, token in
            if candidateTokens.contains(token) {
                count += 1
            }
        }
        return Double(matches) / Double(queryTokens.count)
    }
}
