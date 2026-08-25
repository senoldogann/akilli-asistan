import Foundation

/// Soru tespiti, dil çıkarımı ve çoklu soru bölümleme için saf metin-analiz yardımcıları.
///
/// `IntelligenceService`'ten çıkarıldı, böylece orkestrasyon dosyası yalnızca
/// kontrol akışına sahip olur. Bunlar yalnızca `InterviewKnowledgeMatcher`'a bağlı
/// durumsuz fonksiyonlardır.
enum TextAnalysis {
    static func detectedQuestionSegments(_ query: String) -> [String] {
        let compact = query
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return [] }

        let punctuationSegments = questionMarkedSegments(from: compact)
        if !punctuationSegments.isEmpty {
            return Array(punctuationSegments.prefix(3))
        }

        let inferredSegments = inferredQuestionSegments(from: compact)
        if !inferredSegments.isEmpty {
            return Array(inferredSegments.prefix(3))
        }

        if let standaloneQuestion = standaloneQuestionSegment(from: compact) {
            return [standaloneQuestion]
        }

        return []
    }

    static func splitQuestionSegments(_ query: String) -> [String] {
        let detected = detectedQuestionSegments(query)
        return detected.count >= 2 ? detected : []
    }

    private static func questionMarkedSegments(from query: String) -> [String] {
        guard query.contains("?") else { return [] }
        var segments: [String] = []
        var seen = Set<String>()
        let rawSegments = query.components(separatedBy: "?")
        for raw in rawSegments {
            let cleaned = cleanedQuestionSegment(raw)
            guard cleaned.count >= 4 else { continue }
            let normalized = InterviewKnowledgeMatcher.normalize(cleaned)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            segments.append(cleaned + "?")
        }
        return Array(segments.prefix(3))
    }

    private static func standaloneQuestionSegment(from query: String) -> String? {
        let lowered = InterviewKnowledgeMatcher.normalize(query)
        guard !lowered.isEmpty else { return nil }

        let preambles = [
            "next question", "quick question", "one question", "question",
            "seuraava kysymys", "kysymys", "lyhyt kysymys",
            "sıradaki soru", "bir soru", "soru"
        ]

        var candidate = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preamble = preambles.first(where: { lowered.hasPrefix($0 + " ") || lowered == $0 }) {
            let prefixLength = (candidate as NSString).range(of: preamble, options: .caseInsensitive).length
            if prefixLength > 0, candidate.count > prefixLength {
                let index = candidate.index(candidate.startIndex, offsetBy: min(prefixLength, candidate.count))
                candidate = String(candidate[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let cleaned = cleanedQuestionSegment(candidate)
        guard cleaned.count >= 4 else { return nil }
        guard looksLikeQuestionClause(cleaned) || cleaned.contains("?") else { return nil }
        return ensureQuestionMark(cleaned)
    }

    private static func inferredQuestionSegments(from query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return [] }

        let nsQuery = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsQuery.length)
        let boundaries = inferredQuestionBoundaryLocations(in: trimmed)
        guard boundaries.count >= 2 else { return [] }

        var segments: [String] = []
        var seen = Set<String>()

        for (index, start) in boundaries.enumerated() {
            let end = (index + 1 < boundaries.count) ? boundaries[index + 1] : fullRange.length
            guard end > start else { continue }
            let raw = nsQuery.substring(with: NSRange(location: start, length: end - start))
            let cleaned = cleanedQuestionSegment(raw)
            guard cleaned.count >= 4 else { continue }
            guard looksLikeQuestionClause(cleaned) else { continue }

            let normalized = InterviewKnowledgeMatcher.normalize(cleaned)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            segments.append(cleaned + "?")
        }

        return segments
    }

    private static func inferredQuestionBoundaryLocations(in query: String) -> [Int] {
        let starterPhrases = [
            "could you", "would you", "can you", "do you", "tell me", "tell us",
            "walk me through", "can you walk me through", "could you walk me through",
            "have you", "have you worked", "what kind of", "what are your", "how have you",
            "ne zaman", "kuka", "kerrotko", "kerro", "voitko", "voisitko", "voitteko",
            "miksi", "miten", "millainen", "milloin", "haluatko", "onko", "mika", "mikä", "mita", "mitä", "paljonko", "puhu", "entä",
            "what", "how", "why", "when", "which", "who",
            "neden", "nasil", "nasıl", "hangi", "kim", "bize anlat", "anlat"
        ].sorted { $0.count > $1.count }

        let escaped = starterPhrases.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?:(?<=^)|(?<=\s)|(?<=[.!?]))\s*("# + escaped + #")\b"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsQuery = query as NSString
        let matches = regex.matches(in: query, options: [], range: NSRange(location: 0, length: nsQuery.length))
        var boundaries: [Int] = []

        for match in matches {
            let starterRange = match.range(at: 1)
            guard starterRange.location != NSNotFound else { continue }
            boundaries.append(starterRange.location)
        }

        let normalizedStart = InterviewKnowledgeMatcher.normalize(query.prefix(48).description)
        if looksLikeQuestionClause(normalizedStart) {
            boundaries.append(0)
        }

        return Array(Set(boundaries)).sorted()
    }

    private static func cleanedQuestionSegment(_ raw: String) -> String {
        let trailingConnectors = [
            " ja", " and", " ve", " sekä", " tai", " or"
        ]
        let leadingConnectors = [
            "ja ", "and ", "ve ", "sekä ", "tai ", "or "
        ]

        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: #"^[,.;:\-]+"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[,.;:\-]+$"#, with: "", options: .regularExpression)

        for connector in leadingConnectors where cleaned.lowercased().hasPrefix(connector) {
            cleaned.removeFirst(connector.count)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        for connector in trailingConnectors where cleaned.lowercased().hasSuffix(connector) {
            cleaned.removeLast(connector.count)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        return cleaned
    }

    private static func looksLikeQuestionClause(_ text: String) -> Bool {
        let normalized = InterviewKnowledgeMatcher.normalize(text)
        guard !normalized.isEmpty else { return false }

        let starterPrefixes = [
            "could you", "would you", "can you", "do you", "tell me", "tell us",
            "walk me through", "can you walk me through", "could you walk me through",
            "have you", "have you worked", "what", "what kind of", "what are your",
            "how", "how have you", "why", "when", "which", "who",
            "kuka", "kerrotko", "kerro", "voitko", "voisitko", "voitteko",
            "miksi", "miten", "millainen", "milloin", "haluatko", "onko", "mika", "mikä", "mita", "mitä", "paljonko", "puhu", "entä",
            "neden", "nasil", "nasıl", "hangi", "kim", "ne zaman", "anlat", "bize anlat"
        ]

        return starterPrefixes.contains(where: { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + " ")
        })
    }

    private static func ensureQuestionMark(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "?.! \n\t"))
        return trimmed.isEmpty ? text : trimmed + "?"
    }

    nonisolated static func isFollowUpQuestion(_ query: String) -> Bool {
        let normalized = InterviewKnowledgeMatcher.normalize(query)
        guard !normalized.isEmpty else { return false }

        let tokenCount = normalized.split(separator: " ").count
        guard tokenCount <= 12 else { return false }

        let explicitFollowUpPhrases = [
            "what kind of project was that",
            "what kind of project was it",
            "which project was that",
            "how did you do that",
            "how did you build that",
            "how did you implement that",
            "tell me more about that",
            "tell me more about it",
            "what was that project",
            "minkalainen projekti se oli",
            "minkälainen projekti se oli",
            "millaista projektia se oli",
            "minkalaista projektia se oli",
            "minkälaista projektia se oli",
            "kerro lisaa siita",
            "kerro lisää siitä",
            "voisitko kertoa lisaa siita",
            "voisitko kertoa lisää siitä",
            "miten teit sen",
            "miten tehnyt sen",
            "miten toteutit sen",
            "miten rakensit sen",
            "enta se projekti",
            "entä se projekti",
            "o nasil bir projeydi",
            "o nasıl bir projeydi",
            "o proje neydi",
            "ondan biraz daha bahseder misin"
        ]
        if explicitFollowUpPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let referentialTokens = [
            "that", "it", "those", "them",
            "se", "sen", "siina", "siinä", "siita", "siitä", "sita", "sitä", "sellainen",
            "o", "onu", "ondan", "onu", "bu", "bunu", "bundan"
        ]
        let detailTokens = [
            "project", "projekti", "projekti", "experience", "kokemus", "role", "company",
            "detail", "details", "more", "kind", "whatkind", "minkalainen", "minkälainen",
            "minkalaista", "minkälaista", "millaista", "millainen", "which", "what",
            "how", "miten", "did", "made", "built", "implemented", "teit", "tehnyt", "rakensit", "toteutit"
        ]

        let tokens = Set(normalized.split(separator: " ").map(String.init))
        let hasReference = !tokens.isDisjoint(with: referentialTokens)
        let hasDetailTarget = !tokens.isDisjoint(with: detailTokens)
        let looksLikeQuestion = query.contains("?") || looksLikeQuestionClause(query)

        return looksLikeQuestion && hasReference && hasDetailTarget
    }

    nonisolated static func followUpRetrievalQuery(
        currentQuery: String,
        previousQuestion: String,
        previousAnswer: String
    ) -> String {
        let compactPreviousAnswer = previousAnswer
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answerSnippet = String(compactPreviousAnswer.prefix(240))

        return """
        \(currentQuery)
        Previous question: \(previousQuestion)
        Previous grounded answer: \(answerSnippet)
        """
    }
}
