import Foundation

struct ActiveRoleProfile: Sendable, Hashable {
    let company: String
    let roleTitle: String
    let overview: String
    let workMode: String
    let locations: [String]
    let focusAreas: [String]
    let records: [InterviewKnowledgeRecord]
    let rawDescription: String
}

enum ActiveRoleProfileService {
    static let userDefaultsKey = "activeJobDescription"

    private enum Section: CaseIterable {
        case intro
        case expectations
        case offer
        case whyJoin
        case application
        case privacy
        case other
    }

    private struct CompetencyDefinition {
        let title: String
        let keywords: [String]
        let aliases: [String]
        let preferredSections: Set<Section>
    }

    private static let competencyDefinitions: [CompetencyDefinition] = [
        CompetencyDefinition(
            title: "Why This Company",
            keywords: ["company", "culture", "community", "growth", "warm", "open", "develop", "digital", "ai", "partner"],
            aliases: ["why this company", "why us", "why join", "miksi loihde", "miksi juuri", "neden bu şirket", "neden özellikle bu şirket"],
            preferredSections: [.whyJoin, .offer, .intro]
        ),
        CompetencyDefinition(
            title: "Role Scope",
            keywords: ["role", "fullstack", "developer", "engineer", "project", "consulting", "client"],
            aliases: ["what kind of role", "which role", "millaista roolia", "hangi rol", "what are you looking for"],
            preferredSections: [.intro, .expectations]
        ),
        CompetencyDefinition(
            title: "Backend (Node.js / Java / Spring)",
            keywords: ["backend", "node", "java", "spring", "server", "microservice"],
            aliases: ["node.js", "java", "spring framework", "backend development"],
            preferredSections: [.expectations, .intro]
        ),
        CompetencyDefinition(
            title: "Frontend (React / TypeScript)",
            keywords: ["frontend", "react", "typescript", "javascript", "ui"],
            aliases: ["reactjs", "typescript", "frontend experience"],
            preferredSections: [.expectations]
        ),
        CompetencyDefinition(
            title: "Cloud / Azure",
            keywords: ["azure", "cloud", "deployment", "app service", "function", "pilvipohj"],
            aliases: ["azure experience", "cloud experience", "pilvipohjaiset sovellukset"],
            preferredSections: [.expectations]
        ),
        CompetencyDefinition(
            title: "DevOps / CI-CD",
            keywords: ["devops", "ci", "cd", "pipeline", "deploy", "automation", "release"],
            aliases: ["ci cd", "deployment pipeline", "julkaisuprosessi"],
            preferredSections: [.expectations]
        ),
        CompetencyDefinition(
            title: "Integrations / REST / API Security",
            keywords: ["integration", "rest", "api", "security", "secure", "rajapinta", "turvall"],
            aliases: ["integrations", "rest api", "api security", "sovellusrajapinnat"],
            preferredSections: [.expectations]
        ),
        CompetencyDefinition(
            title: "Agile / Software Automation",
            keywords: ["agile", "scrum", "automation", "softa automaatio", "ketter", "prosessi"],
            aliases: ["agile methods", "ketterat menetelmat", "softa automaatio"],
            preferredSections: [.expectations]
        ),
        CompetencyDefinition(
            title: "Communication / Languages",
            keywords: ["communication", "interaction", "vuorovaikutus", "finnish", "english", "suomen", "englannin"],
            aliases: ["language skills", "finnish and english", "sujuva suomi", "hyvat vuorovaikutustaidot"],
            preferredSections: [.expectations]
        ),
        CompetencyDefinition(
            title: "Ownership / Client Problem Solving",
            keywords: ["ownership", "responsibility", "client", "customer", "business", "asiakas", "liiketoiminta", "vastuunotto"],
            aliases: ["ownership", "client work", "customer challenges", "asiakkaan liiketoiminnan haasteita"],
            preferredSections: [.expectations, .intro]
        ),
        CompetencyDefinition(
            title: "AI in Development",
            keywords: ["ai", "tekoaly", "tekoaly", "machine learning", "llm"],
            aliases: ["ai in software development", "tekoalyn hyodyntaminen", "tekoälyn hyödyntäminen"],
            preferredSections: [.expectations, .whyJoin, .intro]
        ),
        CompetencyDefinition(
            title: "Benefits / Work Model",
            keywords: ["salary", "hybrid", "remote", "office", "benefit", "palkka", "toimisto", "urakehitys"],
            aliases: ["what can you expect", "benefits", "hybrid", "remote", "mita voit odottaa"],
            preferredSections: [.offer, .whyJoin]
        )
    ]

    static func currentProfile() -> ActiveRoleProfile? {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return profile(from: raw)
    }

