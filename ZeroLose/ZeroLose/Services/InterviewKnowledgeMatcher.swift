import Foundation
import NaturalLanguage

struct InterviewKnowledgeRecord: Sendable, Hashable {
    let category: String
    let question: String
    let answer: String
    let keyPoints: [String]
}

struct InterviewKnowledgeMatch: Sendable {
    let record: InterviewKnowledgeRecord
    let score: Double
    let matchedTokenCount: Int
}

enum InterviewKnowledgeMatcher {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in",
        "is", "it", "its", "me", "my", "of", "on", "or", "our", "that", "the", "their",
        "them", "they", "this", "to", "we", "what", "when", "where", "which", "why", "with", "you", "your",
        "bir", "bu", "ve", "veya", "ile", "icin", "için", "mi", "mı", "mu", "mü", "mu", "m",
        "nasil", "nasıl", "nedir", "neden", "hangi", "kac", "kaç", "ne", "kim", "olarak",
        "se", "sen", "siz", "biz", "ben", "da", "de",
        "ja", "on", "se", "että", "mita", "mitä", "miten", "miksi", "kun", "joka", "tai", "myos", "myös",
            // Finnish modal/question filler words
            "onko", "haluatko", "voisitko", "voitteko", "voitko",
            "minulle", "meilta", "meiltä", "jotain", "teille",
            "sinulla", "sinusta", "sinun", "sun", "teilla", "teillä", "teidan", "teidän", "minun", "mun"
    ]

    private static let stemSuffixes: [String] = [
        "iyorsunuz", "iyoruz", "iyorum", "iyorsun", "iyor", "ıyorsunuz", "ıyoruz", "ıyorum", "ıyorsun", "ıyor",
        "uyorsunuz", "uyoruz", "uyorum", "uyorsun", "uyor",
        "yorsunuz", "yoruz", "yorum", "yorsun", "yor",
        "siniz", "sınız", "sunuz", "sünüz", "dir", "dır", "dur", "dür", "tir", "tır", "tur", "tür",
        "leri", "ları", "lar", "ler", "nin", "nın", "nun", "nün", "dan", "den", "tan", "ten",
        "lik", "lık", "luk", "lük",
        "ing", "edly", "ed", "ly", "tion", "tions", "ment", "ments",
        "ssa", "ssä", "sta", "stä", "lla", "llä", "lta", "ltä", "ksi", "tta", "ttä", "inen", "iset",
        "es"
    ]

    private static let synonymMap: [String: String] = {
        let groups: [[String]] = [
            ["handle", "manage", "managed", "managing", "yonet", "yonetim", "yonetmek", "yönet", "yönetim", "yönetmek"],
            ["solve", "solved", "solving", "resolve", "resolution", "coz", "cozum", "cozmek", "çöz", "çözüm", "çözmek"],
            ["quick", "quickly", "fast", "rapid", "hizli", "hızlı"],
            ["problem", "issue", "incident", "sorun", "problem", "olay", "kesinti"],
            ["ask", "question", "questions", "kysy", "kysya", "kysyä", "kysymys", "kysymykset", "kysymyksia", "kysymyksiä", "soru", "sorular"],
            ["introduce", "intro", "aboutyourself", "yourself", "itsestasi", "itsestäsi", "kerro", "kerrotko", "puhu", "tausta", "background"],
            ["debt", "borc", "borcu", "borç", "borcu", "technicaldebt"],
            ["legacy", "eski", "monolith", "monolit"],
            ["introduce", "introduction", "background", "tanit", "tanitim", "tanıt", "tanıtım", "ozgecmis", "özgeçmiş"],
            ["performance", "performans", "performansi", "performansı"],
            ["optimize", "optimization", "improve", "hizlandir", "hızlandır", "iyilestir", "iyileştir"],
            ["team", "takim", "takım", "collaboration", "communication", "stakeholder"],
            ["scale", "scaling", "olcek", "ölçek", "buyut", "büyüt"],
            ["frontend", "react", "ui"],
            ["backend", "api", "service"],
            ["test", "testing", "qa"],
            ["salary", "compensation", "wage", "brutto", "palkka", "palkkataso", "palkkatoive", "palkkatavoite", "palkkavaatimus"]
        ]

        var map: [String: String] = [:]
        for group in groups {
            guard let canonical = group.first else { continue }
            for token in group {
                map[token] = canonical
            }
        }
        return map
    }()

    private static let salaryTokenPrefixes: [String] = [
        "palkka", "palkkatoiv", "palkkatavoit", "palkkavaat", "palkkatas",
        "salary", "compens", "wage", "brutto"
    ]

    static func topMatches(
        query: String,
        records: [InterviewKnowledgeRecord],
        maxResults: Int = 4,
        minimumScore: Double = 0.12
    ) -> [InterviewKnowledgeMatch] {
        let normalizedQuery = normalize(query)
        let queryTokens = tokenSet(from: normalizedQuery)
        guard !normalizedQuery.isEmpty else { return [] }

        var matches: [InterviewKnowledgeMatch] = []
        matches.reserveCapacity(records.count)

        for record in records {
            if let match = scoreMatch(
                queryNormalized: normalizedQuery,
                queryTokens: queryTokens,
                record: record,
                minimumScore: minimumScore
            ) {
                matches.append(match)
            }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.matchedTokenCount > rhs.matchedTokenCount
                }
                return lhs.score > rhs.score
            }
            .prefix(maxResults)
            .map { $0 }
    }

    private static func scoreMatch(
        queryNormalized: String,
        queryTokens: Set<String>,
        record: InterviewKnowledgeRecord,
        minimumScore: Double
    ) -> InterviewKnowledgeMatch? {
        let categoryNorm = normalize(record.category)
        let questionNorm = normalize(record.question)
        let answerNorm = normalize(record.answer)
        let keyPointsNorm = normalize(record.keyPoints.joined(separator: " "))
        let corpus = normalize([questionNorm, answerNorm, keyPointsNorm].joined(separator: " "))
        guard !corpus.isEmpty else { return nil }

        let categoryTokens = tokenSet(from: categoryNorm)
        let corpusTokens = tokenSet(from: corpus)
        let questionTokens = tokenSet(from: questionNorm)
        let answerTokens = tokenSet(from: answerNorm)
        let keyPointTokens = tokenSet(from: keyPointsNorm)
        let intersectionCount = queryTokens.intersection(corpusTokens).count

        let tokenCoverage = queryTokens.isEmpty
            ? 0
            : Double(intersectionCount) / Double(queryTokens.count)
        let jaccard = corpusTokens.isEmpty
            ? 0
            : Double(intersectionCount) / Double(queryTokens.union(corpusTokens).count)
        let questionOverlap = tokenOverlap(queryTokens, questionTokens)
        let answerOverlap = tokenOverlap(queryTokens, answerTokens)
        let keyPointOverlap = tokenOverlap(queryTokens, keyPointTokens)
        let categoryOverlap = tokenOverlap(queryTokens, categoryTokens)

        var phraseBoost = 0.0
        let queryCanonical = canonicalPhrase(from: queryNormalized, removeStopWords: true)
        let questionCanonical = canonicalPhrase(from: questionNorm, removeStopWords: false)
        let answerCanonical = canonicalPhrase(from: answerNorm, removeStopWords: false)

        if queryCanonical.count >= 8, corpus.contains(queryCanonical) {
            phraseBoost += 0.24
        }
        if queryCanonical.count >= 6, questionCanonical.contains(queryCanonical) {
            phraseBoost += 0.18
        }
        if queryCanonical.count >= 6, answerCanonical.contains(queryCanonical) {
            phraseBoost += 0.16
        }

        let queryPhrases = ngrams(from: canonicalTokens(from: queryNormalized, removeStopWords: true), size: 2)
        if !queryPhrases.isEmpty {
            var matchedBigrams = 0
            for bigram in queryPhrases.prefix(4) {
                let joined = bigram.joined(separator: " ")
                if questionCanonical.contains(joined) || answerCanonical.contains(joined) {
                    matchedBigrams += 1
                }
            }
            phraseBoost += min(0.12, Double(matchedBigrams) * 0.04)
        }

        // Allow short phrase lookups to still match even with low token overlap.
        if queryTokens.isEmpty, phraseBoost < 0.25 {
            return nil
        }

        let trigramQuestion = trigramDice(queryCanonical, questionCanonical)
        let trigramAnswer = trigramDice(queryCanonical, answerCanonical)
        let editQuestion = normalizedEditSimilarity(queryCanonical, questionCanonical)
        let editAnswer = normalizedEditSimilarity(queryCanonical, answerCanonical)
        let questionSemantic = (trigramQuestion * 0.65) + (editQuestion * 0.35)
        let answerSemantic = (trigramAnswer * 0.55) + (editAnswer * 0.45)
        let semanticApprox = max(questionSemantic, answerSemantic * 0.75)

        let hasQuestionTokenOverlap = !queryTokens.intersection(questionTokens).isEmpty
        if queryTokens.count <= 2, !hasQuestionTokenOverlap {
            let hasStrongSemanticSignal = semanticApprox >= 0.80 && phraseBoost >= 0.16
            if !hasStrongSemanticSignal {
                return nil
            }
        }

        var score = min(
            1.0,
            (tokenCoverage * 0.24) +
            (jaccard * 0.10) +
            (questionOverlap * 0.30) +
            (answerOverlap * 0.10) +
            (keyPointOverlap * 0.08) +
            (semanticApprox * 0.14) +
            (categoryOverlap * 0.04) +
            phraseBoost
        )

        if questionOverlap == 0, answerOverlap > 0, queryTokens.count <= 4 {
            score *= 0.72
        }

        guard score >= minimumScore else { return nil }
        return InterviewKnowledgeMatch(record: record, score: score, matchedTokenCount: intersectionCount)
    }

    private static func tokenOverlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.count)
    }

    private static func tokenSet(from normalized: String) -> Set<String> {
        Set(canonicalTokens(from: normalized, removeStopWords: true))
    }

    private static func canonicalPhrase(from normalized: String, removeStopWords: Bool) -> String {
        canonicalTokens(from: normalized, removeStopWords: removeStopWords).joined(separator: " ")
    }

    private static func canonicalTokens(from normalized: String, removeStopWords: Bool) -> [String] {
        normalized
            .split(separator: " ")
            .map(String.init)
            .compactMap { token in
                guard let canonical = canonicalToken(for: token) else { return nil }
                if removeStopWords && stopWords.contains(canonical) {
                    return nil
                }
                return canonical
            }
    }

    private static func canonicalToken(for token: String) -> String? {
        if let mappedRaw = synonymMap[token] {
            return mappedRaw
        }
        if isSalaryToken(token) {
            return "salary"
        }

        let stemmed = stemToken(token)
        guard stemmed.count >= 2 else { return nil }

        if let mappedStemmed = synonymMap[stemmed] {
            return mappedStemmed
        }
        if isSalaryToken(stemmed) {
            return "salary"
        }
        return stemmed
    }

    private static func isSalaryToken(_ token: String) -> Bool {
        salaryTokenPrefixes.contains(where: { token.hasPrefix($0) })
    }

    private static func stemToken(_ rawToken: String) -> String {
        var token = rawToken
        for suffix in stemSuffixes {
            guard token.count > suffix.count + 2 else { continue }
            if token.hasSuffix(suffix) {
                token.removeLast(suffix.count)
                break
            }
        }
        return token
    }

    private static func ngrams(from tokens: [String], size: Int) -> [[String]] {
        guard size > 0, tokens.count >= size else { return [] }
        return (0...(tokens.count - size)).map { index in
            Array(tokens[index..<(index + size)])
        }
    }

    private static func trigramDice(_ left: String, _ right: String) -> Double {
        let leftTrigrams = characterNgrams(left, n: 3)
        let rightTrigrams = characterNgrams(right, n: 3)
        guard !leftTrigrams.isEmpty, !rightTrigrams.isEmpty else { return 0 }
        let intersection = leftTrigrams.intersection(rightTrigrams).count
        return (2.0 * Double(intersection)) / Double(leftTrigrams.count + rightTrigrams.count)
    }

    private static func characterNgrams(_ text: String, n: Int) -> Set<String> {
        let cleaned = text.replacingOccurrences(of: " ", with: "_")
        let chars = Array(cleaned)
        guard chars.count >= n else { return [] }
        var grams = Set<String>()
        grams.reserveCapacity(max(1, chars.count - n + 1))
        for i in 0...(chars.count - n) {
            grams.insert(String(chars[i..<(i + n)]))
        }
        return grams
    }

    private static func normalizedEditSimilarity(_ left: String, _ right: String) -> Double {
        let l = Array(left)
        let r = Array(right)
        let maxLen = max(l.count, r.count)
        guard maxLen > 0 else { return 1.0 }
        let distance = levenshteinDistance(l, r)
        return max(0, 1.0 - (Double(distance) / Double(maxLen)))
    }

    private static func levenshteinDistance(_ left: [Character], _ right: [Character]) -> Int {
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

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let cleanedScalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(cleanedScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func canonicalKeywords(from text: String, removeStopWords: Bool = true) -> Set<String> {
        let normalized = normalize(text)
        return Set(canonicalTokens(from: normalized, removeStopWords: removeStopWords))
    }

    static func keywordOverlapCount(query: String, target: String) -> Int {
        let queryTokens = canonicalKeywords(from: query, removeStopWords: true)
        let targetTokens = canonicalKeywords(from: target, removeStopWords: true)
        guard !queryTokens.isEmpty, !targetTokens.isEmpty else { return 0 }
        return queryTokens.intersection(targetTokens).count
    }

    static func dominantLanguageCode(for text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(normalized)
        return recognizer.dominantLanguage?.rawValue
    }
}
