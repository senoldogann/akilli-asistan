import Foundation
import NaturalLanguage

struct InterviewKnowledgeRecord: Sendable, Hashable {
    let category: String
    let question: String
    let answer: String
    let keyPoints: [String]
    let aliases: [String]

    nonisolated init(
        category: String,
        question: String,
        answer: String,
        keyPoints: [String],
        aliases: [String] = []
    ) {
        self.category = category
        self.question = question
        self.answer = answer
        self.keyPoints = keyPoints
        self.aliases = aliases
    }
}

struct InterviewKnowledgeMatch: Sendable {
    let record: InterviewKnowledgeRecord
    let score: Double
    let matchedTokenCount: Int
}

enum InterviewKnowledgeMatcher {
    private struct IntentRule {
        let tag: String
        let phrases: [String]
        let keywords: [String]
        let minimumKeywordHits: Int
    }

    nonisolated private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in",
        "is", "it", "its", "me", "my", "of", "on", "or", "our", "that", "the", "their",
        "them", "they", "this", "to", "we", "what", "when", "where", "which", "why", "with", "you", "your",
        "bir", "bu", "ve", "veya", "ile", "icin", "için", "mi", "mı", "mu", "mü", "mu", "m",
        "nasil", "nasıl", "nedir", "neden", "hangi", "kac", "kaç", "ne", "kim", "olarak",
        "se", "sen", "siz", "biz", "ben", "da", "de",
        "ja", "on", "se", "että", "mita", "mitä", "miten", "miksi", "kun", "joka", "tai", "myos", "myös",
            // Finnish modal/question filler words
            "onko", "haluatko", "voisitko", "voitteko", "voitko",
            "minulle", "meilta", "meiltä", "jotain", "teille", "jos", "jokin", "asia", "kanssa",
            "sinulla", "sinusta", "sinun", "sun", "teilla", "teillä", "teidan", "teidän", "minun", "mun"
    ]

    nonisolated private static let stemSuffixes: [String] = [
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

    nonisolated private static let synonymMap: [String: String] = {
        let groups: [[String]] = [
            ["handle", "manage", "managed", "managing", "yonet", "yonetim", "yonetmek", "yönet", "yönetim", "yönetmek", "toimia", "toimit", "toimin", "hallita", "hallitsen", "hallitsisit"],
            ["solve", "solved", "solving", "resolve", "resolution", "coz", "cozum", "cozmek", "çöz", "çözüm", "çözmek", "ratkaista", "ratkaisen", "ratko", "selvitan", "selvitän"],
            ["quick", "quickly", "fast", "rapid", "hizli", "hızlı"],
            ["problem", "issue", "incident", "sorun", "problem", "olay", "kesinti", "ongelma", "ongelmatilanne", "haaste", "ristiriita", "konflikti"],
            ["ask", "question", "questions", "kysy", "kysya", "kysyä", "kysymys", "kysymykset", "kysymyksia", "kysymyksiä", "soru", "sorular"],
            ["introduce", "intro", "aboutyourself", "yourself", "itsestasi", "itsestäsi", "kerro", "kerrotko", "puhu", "tausta", "background"],
            ["debt", "borc", "borcu", "borç", "borcu", "technicaldebt"],
            ["legacy", "eski", "monolith", "monolit"],
            ["introduce", "introduction", "background", "tanit", "tanitim", "tanıt", "tanıtım", "ozgecmis", "özgeçmiş"],
            ["performance", "performans", "performansi", "performansı"],
            ["optimize", "optimization", "improve", "hizlandir", "hızlandır", "iyilestir", "iyileştir"],
            ["team", "takim", "takım", "collaboration", "communication", "stakeholder"],
            ["client", "customer", "asiakas", "asiakastyo", "asiakastyota", "clientfacing"],
            ["coworker", "colleague", "teammate", "tyokaver", "tyotover", "tiimikaver", "kollega"],
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

    nonisolated private static let salaryTokenPrefixes: [String] = [
        "palkka", "palkkatoiv", "palkkatavoit", "palkkavaat", "palkkatas",
        "salary", "compens", "wage", "brutto"
    ]

    nonisolated private static let intentRules: [IntentRule] = [
        IntentRule(
            tag: "self_intro",
            phrases: [
                "tell me about yourself", "introduce yourself", "who are you",
                "kerro itsestasi", "kerro itsestäsi", "kerrotko vähän itsestäsi",
                "kuka sina olet", "kuka sinä olet", "puhu sinusta", "esittele itsesi"
            ],
            keywords: ["introduce", "aboutyourself", "yourself", "background"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "company_motivation",
            phrases: [
                "why this company", "why us", "why did you apply", "why loihde",
                "miksi hait juuri", "miksi loihde", "neden özellikle", "neden bu sirket"
            ],
            keywords: ["why", "company", "apply", "motivation", "loihde"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "career_change",
            phrases: [
                "why are you looking for a new job", "why are you changing jobs",
                "miksi etsit uutta tyopaikkaa", "miksi etsit uutta työpaikkaa",
                "neden yeni is", "neden yeni iş"
            ],
            keywords: ["new", "job", "change", "career"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "desired_role",
            phrases: [
                "what kind of role are you looking for", "which role are you looking for",
                "millaista roolia etsit", "hangi rol", "nasil bir pozisyon"
            ],
            keywords: ["role", "position", "fullstack", "backend", "frontend"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "strongest_tech",
            phrases: [
                "strongest technologies", "what technologies are you strongest in",
                "vahvimmat teknologiasi", "en guclu teknolojiler", "en güçlü teknolojiler"
            ],
            keywords: ["technology", "tech", "react", "typescript", "node", "backend", "frontend"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "cloud_experience",
            phrases: [
                "experience with azure", "experience with aws", "cloud experience",
                "kokemusta azuresta", "azure tecruben", "azure tecrüben"
            ],
            keywords: ["azure", "aws", "cloud"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "client_work",
            phrases: [
                "worked with clients", "customer work", "client facing",
                "asiakastyota", "asiakastyötä", "ollut suoraan asiakkaiden kanssa tekemisissa",
                "musterilerle", "müşterilerle"
            ],
            keywords: ["client", "customer", "stakeholder", "requirement", "business"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "conflict_resolution",
            phrases: [
                "problem with coworker or client",
                "asiakkaan kanssa tulee ongelmatilanne",
                "ongelmatilanne asiakkaan kanssa",
                "ongelmia tyotovereiden tai asiakkaiden kanssa",
                "ongelmia työkavereiden tai asiakkaiden kanssa"
            ],
            keywords: ["problem", "client", "coworker", "handle", "solve", "conflict"],
            minimumKeywordHits: 3
        ),
        IntentRule(
            tag: "work_style",
            phrases: [
                "how would you describe your work style",
                "millaista työskentelytapaa", "tyoskentelytapaa", "calisma tarzi", "çalışma tarzı"
            ],
            keywords: ["workstyle", "ownership", "responsible", "independent"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "agile",
            phrases: [
                "agile methods", "scrum", "ketterista menetelmista", "ketteristä menetelmistä"
            ],
            keywords: ["agile", "scrum", "sprint", "retro", "backlog"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "devops",
            phrases: [
                "devops", "ci cd", "deployment pipeline", "julkaisuprosessi"
            ],
            keywords: ["devops", "ci", "cd", "deploy", "pipeline", "release"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "language_skill",
            phrases: [
                "how good is your finnish", "finnish level", "suomen kielen taitosi",
                "fince seviyen", "suomeni"
            ],
            keywords: ["finnish", "suomi", "language", "b2"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "ai_usage",
            phrases: [
                "how do you use ai", "tekoalya ohjelmistokehityksessa", "tekoälyä ohjelmistokehityksessä",
                "yazilim gelistirmede ai", "yazılım geliştirmede ai"
            ],
            keywords: ["ai", "tekoaly", "tekoäly", "llm", "assistant"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "integrations",
            phrases: [
                "experience with integrations", "experience with apis", "integraatioista", "rajapinnoista",
                "entegrasyon", "api"
            ],
            keywords: ["integration", "api", "rest", "rajapinta", "endpoint"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "proud_project",
            phrases: [
                "project you are proud of", "proud project", "ylpea projekti", "ylpeä projekti",
                "gurur duydugun proje", "gurur duyduğun proje"
            ],
            keywords: ["project", "proud", "architecture", "performance"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "role_fit",
            phrases: [
                "why should we choose you", "why are you a good fit", "miksi juuri sina", "miksi juuri sinä",
                "neden bu role uygunsun"
            ],
            keywords: ["fit", "choose", "suitable", "strength", "role"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "availability",
            phrases: [
                "when can you start", "milloin voisit aloittaa", "ne zaman baslayabilirsin", "ne zaman başlayabilirsin"
            ],
            keywords: ["start", "availability", "aloittaa"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "compensation",
            phrases: [
                "salary expectation", "salary expectations", "compensation expectation",
                "millainen palkkatoive", "palkkatavoite", "maas beklentin", "maaş beklentin"
            ],
            keywords: ["salary", "compensation", "wage", "brutto"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "work_mode",
            phrases: [
                "hybrid or remote", "etana vai hybridina", "etänä vai hybridinä",
                "hybrid mi uzaktan mi", "hybrid mi uzaktan mı"
            ],
            keywords: ["hybrid", "remote", "onsite", "eta", "etä"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "stack_preference",
            phrases: [
                "frontend or backend", "frontend vai backend", "frontendci misin backendci misin"
            ],
            keywords: ["frontend", "backend", "fullstack"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "java_spring",
            phrases: [
                "java or spring", "java tai spring", "java veya spring"
            ],
            keywords: ["java", "spring"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "team_preference",
            phrases: [
                "what kind of team", "millaisessa tiimissa viihdyt", "millaisessa tiimissä viihdyt",
                "hangi takimda", "hangi takımda"
            ],
            keywords: ["team", "culture", "collaboration", "trust"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "work_motivation",
            phrases: [
                "what motivates you", "mika motivoi sinua", "mikä motivoi sinua", "seni ne motive eder"
            ],
            keywords: ["motivate", "motivation", "impact", "learning"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "pressure_handling",
            phrases: [
                "under pressure", "busy situation", "paineen alla", "kiireisessa tilanteessa", "yoğun zamanda", "baski altinda"
            ],
            keywords: ["pressure", "stress", "priority", "prioritization", "kiire", "paine"],
            minimumKeywordHits: 1
        ),
        IntentRule(
            tag: "ask_back",
            phrases: [
                "do you have any questions for us", "questions for us",
                "haluatko kysya meilta jotain", "haluatko kysyä meiltä jotain",
                "onko kysymyksia minulle", "onko kysymyksiä minulle", "bize sormak istedigin"
            ],
            keywords: ["question", "ask", "kysy", "kysymys", "meilta", "meiltä"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "multi_project",
            phrases: [
                "multiple projects", "more than one workspace", "useampi workspace", "useampi projekti",
                "birden fazla proje", "birden fazla workspace"
            ],
            keywords: ["multiple", "workspace", "project", "priority"],
            minimumKeywordHits: 2
        ),
        IntentRule(
            tag: "disagreement",
            phrases: [
                "different opinion", "disagree with teammate", "eriava nakemys", "eriävä näkemys",
                "eri mielta", "eri mieltä", "eri mielta tyokaverin kanssa", "eri mieltä työkaverin kanssa",
                "farkli gorus", "farklı görüş"
            ],
            keywords: ["disagree", "different", "opinion", "argument", "conflict", "eri", "mielta", "tyokaver", "tiimikaver"],
            minimumKeywordHits: 2
        )
    ]

    nonisolated static func topMatches(
        query: String,
        records: [InterviewKnowledgeRecord],
        maxResults: Int = 4,
        minimumScore: Double = 0.12
    ) -> [InterviewKnowledgeMatch] {
        let normalizedQuery = normalize(query)
        let queryTokens = tokenSet(from: normalizedQuery)
        let queryIntentTags = intentTags(from: normalizedQuery)
        guard !normalizedQuery.isEmpty else { return [] }

        var matches: [InterviewKnowledgeMatch] = []
        matches.reserveCapacity(records.count)

        for record in records {
            if let match = scoreMatch(
                queryNormalized: normalizedQuery,
                queryTokens: queryTokens,
                queryIntentTags: queryIntentTags,
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

    nonisolated private static func scoreMatch(
        queryNormalized: String,
        queryTokens: Set<String>,
        queryIntentTags: Set<String>,
        record: InterviewKnowledgeRecord,
        minimumScore: Double
    ) -> InterviewKnowledgeMatch? {
        let categoryNorm = normalize(record.category)
        let questionNorm = normalize(record.question)
        let answerNorm = normalize(record.answer)
        let keyPointsNorm = normalize(record.keyPoints.joined(separator: " "))
        let aliasesNorm = normalize(record.aliases.joined(separator: " "))
        let corpus = normalize([questionNorm, answerNorm, keyPointsNorm, aliasesNorm].joined(separator: " "))
        guard !corpus.isEmpty else { return nil }

        let categoryTokens = tokenSet(from: categoryNorm)
        let corpusTokens = tokenSet(from: corpus)
        let questionTokens = tokenSet(from: questionNorm)
        let answerTokens = tokenSet(from: answerNorm)
        let keyPointTokens = tokenSet(from: keyPointsNorm)
        let aliasTokens = tokenSet(from: aliasesNorm)
        let recordIntentTags = intentTags(from: [categoryNorm, questionNorm, answerNorm, keyPointsNorm, aliasesNorm].joined(separator: " "))
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
        let aliasOverlap = tokenOverlap(queryTokens, aliasTokens)
        let categoryOverlap = tokenOverlap(queryTokens, categoryTokens)
        let intentOverlap = tokenOverlap(queryIntentTags, recordIntentTags)

        var phraseBoost = 0.0
        let queryCanonical = canonicalPhrase(from: queryNormalized, removeStopWords: true)
        let questionCanonical = canonicalPhrase(from: questionNorm, removeStopWords: false)
        let answerCanonical = canonicalPhrase(from: answerNorm, removeStopWords: false)
        let aliasCanonical = canonicalPhrase(from: aliasesNorm, removeStopWords: false)

        if queryCanonical.count >= 8, corpus.contains(queryCanonical) {
            phraseBoost += 0.24
        }
        if queryCanonical.count >= 6, questionCanonical.contains(queryCanonical) {
            phraseBoost += 0.18
        }
        if queryCanonical.count >= 6, answerCanonical.contains(queryCanonical) {
            phraseBoost += 0.16
        }
        if queryCanonical.count >= 6, aliasCanonical.contains(queryCanonical) {
            phraseBoost += 0.18
        }
        if !queryIntentTags.isEmpty, !queryIntentTags.intersection(recordIntentTags).isEmpty {
            phraseBoost += min(0.16, Double(queryIntentTags.intersection(recordIntentTags).count) * 0.08)
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
        let trigramAlias = trigramDice(queryCanonical, aliasCanonical)
        let editQuestion = normalizedEditSimilarity(queryCanonical, questionCanonical)
        let editAnswer = normalizedEditSimilarity(queryCanonical, answerCanonical)
        let editAlias = normalizedEditSimilarity(queryCanonical, aliasCanonical)
        let questionSemantic = (trigramQuestion * 0.65) + (editQuestion * 0.35)
        let answerSemantic = (trigramAnswer * 0.55) + (editAnswer * 0.45)
        let aliasSemantic = (trigramAlias * 0.60) + (editAlias * 0.40)
        let semanticApprox = max(questionSemantic, max(answerSemantic * 0.75, aliasSemantic * 0.95))

        let hasDirectQuestionSignal = !queryTokens.intersection(questionTokens.union(aliasTokens)).isEmpty
        if queryTokens.count <= 2, !hasDirectQuestionSignal {
            let hasStrongSemanticSignal =
                semanticApprox >= 0.80 &&
                (phraseBoost >= 0.16 || intentOverlap >= 0.50)
            if !hasStrongSemanticSignal {
                return nil
            }
        }

        let hasLexicalEvidence =
            intersectionCount > 0 ||
            questionOverlap > 0 ||
            answerOverlap > 0 ||
            keyPointOverlap > 0 ||
            aliasOverlap > 0
        let hasIntentOrPhraseEvidence = phraseBoost >= 0.12 || intentOverlap >= 0.50
        if !hasLexicalEvidence && !hasIntentOrPhraseEvidence && semanticApprox < 0.82 {
            return nil
        }

        var score = min(
            1.0,
            (tokenCoverage * 0.24) +
            (jaccard * 0.10) +
            (questionOverlap * 0.24) +
            (answerOverlap * 0.10) +
            (keyPointOverlap * 0.08) +
            (aliasOverlap * 0.14) +
            (semanticApprox * 0.12) +
            (intentOverlap * 0.14) +
            (categoryOverlap * 0.04) +
            phraseBoost
        )

        if questionOverlap == 0, answerOverlap > 0, queryTokens.count <= 4 {
            score *= 0.72
        }

        guard score >= minimumScore else { return nil }
        return InterviewKnowledgeMatch(record: record, score: score, matchedTokenCount: intersectionCount)
    }

    nonisolated private static func tokenOverlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.count)
    }

    nonisolated static func makeInterviewAliases(
        question: String,
        answer: String = "",
        translation: String = "",
        keyPoints: [String] = [],
        category: String = ""
    ) -> [String] {
        var aliases: [String] = []
        let trimmedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranslation.isEmpty {
            aliases.append(trimmedTranslation)
        }

        let corpus = [question, translation, answer, category, keyPoints.joined(separator: " ")].joined(separator: " ")
        let tags = intentTags(from: corpus)
        for rule in intentRules where tags.contains(rule.tag) {
            aliases.append(contentsOf: rule.phrases)
        }

        var seen = Set<String>()
        let normalizedQuestion = normalize(question)
        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { normalize($0) != normalizedQuestion }
            .filter { seen.insert(normalize($0)).inserted }
    }

    nonisolated private static func tokenSet(from normalized: String) -> Set<String> {
        Set(canonicalTokens(from: normalized, removeStopWords: true))
    }

    nonisolated private static func intentTags(from text: String) -> Set<String> {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }
        let canonical = canonicalKeywords(from: normalized, removeStopWords: true)
        var tags = Set<String>()

        for rule in intentRules {
            let phraseHit = rule.phrases.contains(where: normalized.contains)
            let keywordHits = rule.keywords.reduce(into: 0) { count, keyword in
                if canonical.contains(keyword) || normalized.contains(keyword) {
                    count += 1
                }
            }
            if phraseHit || keywordHits >= rule.minimumKeywordHits {
                tags.insert(rule.tag)
            }
        }

        if canonical.contains("salary") {
            tags.insert("compensation")
        }

        return tags
    }

    nonisolated private static func canonicalPhrase(from normalized: String, removeStopWords: Bool) -> String {
        canonicalTokens(from: normalized, removeStopWords: removeStopWords).joined(separator: " ")
    }

    nonisolated private static func canonicalTokens(from normalized: String, removeStopWords: Bool) -> [String] {
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

    nonisolated private static func canonicalToken(for token: String) -> String? {
        if let mappedByPrefix = canonicalTokenByPrefix(token) {
            return mappedByPrefix
        }
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
        if let mappedStemmedByPrefix = canonicalTokenByPrefix(stemmed) {
            return mappedStemmedByPrefix
        }
        if isSalaryToken(stemmed) {
            return "salary"
        }
        return stemmed
    }

    nonisolated private static func canonicalTokenByPrefix(_ token: String) -> String? {
        let prefixMappings: [(prefix: String, canonical: String)] = [
            ("asiakasty", "client"),
            ("asiakka", "client"),
            ("asiakas", "client"),
            ("tyokaver", "coworker"),
            ("tyotover", "coworker"),
            ("tiimikaver", "coworker"),
            ("kolleg", "coworker"),
            ("ongelm", "problem"),
            ("haast", "problem"),
            ("ristiri", "problem"),
            ("konflikt", "problem"),
            ("toimi", "handle"),
            ("hallits", "handle"),
            ("ratko", "solve"),
            ("selvit", "solve")
        ]

        for mapping in prefixMappings where token.hasPrefix(mapping.prefix) {
            return mapping.canonical
        }
        return nil
    }

    nonisolated private static func isSalaryToken(_ token: String) -> Bool {
        salaryTokenPrefixes.contains(where: { token.hasPrefix($0) })
    }

    nonisolated private static func stemToken(_ rawToken: String) -> String {
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

    nonisolated private static func ngrams(from tokens: [String], size: Int) -> [[String]] {
        guard size > 0, tokens.count >= size else { return [] }
        return (0...(tokens.count - size)).map { index in
            Array(tokens[index..<(index + size)])
        }
    }

    nonisolated private static func trigramDice(_ left: String, _ right: String) -> Double {
        let leftTrigrams = characterNgrams(left, n: 3)
        let rightTrigrams = characterNgrams(right, n: 3)
        guard !leftTrigrams.isEmpty, !rightTrigrams.isEmpty else { return 0 }
        let intersection = leftTrigrams.intersection(rightTrigrams).count
        return (2.0 * Double(intersection)) / Double(leftTrigrams.count + rightTrigrams.count)
    }

    nonisolated private static func characterNgrams(_ text: String, n: Int) -> Set<String> {
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

    nonisolated private static func normalizedEditSimilarity(_ left: String, _ right: String) -> Double {
        let l = Array(left)
        let r = Array(right)
        let maxLen = max(l.count, r.count)
        guard maxLen > 0 else { return 1.0 }
        let distance = levenshteinDistance(l, r)
        return max(0, 1.0 - (Double(distance) / Double(maxLen)))
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

    nonisolated static func normalize(_ text: String) -> String {
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

    nonisolated static func canonicalKeywords(from text: String, removeStopWords: Bool = true) -> Set<String> {
        let normalized = normalize(text)
        return Set(canonicalTokens(from: normalized, removeStopWords: removeStopWords))
    }

    nonisolated static func keywordOverlapCount(query: String, target: String) -> Int {
        let queryTokens = canonicalKeywords(from: query, removeStopWords: true)
        let targetTokens = canonicalKeywords(from: target, removeStopWords: true)
        guard !queryTokens.isEmpty, !targetTokens.isEmpty else { return 0 }
        return queryTokens.intersection(targetTokens).count
    }

    nonisolated static func dominantLanguageCode(for text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(normalized)
        return recognizer.dominantLanguage?.rawValue
    }
}