    static func profile(from description: String) -> ActiveRoleProfile? {
        let rawDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDescription.isEmpty else { return nil }

        let lines = rawDescription
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sanitizedLines = sanitizeImportedLines(lines)
        guard !sanitizedLines.isEmpty else { return nil }

        let sectionedLines = extractSectionLines(from: sanitizedLines)
        let company = extractCompanyName(from: sanitizedLines)
        let roleTitle = extractRoleTitle(from: sanitizedLines, company: company)
        let overview = buildOverview(from: sectionedLines[.intro] ?? [], company: company, roleTitle: roleTitle)
        let workMode = extractWorkMode(from: sectionedLines)
        let locations = extractLocations(from: sectionedLines)
        let competencyRecords = buildCompetencyRecords(sectionedLines: sectionedLines, company: company, roleTitle: roleTitle)

        let records: [InterviewKnowledgeRecord] = {
            var aggregated: [InterviewKnowledgeRecord] = []
            if !overview.isEmpty {
                aggregated.append(
                    InterviewKnowledgeRecord(
                        category: "Active Role > Overview",
                        question: "Active Role Overview",
                        answer: overview,
                        keyPoints: [company, roleTitle, workMode].filter { !$0.isEmpty },
                        aliases: [
                            company,
                            roleTitle,
                            "current role",
                            "target company",
                            "what kind of role is this",
                            "which company is this interview for",
                            "millaiseen rooliin haet",
                            "hangi rol bu"
                        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    )
                )
            }
            aggregated.append(contentsOf: competencyRecords)
            return aggregated
        }()

        let focusAreas = competencyRecords.map(\.question)

        return ActiveRoleProfile(
            company: company,
            roleTitle: roleTitle,
            overview: overview,
            workMode: workMode,
            locations: locations,
            focusAreas: focusAreas,
            records: records,
            rawDescription: rawDescription
        )
    }

    private static func sanitizeImportedLines(_ lines: [String]) -> [String] {
        lines.filter { line in
            let normalized = InterviewKnowledgeMatcher.normalize(line)
            guard !normalized.isEmpty else { return false }
            if normalized.hasPrefix("imported role") || normalized.hasPrefix("imported context") {
                return false
            }
            if normalized.hasPrefix("parsed role pack") {
                return false
            }
            return true
        }
    }

    static func relevantMatches(
        for query: String,
        profile: ActiveRoleProfile,
        maxResults: Int = 3,
        minimumScore: Double = 0.16
    ) -> [InterviewKnowledgeMatch] {
        InterviewKnowledgeMatcher.topMatches(
            query: query,
            records: profile.records,
            maxResults: maxResults,
            minimumScore: minimumScore
        )
    }

    static func strongestMatchScore(for query: String, profile: ActiveRoleProfile) -> Double {
        relevantMatches(for: query, profile: profile, maxResults: 1).first?.score ?? 0
    }

    static func groundingContext(
        for query: String,
        profile: ActiveRoleProfile,
        maxResults: Int = 3
    ) -> String {
        let matches = relevantMatches(for: query, profile: profile, maxResults: maxResults)
        let focusAreaSummary = profile.focusAreas.prefix(6).joined(separator: ", ")
        let locationSummary = profile.locations.isEmpty ? "" : "Locations: \(profile.locations.joined(separator: ", "))"
        let workModeSummary = profile.workMode.isEmpty ? "" : "Work model: \(profile.workMode)"

        var lines: [String] = [
            "[ACTIVE ROLE GROUNDING]",
            "Company: \(profile.company.isEmpty ? "Unknown" : profile.company)",
            "Role: \(profile.roleTitle.isEmpty ? "Not detected" : profile.roleTitle)",
            focusAreaSummary.isEmpty ? "" : "Focus Areas: \(focusAreaSummary)",
            locationSummary,
            workModeSummary
        ]

        if !matches.isEmpty {
            lines.append("Relevant Role Evidence:")
            for (index, match) in matches.enumerated() {
                let answer = compact(match.record.answer, limit: 220)
                lines.append("[\(index + 1)] \(match.record.question) | Score: \(String(format: "%.2f", match.score))")
                lines.append("A: \(answer)")
            }
        }

        return lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func warmUpContext(for profile: ActiveRoleProfile?) -> String {
        guard let profile else {
            return "[ACTIVE ROLE]\nNo active job description loaded. Use generic interview grounding only."
        }

        let focusAreaSummary = profile.focusAreas.prefix(8).joined(separator: ", ")
        let locationSummary = profile.locations.isEmpty ? "" : "Locations: \(profile.locations.joined(separator: ", "))"
        let workModeSummary = profile.workMode.isEmpty ? "" : "Work model: \(profile.workMode)"

        return [
            "[ACTIVE ROLE]",
            "Company: \(profile.company)",
            "Role: \(profile.roleTitle)",
            locationSummary,
            workModeSummary,
            focusAreaSummary.isEmpty ? "" : "Focus Areas: \(focusAreaSummary)",
            "Rules:",
            "- Treat this active role as the source of truth for company, stack, and role-specific expectations.",
            "- If the question is role- or company-specific, prefer this active role before generic memory.",
            "- If the role does not specify a detail, fall back to persona and interview vault without inventing facts."
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    static func previewSummary(for description: String) -> String {
        guard let profile = profile(from: description) else { return "No active role parsed yet." }
        let focusAreas = profile.focusAreas.prefix(6).joined(separator: ", ")
        let workMode = profile.workMode.isEmpty ? "Not detected" : profile.workMode
        return [
            "Company: \(profile.company.isEmpty ? "Unknown" : profile.company)",
            "Role: \(profile.roleTitle.isEmpty ? "Not detected" : profile.roleTitle)",
            "Work model: \(workMode)",
            focusAreas.isEmpty ? "Focus Areas: Not detected" : "Focus Areas: \(focusAreas)"
        ].joined(separator: "\n")
    }

    private static func buildCompetencyRecords(
        sectionedLines: [Section: [String]],
        company: String,
        roleTitle: String
    ) -> [InterviewKnowledgeRecord] {
        var records: [InterviewKnowledgeRecord] = []
        var seenQuestions = Set<String>()

        for definition in competencyDefinitions {
            let evidence = collectEvidence(for: definition, sectionedLines: sectionedLines)
            guard !evidence.isEmpty else { continue }

            let question = definition.title
            let normalizedQuestion = InterviewKnowledgeMatcher.normalize(question)
            guard seenQuestions.insert(normalizedQuestion).inserted else { continue }

            let answer = evidence.joined(separator: " ")
            let aliases = definition.aliases + [company, roleTitle]
            records.append(
                InterviewKnowledgeRecord(
                    category: "Active Role > \(definition.title)",
                    question: question,
                    answer: answer,
                    keyPoints: definition.keywords,
                    aliases: aliases
                )
            )
        }

        return records
    }

    private static func collectEvidence(
        for definition: CompetencyDefinition,
        sectionedLines: [Section: [String]]
    ) -> [String] {
        let keywordCorpus = definition.keywords.joined(separator: " ")
        var evidence: [String] = []
        var seen = Set<String>()

        for section in Section.allCases {
            guard let lines = sectionedLines[section], !lines.isEmpty else { continue }
            for line in lines {
                let normalizedLine = InterviewKnowledgeMatcher.normalize(line)
                let keywordOverlap = InterviewKnowledgeMatcher.keywordOverlapCount(query: normalizedLine, target: keywordCorpus)
                let aliasHit = definition.aliases.contains { alias in
                    let normalizedAlias = InterviewKnowledgeMatcher.normalize(alias)
                    return !normalizedAlias.isEmpty && normalizedLine.contains(normalizedAlias)
                }
                let shouldInclude = keywordOverlap > 0 || aliasHit || (definition.preferredSections.contains(section) && line.count > 24 && keywordOverlap > 0)
                guard shouldInclude else { continue }
                let compactLine = compact(line, limit: 190)
                let normalizedCompact = InterviewKnowledgeMatcher.normalize(compactLine)
                guard seen.insert(normalizedCompact).inserted else { continue }
                evidence.append(compactLine)
            }
        }

        if evidence.isEmpty {
            for section in definition.preferredSections {
                guard let fallback = sectionedLines[section]?.first else { continue }
                let compactFallback = compact(fallback, limit: 190)
                let normalizedFallback = InterviewKnowledgeMatcher.normalize(compactFallback)
                guard seen.insert(normalizedFallback).inserted else { continue }
                evidence.append(compactFallback)
                break
            }
        }

        return Array(evidence.prefix(3))
    }

    private static func extractSectionLines(from lines: [String]) -> [Section: [String]] {
        var result: [Section: [String]] = [:]
        var currentSection: Section = .intro

        for line in lines {
            let normalized = InterviewKnowledgeMatcher.normalize(line)
            if let detectedSection = detectSection(for: normalized) {
                currentSection = detectedSection
                continue
            }

            let cleaned = line
                .replacingOccurrences(of: #"^[\*\-•]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            result[currentSection, default: []].append(cleaned)
        }

        return result
    }

    private static func detectSection(for normalizedLine: String) -> Section? {
        if normalizedLine.contains("mita odotamme") || normalizedLine.contains("what we expect") || normalizedLine.contains("requirements") || normalizedLine.contains("what we are looking") {
            return .expectations
        }
        if normalizedLine.contains("mita voit odottaa") || normalizedLine.contains("what you can expect") || normalizedLine.contains("what we offer") || normalizedLine.contains("what we provide") {
            return .offer
        }
        if normalizedLine.contains("miksi tulla") || normalizedLine.contains("why join") || normalizedLine.contains("why loihde") || normalizedLine.contains("miksi meille") {
            return .whyJoin
        }
        if normalizedLine.contains("liitathan mukaan") || normalizedLine.contains("liitathan") || normalizedLine.contains("hakemus") || normalizedLine.contains("cv") || normalizedLine.contains("recruit") {
            return .application
        }
        if normalizedLine.contains("tietoturvallisesti") || normalizedLine.contains("privacy") || normalizedLine.contains("luottotietojen") || normalizedLine.contains("huumetestaus") {
            return .privacy
        }
        return nil
    }

    private static func extractCompanyName(from lines: [String]) -> String {
        for line in lines.prefix(4) {
            let normalized = InterviewKnowledgeMatcher.normalize(line)
            let wordCount = normalized.split(separator: " ").count
            if wordCount > 0 && wordCount <= 4 && !normalized.contains("mita") && !normalized.contains("why") {
                return line
            }
        }
        return lines.first ?? ""
    }

    private static func extractRoleTitle(from lines: [String], company: String) -> String {
        let normalizedCompany = InterviewKnowledgeMatcher.normalize(company)
        let patterns = [
            #"(?i)(senior|lead|staff|principal|koken[a-zåäö-]*)?\s*(full\s*stack[- ]?(?:ohjelmistokehittäj[a-zåäö-]*|developer|engineer)|backend[- ]?(?:developer|engineer)|frontend[- ]?(?:developer|engineer)|software\s+(?:developer|engineer)|ohjelmistokehittäj[a-zåäö-]*)"#,
            #"(?i)(full\s*stack[- ]?(?:developer|engineer)|fullstack[- ]?ohjelmistokehittäj[a-zåäö-]*|backend[- ]?developer|frontend[- ]?developer|software engineer|software developer)"#
        ]

        for line in lines.prefix(12) {
            let cleaned = line.replacingOccurrences(of: company, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            for pattern in patterns {
                if let range = cleaned.range(of: pattern, options: [.regularExpression]) {
                    return cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let normalized = InterviewKnowledgeMatcher.normalize(cleaned)
            if normalized.contains("fullstack") || normalized.contains("full stack") || normalized.contains("backend") || normalized.contains("frontend") || normalized.contains("ohjelmistokehitt") {
                if normalized != normalizedCompany {
                    return compact(cleaned, limit: 90)
                }
            }
        }

        return ""
    }

    private static func buildOverview(from introLines: [String], company: String, roleTitle: String) -> String {
        let compactIntro = introLines.prefix(3).map { compact($0, limit: 180) }
        var parts: [String] = []
        if !company.isEmpty || !roleTitle.isEmpty {
            parts.append([company, roleTitle].filter { !$0.isEmpty }.joined(separator: " - "))
        }
        if !compactIntro.isEmpty {
            parts.append(compactIntro.joined(separator: " "))
        }
        return compact(parts.joined(separator: " "), limit: 360)
    }

    private static func extractWorkMode(from sectionedLines: [Section: [String]]) -> String {
        let lines = sectionedLines[.offer, default: []] + sectionedLines[.intro, default: []]
        for line in lines {
            let normalized = InterviewKnowledgeMatcher.normalize(line)
            if normalized.contains("hybrid") {
                return "Hybrid"
            }
            if normalized.contains("remote") || normalized.contains("eta") || normalized.contains("etaty") {
                return "Remote-friendly"
            }
            if normalized.contains("onsite") || normalized.contains("toimistolla") {
                return "On-site"
            }
        }
        return ""
    }

    private static func extractLocations(from sectionedLines: [Section: [String]]) -> [String] {
        let lines = sectionedLines[.offer, default: []] + sectionedLines[.intro, default: []]
        let knownLocations: [(match: String, canonical: String)] = [
            ("Helsinki", "Helsinki"), ("Helsingissä", "Helsinki"),
            ("Oulu", "Oulu"), ("Oulussa", "Oulu"),
            ("Lappeenranta", "Lappeenranta"), ("Lappeenrannassa", "Lappeenranta"),
            ("Tampere", "Tampere"), ("Tampereella", "Tampere"),
            ("Espoo", "Espoo"), ("Espoossa", "Espoo"),
            ("Turku", "Turku"), ("Turussa", "Turku")
        ]
        var found: [String] = []
        var seen = Set<String>()
        for line in lines {
            for location in knownLocations where line.localizedCaseInsensitiveContains(location.match) {
                if seen.insert(location.canonical).inserted {
                    found.append(location.canonical)
                }
            }
        }
        return found
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: max(0, limit - 1))
        return trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
