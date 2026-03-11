import Foundation
import NaturalLanguage
import os

enum WebSearchMode: Sendable {
    case automatic
    case forceOn
}

/// The centralized brain of ZeroLose.
/// Handles reasoning, web searching, and streaming responses for ALL input sources.
class IntelligenceService {
    private let ollamaService: OllamaService
    private let tavilyService: TavilyService
    private let cacheService: ResponseCacheService
    private let semanticRetriever: SemanticRetriever?
    private let chatHistoryService: ChatHistoryService?
    private let systemStatusService: SystemStatusService?
    private let logger = Logger.intelligence
    
    private var conversationHistory: [OllamaService.ChatMessage] = []
    private let maxHistoryLimit = 15 // Keep last 15 messages for context
    private var transientPersonaContext: String = ""
    
    private enum SearchDecision {
        case required
        case optional
        case notNeeded
    }

    private enum ResponseProfile {
        case interviewConcise
        case detailedNarrative
        case detailedTable
    }
    
    func clearHistory() {
        conversationHistory.removeAll()
        logger.info("🗑️ Conversation history cleared in IntelligenceService")
    }
    
    func setTransientPersonaContext(_ context: String) {
        transientPersonaContext = context
    }
    
    func clearTransientPersonaContext() {
        transientPersonaContext = ""
    }
    
    init(
        ollamaService: OllamaService,
        tavilyService: TavilyService = TavilyService(),
        cacheService: ResponseCacheService = .shared,
        semanticRetriever: SemanticRetriever? = nil,
        chatHistoryService: ChatHistoryService? = nil,
        systemStatusService: SystemStatusService? = nil
    ) {
        self.ollamaService = ollamaService
        self.tavilyService = tavilyService
        self.cacheService = cacheService
        self.semanticRetriever = semanticRetriever
        self.chatHistoryService = chatHistoryService
        self.systemStatusService = systemStatusService
    }
    
    /// Main entry point for processing any query (Text or Vision)
    func process(
        query: String,
        imageData: Data? = nil,
        webSearchMode: WebSearchMode = .automatic,
        allowAgentActions: Bool = false,
        detectedLanguage: String? = nil,
        onStatusUpdate: @escaping (String) -> Void,
        onPartialResponse: @escaping (String) -> Void
    ) async throws -> String {
        let lowerQuery = query.lowercased()
        let responseProfile = responseProfile(for: lowerQuery)
        let finalLanguageCode: String? = {
            if let detectedLanguage {
                return detectedLanguage.lowercased()
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(query)
            return recognizer.dominantLanguage?.rawValue.lowercased()
        }()

        let searchDecision: SearchDecision
        if imageData != nil {
            searchDecision = .notNeeded
        } else {
            switch webSearchMode {
            case .automatic:
                searchDecision = searchDecisionForQuery(query)
            case .forceOn:
                searchDecision = .required
            }
        }

        var vaultMatches: [InterviewKnowledgeMatch] = []
        if imageData == nil {
            await MainActor.run { onStatusUpdate("Checking interview vault...") }
            vaultMatches = await retrieveVaultMatches(
                for: query,
                maxResults: responseProfile == .interviewConcise ? 3 : 5
            )
        }
        let strongestVaultScore = vaultMatches.first?.score ?? 0
        let hasStrongVaultMatch = strongestVaultScore >= 0.50
        let vaultContext = buildVaultContext(from: vaultMatches)

        let bypassCache = shouldBypassCache(for: searchDecision)
        let shouldPreferVaultOverCache = hasStrongVaultMatch
        
        // 0. CACHE CHECK
        if !bypassCache, !shouldPreferVaultOverCache, let cachedAnswer = cacheService.getResponse(for: query) {
            logger.info("Cache HIT for query: \(self.sanitize(query))")
            await MainActor.run {
                onStatusUpdate("Ready")
                onPartialResponse(cachedAnswer)
            }
            return cachedAnswer
        } else if bypassCache {
            logger.info("Cache bypassed due to freshness-sensitive query")
        } else if shouldPreferVaultOverCache {
            logger.info("Cache bypassed due to strong interview vault match")
        }

        // Variant-aware direct vault answer for low-latency interview flow.
        if imageData == nil,
           searchDecision != .required,
           responseProfile == .interviewConcise,
           let topVaultMatch = vaultMatches.first,
           topVaultMatch.score >= 0.64 {
            let directVaultAnswer = topVaultMatch.record.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !directVaultAnswer.isEmpty,
               canUseDirectVaultAnswer(
                queryLanguageCode: finalLanguageCode,
                answer: directVaultAnswer
               ) {
                logger.info("Direct vault reply used (score: \(topVaultMatch.score, privacy: .public))")
                let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
                let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: directVaultAnswer, images: nil)
                conversationHistory.append(userMessage)
                conversationHistory.append(assistantMessage)
                if conversationHistory.count > maxHistoryLimit * 2 {
                    conversationHistory.removeFirst(2)
                }
                await MainActor.run {
                    onStatusUpdate("Ready (Vault)")
                    onPartialResponse(directVaultAnswer)
                }
                return directVaultAnswer
            }
        }
        
        await MainActor.run { onStatusUpdate("Thinking...") }
        
        // 0.4 GATHER SYSTEM CONTEXT
        let systemContext = await systemStatusService?.getSystemContextSummary() ?? ""
        
        // 0.5 RAG RETRIEVAL (if enabled)
        var ragContext = ""
        
        if let retriever = semanticRetriever {
            do {
                await MainActor.run { onStatusUpdate("Searching memory...") }
                let retrieved = try await retriever.retrieve(query: query, topK: 5)
                
                if !retrieved.isEmpty {
                    ragContext = "\n[RETRIEVED FROM MEMORY]:\n" + retrieved.map { context in
                        let compactText = context.chunkText
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let snippet = String(compactText.prefix(420))
                        return """
                        - Source: \(context.sourceDisplay) | Similarity: \(String(format: "%.2f", context.similarity))
                          Context: \(snippet)
                        """
                    }.joined(separator: "\n") + "\n"
                    
                    logger.info("🧠 RAG: Retrieved \(retrieved.count) contexts")
                }
            } catch {
                logger.error("⚠️ RAG retrieval failed: \(error.localizedDescription)")
            }
        }
        
        // 1. DECISION: Need web search?
        var searchContext = ""
        var webSearchAttempted = false
        var webSearchSucceeded = false
        var webSearchFailureReason = ""
        
        if imageData == nil {
            let shouldSearchWeb: Bool
            switch searchDecision {
            case .required:
                shouldSearchWeb = true
            case .optional:
                shouldSearchWeb = (try? await decideWebSearchUsingLLMGate(query: query)) ?? false
            case .notNeeded:
                shouldSearchWeb = false
            }
            
            if shouldSearchWeb {
                webSearchAttempted = true
                do {
                    await MainActor.run { onStatusUpdate("Searching web...") }
                    let searchDetailLevel: TavilyService.DetailLevel =
                        responseProfile == .interviewConcise ? .brief : .detailed
                    searchContext = try await tavilyService.search(query: query, detailLevel: searchDetailLevel)
                    webSearchSucceeded = true
                    await MainActor.run { onStatusUpdate("Synthesizing...") }
                } catch {
                    webSearchFailureReason = error.localizedDescription
                    logger.error("Web search execution failed: \(error.localizedDescription)")
                }
            }
        }

        if imageData == nil, searchDecision == .required, webSearchAttempted, !webSearchSucceeded {
            let fallback = liveWebVerificationUnavailableMessage(languageCode: finalLanguageCode)
            let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
            let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: fallback, images: nil)
            conversationHistory.append(userMessage)
            conversationHistory.append(assistantMessage)
            if conversationHistory.count > maxHistoryLimit * 2 {
                conversationHistory.removeFirst(2)
            }
            await MainActor.run {
                onPartialResponse(fallback)
                onStatusUpdate("Web unavailable")
            }
            return fallback
        }
        
        // 2. CONSTRUCT SYSTEM PROMPT
        let rolePrompt: String = (imageData != nil) ? 
            "senior software engineer identifying issues from a screen capture. CRITICAL: Identify language of text in image FIRST, then respond IN THAT LANGUAGE." : 
            "senior software engineer assistant in a live interview/meeting"
            
        let storedPersona = UserDefaults.standard.string(forKey: "userPersonaContext") ?? ""
        let persistentPersona = storedPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionPersona = transientPersonaContext.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let mergedPersona: String
        if !persistentPersona.isEmpty && !sessionPersona.isEmpty {
            mergedPersona = """
            \(persistentPersona)
            
            [SESSION INTERVIEW CONTEXT]
            \(sessionPersona)
            """
        } else if !persistentPersona.isEmpty {
            mergedPersona = persistentPersona
        } else if !sessionPersona.isEmpty {
            mergedPersona = sessionPersona
        } else {
            mergedPersona = "No specific persona defined. Act as a helpful AI assistant."
        }
        var languageInstruction = "Respond in the EXACT SAME LANGUAGE as the question."

        if let langCode = finalLanguageCode {
            switch langCode {
            case "tr", "turkish": languageInstruction = "The user is asking in TURKISH. Respond ONLY in TURKISH."
            case "en", "english": languageInstruction = "The user is asking in ENGLISH. Respond ONLY in ENGLISH."
            case "fi", "finnish": languageInstruction = "The user is asking in FINNISH. CRITICAL: Use 'Professional Puheenkieli'."
            default: break
            }
        }

        let actionPolicy: String
        if allowAgentActions {
            actionPolicy = """
            6. OPERATIONAL RULES:
               - SILENT EXECUTION: If performing action, output ONLY [ACTION: ...] tag.
               - ACTION TYPES: Allowed action types are ONLY "applescript" or "stop". NEVER emit "shell".
               - NO internal reasoning or hidden tags in final answer.
            """
        } else {
            actionPolicy = """
            6. OPERATIONAL RULES:
               - NEVER output ACTION tags, shell scripts, AppleScript payloads, or JSON action objects.
               - Return only natural-language answer text.
               - NO internal reasoning or hidden tags in final answer.
            """
        }

        let responseStyleInstruction = responseStyleInstruction(for: responseProfile)
        let vaultPriorityHint = hasStrongVaultMatch
            ? "Strong vault match detected (score: \(String(format: "%.2f", strongestVaultScore))). Base the answer primarily on vault content, then adapt naturally."
            : "If vault match is weak or absent, use memory/web/general reasoning in that order."
        let webSearchStatusHint: String = {
            if webSearchAttempted && webSearchSucceeded {
                return "[WEB SEARCH STATUS]\nLive web evidence retrieved successfully."
            }
            if webSearchAttempted && !webSearchSucceeded {
                let reason = webSearchFailureReason.isEmpty ? "Unknown error" : webSearchFailureReason
                return "[WEB SEARCH STATUS]\nLive web search failed: \(reason)"
            }
            return ""
        }()
        
        let systemPrompt = """
        [IDENTITY & ROLE]
        You are a \(rolePrompt). 
        Default voice: clear, interview-ready spoken sentences.
        
        [USER PERSONA]:
        \(mergedPersona)
        
        [INSTRUCTIONS]
        1. KNOWLEDGE PRIORITY:
           - First: [USER PERSONA]
           - Second: [INTERVIEW VAULT MATCHES]
           - Third: [RETRIEVED FROM MEMORY]
           - Fourth: CONTEXT FROM SEARCH
           - Fifth: General reasoning fallback
           - \(vaultPriorityHint)
           - If there is no direct answer in vault/memory, produce a sensible best-practice answer.
        2. CONTEXTUAL INTELLIGENCE:
           \(vaultContext)
           \(ragContext)
           \(searchContext.isEmpty ? "" : "CONTEXT FROM SEARCH:\n\(searchContext)\n")
           \(webSearchStatusHint.isEmpty ? "" : "\(webSearchStatusHint)\n")
           \(systemContext.isEmpty ? "" : "SYSTEM CONTEXT:\n\(systemContext)\n")
        
        3. LANGUAGE LOCK: \(languageInstruction)
           Never switch language mid-answer. Never mix unrelated languages.
           If user writes informally, keep professional spoken tone.
        
        4. RESPONSE STYLE:
           \(responseStyleInstruction)
           - Write in natural spoken language for read-aloud (not robotic, no slang overload).
           - Understand the exact question before answering; avoid irrelevant detours.
           - Avoid markdown/list/table unless explicitly requested by the user.
        
        5. FACTUAL SAFETY:
           - Do not invent facts, names, or metrics.
           - Do not invent benchmark scores or release details. If unverified, say that clearly.
           - Never output fake citation markers like [1], [2], [^1].
           - If fresh verification is required and web search is unavailable, clearly say verification is unavailable now and do not guess.
           - If uncertain, say so briefly and give the safest answer.
        
        \(actionPolicy)
        
        \(AutomationLibrary.getPromptContext())
        """
        
        // 3. CONSTRUCT MESSAGE ARRAY
        var messages: [OllamaService.ChatMessage] = []
        
        // A. Add System Prompt
        messages.append(OllamaService.ChatMessage(role: "system", content: systemPrompt, images: nil))
        
        // B. Add Curated History (only last N to prevent bloat)
        let contextHistory = conversationHistory.suffix(maxHistoryLimit)
        messages.append(contentsOf: contextHistory)
        
        // C. Add Current Query
        var chatImages: [String]? = nil
        if let data = imageData {
             chatImages = [data.base64EncodedString()]
        }
        let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: chatImages)
        messages.append(userMessage)
        
        // 4. STREAMING EXECUTION
        var model = (imageData != nil) ? AIModelNames.vision : AIModelNames.reasoning
        let isSlashCommand = query.starts(with: "/")
        let isSystemCommand = query.count < 30 && ["mute", "unmute", "volume", "trash", "empty", "pause", "play", "stop"].contains { lowerQuery.contains($0) }
        let isCodingQuery = imageData == nil && isCodingRelatedQuery(lowerQuery)
        let structuredOutputRequested = isStructuredOutputRequested(lowerQuery) || responseProfile == .detailedTable
        let shouldUseActionFastPath = allowAgentActions && (isSlashCommand || isSystemCommand)
        
        if isCodingQuery {
            model = AIModelNames.coding
        }
        
        if shouldUseActionFastPath {
            model = AIModelNames.fast
        }
        
        // Specialized Prompt for Fast Model (Action-Only)
        if shouldUseActionFastPath && model == AIModelNames.fast {
            let fastPrompt = "[ACTION_ONLY] Input: \"\(query)\". Output ONLY JSON format: [ACTION: {\"type\": \"applescript\", \"payload\": \"...\"}]"
            messages = [OllamaService.ChatMessage(role: "user", content: fastPrompt, images: nil)]
        }
        
        do {
            var fullAnswer = ""
            
            try await ollamaService.generateStreaming(messages: messages, model: model) { partialAnswer in
                fullAnswer = partialAnswer
                onPartialResponse(partialAnswer)
            }
            
            let finalizedAnswer = await enforceOutputContractIfNeeded(
                answer: fullAnswer,
                query: query,
                expectedLanguageCode: finalLanguageCode,
                structuredOutputRequested: structuredOutputRequested,
                responseProfile: responseProfile,
                skipPostProcessing: imageData != nil || shouldUseActionFastPath,
                allowAgentActions: allowAgentActions
            )
            
            // 5. UPDATE INTERNAL HISTORY
            conversationHistory.append(userMessage)
            conversationHistory.append(OllamaService.ChatMessage(role: "assistant", content: finalizedAnswer, images: nil))
            
            // Limit history
            if conversationHistory.count > maxHistoryLimit * 2 {
                conversationHistory.removeFirst(2)
            }
            
            return await MainActor.run {
                onPartialResponse(finalizedAnswer)
                onStatusUpdate("Ready")
                return finalizedAnswer
            }
        } catch {
            logger.error("Generation failed: \(error.localizedDescription)")
            onStatusUpdate("Error: Generation Failed")
            throw error
        }
    }
    
    /// Redacts sensitive information from logs
    private func sanitize(_ text: String) -> String {
        guard text.count > 20 else { return text }
        return "[REDACTED (length: \(text.count))]"
    }
    
    private func shouldBypassCache(for decision: SearchDecision) -> Bool {
        decision == .required
    }
    
    private func searchDecisionForQuery(_ query: String) -> SearchDecision {
        let normalized = query.lowercased()
        
        // Strong freshness/dynamic intent -> always search and bypass cache.
        let requiredTokens = [
            "today", "latest", "current", "right now", "as of", "breaking", "news", "update",
            "price", "stock", "weather", "score", "standings", "schedule", "odds",
            "exchange rate", "rate", "interest rate", "law", "regulation", "release date",
            "bugün", "en son", "güncel", "şu an", "haber", "fiyat", "hava durumu",
            "skor", "puan durumu", "maç", "kur", "oran", "faiz", "yasa", "mevzuat",
            "çıktı mı", "cikti mi", "duyuruldu", "released", "release", "announced",
            "benchmark", "benchmark sonuç", "benchmark sonuclari",
            "başkanı", "başkan", "president", "prime minister", "ceo"
        ]
        
        if containsAnyToken(in: normalized, tokens: requiredTokens) {
            return .required
        }
        
        // Potentially dynamic or recommendation-like requests -> optional LLM gate.
        let optionalTokens = [
            "recommend", "best", "compare", "vs", "alternatives", "docs", "documentation",
            "api", "library", "framework", "which one", "trend",
            "research", "sources", "source", "internet", "web",
            "öner", "en iyi", "karşılaştır", "alternatif", "dokümantasyon", "hangisi",
            "araştır", "kaynak", "internetten"
        ]
        
        if containsAnyToken(in: normalized, tokens: optionalTokens) {
            return .optional
        }
        
        return .notNeeded
    }
    
    private func containsAnyToken(in text: String, tokens: [String]) -> Bool {
        tokens.contains { token in
            text.contains(token)
        }
    }
    
    private func decideWebSearchUsingLLMGate(query: String) async throws -> Bool {
        let searchDecisionPrompt = """
        Query: "\(query)"
        Decide if this question REQUIRES live web data for accuracy.
        If the query asks about release status, benchmark, leadership/person/title, or current events, answer YES.
        Return only YES or NO.
        """
        
        let decision = try await ollamaService.generate(
            messages: [OllamaService.ChatMessage(role: "user", content: searchDecisionPrompt, images: nil)],
            model: AIModelNames.fast
        )
        
        let cleaned = decision.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return cleaned.contains("YES") || cleaned.contains("TRUE")
    }
    
    private func isStructuredOutputRequested(_ normalizedQuery: String) -> Bool {
        let tokens = [
            "list", "bullet", "steps", "step by step", "table", "markdown", "format",
            "madde", "adim", "adım adım", "tablo", "liste", "markdown",
            "tablolu", "karsilastir", "karşılaştır", "comparison", "matrix"
        ]
        return containsAnyToken(in: normalizedQuery, tokens: tokens)
    }
    
    private func isLanguageMismatch(_ text: String, expectedLanguageCode: String?) -> Bool {
        guard text.count > 24, let expected = expectedLanguageCode?.lowercased() else { return false }
        
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage?.rawValue.lowercased() else { return false }
        
        switch expected {
        case "tr", "turkish": return detected != "tr"
        case "en", "english": return detected != "en"
        case "fi", "finnish": return detected != "fi"
        default: return false
        }
    }
    
    private func shouldCondenseResponse(
        _ text: String,
        structuredOutputRequested: Bool,
        responseProfile: ResponseProfile
    ) -> Bool {
        guard !structuredOutputRequested else { return false }
        
        let lineCount = text.split(whereSeparator: \.isNewline).count
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let hasStructuredMarkers = text.contains("\n- ") || text.contains("\n1.") || text.contains("|")

        switch responseProfile {
        case .interviewConcise:
            return wordCount > 110 || lineCount > 6 || hasStructuredMarkers
        case .detailedNarrative:
            return wordCount > 260 || lineCount > 18
        case .detailedTable:
            return false
        }
    }
    
    private func languageName(for expectedLanguageCode: String?) -> String {
        guard let code = expectedLanguageCode?.lowercased() else { return "the user's language" }
        switch code {
        case "tr", "turkish": return "Turkish"
        case "en", "english": return "English"
        case "fi", "finnish": return "Finnish"
            default: return "the user's language"
        }
    }

    private func liveWebVerificationUnavailableMessage(languageCode: String?) -> String {
        let code = languageCode?.lowercased() ?? ""
        switch code {
        case "tr", "turkish":
            return "Bu soru güncel web doğrulaması gerektiriyor ama şu an web araması çalışmadı. Yanlış bilgi vermemek için doğrulanmış cevap veremiyorum; lütfen kısa süre sonra tekrar deneyin."
        case "fi", "finnish":
            return "Tämä kysymys vaatii ajantasaisen verkkovarmistuksen, mutta verkkohaku epäonnistui juuri nyt. En halua arvata väärin, joten varmennettua vastausta ei voi antaa tällä hetkellä."
        default:
            return "This question needs live web verification, but web search failed right now. To avoid misinformation, I can’t provide a verified answer at the moment."
        }
    }
    
    private func enforceOutputContractIfNeeded(
        answer: String,
        query: String,
        expectedLanguageCode: String?,
        structuredOutputRequested: Bool,
        responseProfile: ResponseProfile,
        skipPostProcessing: Bool,
        allowAgentActions: Bool
    ) async -> String {
        let baseText = allowAgentActions ? answer : stripActionArtifacts(from: answer)
        let sanitized = sanitizeCitationArtifacts(in: baseText)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return allowAgentActions ? answer : "Hazırım. Sorunu kısa yaz, net cevap vereyim."
        }
        guard !skipPostProcessing else { return trimmed }
        guard !trimmed.contains("[ACTION:") else { return trimmed }
        
        let needsLanguageFix = isLanguageMismatch(trimmed, expectedLanguageCode: expectedLanguageCode)
        let needsCondense = shouldCondenseResponse(
            trimmed,
            structuredOutputRequested: structuredOutputRequested,
            responseProfile: responseProfile
        )
        let needsExpansion = shouldExpandResponse(
            trimmed,
            query: query,
            responseProfile: responseProfile,
            structuredOutputRequested: structuredOutputRequested
        )
        guard needsLanguageFix || needsCondense || needsExpansion else { return trimmed }
        
        // Latency guard: avoid second model call for short/acceptable answers.
        let shouldRewriteForLanguage = needsLanguageFix && trimmed.count > 220
        let shouldRewriteForLength = needsCondense && trimmed.count > 700
        let shouldRewriteForExpansion = needsExpansion && trimmed.count < 180
        guard shouldRewriteForLanguage || shouldRewriteForLength || shouldRewriteForExpansion else {
            return trimmed
        }
        let expansionRule = shouldRewriteForExpansion
            ? "- Expand to 2-4 short sentences without adding new facts."
            : ""
        
        let rewritePrompt = """
        USER QUESTION:
        \(query)
        
        ORIGINAL ANSWER:
        \(trimmed)
        
        Rewrite with strict rules:
        - Keep EXACT meaning; do not add any new facts.
        - Output only \(languageName(for: expectedLanguageCode)).
        \(rewriteStyleRules(for: responseProfile))
        \(expansionRule)
        
        Return only rewritten answer.
        """
        
        guard let rewritten = try? await ollamaService.generate(
            messages: [OllamaService.ChatMessage(role: "user", content: rewritePrompt, images: nil)],
            model: AIModelNames.fast
        ) else {
            return trimmed
        }
        
        return sanitizeCitationArtifacts(in: rewritten)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func stripActionArtifacts(from text: String) -> String {
        var cleaned = text
        
        cleaned = cleaned.replacingOccurrences(
            of: #"(?s)\[ACTION:.*?\]"#,
            with: "",
            options: .regularExpression
        )
        
        let jsonActionPattern = #"(?s)^\s*\{[\s\S]*"type"\s*:\s*"(applescript|shell|stop)"[\s\S]*"payload"\s*:\s*"[\s\S]*"\s*\}\s*$"#
        if cleaned.range(of: jsonActionPattern, options: .regularExpression) != nil {
            return ""
        }
        
        if cleaned.contains("\"type\""), cleaned.contains("\"payload\""), (cleaned.contains("applescript") || cleaned.contains("shell")) {
            return ""
        }
        
        return cleaned
    }
    
    private func isCodingRelatedQuery(_ normalizedQuery: String) -> Bool {
        let codingTokens = [
            "code", "coding", "algorithm", "bug", "debug", "fix", "compile", "build", "syntax",
            "stack trace", "exception", "error", "crash", "refactor", "test", "unit test",
            "integration test", "function", "class", "struct", "interface", "api endpoint",
            "repository", "repo", "pull request", "commit", "diff", "xcode", "swift", "swiftui",
            "typescript", "javascript", "python", "java", "kotlin", "go", "rust", "sql", "regex",
            "docker", "kubernetes", "react", "node", "backend", "frontend",
            "kod", "kodlama", "hata", "derleme", "test senaryosu", "birim testi", "fonksiyon",
            "sinif", "algoritma", "coz", "duzelt", "cokuyor"
        ]
        
        if containsAnyToken(in: normalizedQuery, tokens: codingTokens) {
            return true
        }
        
        let codeLikeTokens = [
            "```", "func ", "class ", "struct ", "interface ", "def ",
            "select ", "insert into ", "update ", "delete from ", "create table ",
            "public ", "private ", "return "
        ]
        return containsAnyToken(in: normalizedQuery, tokens: codeLikeTokens)
    }

    private func responseProfile(for normalizedQuery: String) -> ResponseProfile {
        let tableTokens = [
            "table", "tablo", "tablolu", "comparison", "compare", "karşılaştır",
            "karsilastir", "matrix", "pros cons", "arti eksi", "artı eksi"
        ]
        if containsAnyToken(in: normalizedQuery, tokens: tableTokens) {
            return .detailedTable
        }

        let detailTokens = [
            "detay", "detayli", "detaylı", "ayrinti", "ayrıntı", "kapsamli", "kapsamlı",
            "comprehensive", "in-depth", "deep dive", "deep", "explain", "acikla", "açıkla",
            "neden", "nasil", "nasıl", "step by step", "adim adim", "adım adım",
            "ornek", "örnek", "example", "analyze", "analiz",
            "benchmark", "performans", "performance", "karsilastirma", "karşılaştırma"
        ]
        if containsAnyToken(in: normalizedQuery, tokens: detailTokens) {
            return .detailedNarrative
        }

        return .interviewConcise
    }

    private func responseStyleInstruction(for profile: ResponseProfile) -> String {
        switch profile {
        case .interviewConcise:
            return """
            - Keep it concise but not too short: usually 2-4 short sentences.
            - Prefer direct, human-like spoken phrasing.
            """
        case .detailedNarrative:
            return """
            - User requested detail: provide richer explanation (about 5-8 sentences).
            - Keep structure clear and practical; use short paragraphs.
            """
        case .detailedTable:
            return """
            - User requested structured output: you may use markdown table and short supporting notes.
            - Keep each cell concise and avoid filler.
            """
        }
    }

    private func rewriteStyleRules(for profile: ResponseProfile) -> String {
        switch profile {
        case .interviewConcise:
            return """
            - Keep it spoken and clear: usually 2-4 short sentences.
            - No markdown, no list, no table, no headings.
            """
        case .detailedNarrative:
            return """
            - Keep a natural spoken tone and include needed detail (5-8 sentences).
            - Use short paragraphs; no headings unless requested.
            """
        case .detailedTable:
            return """
            - If comparison fits, keep markdown table; otherwise concise paragraph.
            - Do not add facts that are not in the original answer.
            """
        }
    }

    private func retrieveVaultMatches(for query: String, maxResults: Int) async -> [InterviewKnowledgeMatch] {
        let snapshot = await MainActor.run { VaultService.shared.categories }
        guard !snapshot.isEmpty else { return [] }

        let records = snapshot.flatMap { category in
            category.items.map { item in
                InterviewKnowledgeRecord(
                    category: category.title,
                    question: item.question,
                    answer: item.answerFinnish,
                    keyPoints: item.keyPoints
                )
            }
        }

        return InterviewKnowledgeMatcher.topMatches(
            query: query,
            records: records,
            maxResults: maxResults,
            minimumScore: 0.16
        )
    }

    private func buildVaultContext(from matches: [InterviewKnowledgeMatch]) -> String {
        guard !matches.isEmpty else { return "" }

        let maxCharacters = 2_600
        var usedCharacters = 0
        var lines: [String] = ["[INTERVIEW VAULT MATCHES]"]

        for (index, match) in matches.enumerated() {
            let entry = """
            [\(index + 1)] Category: \(match.record.category) | Score: \(String(format: "%.2f", match.score))
            Q: \(compactVaultText(match.record.question, limit: 220))
            A: \(compactVaultText(match.record.answer, limit: 420))
            KeyPoints: \(match.record.keyPoints.isEmpty ? "-" : match.record.keyPoints.joined(separator: ", "))
            """

            if usedCharacters + entry.count > maxCharacters {
                break
            }

            lines.append(entry)
            usedCharacters += entry.count
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func compactVaultText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    private func canUseDirectVaultAnswer(queryLanguageCode: String?, answer: String) -> Bool {
        guard let queryLanguageCode, !queryLanguageCode.isEmpty else { return true }
        let shortQueryCode = String(queryLanguageCode.prefix(2))
        guard !shortQueryCode.isEmpty else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(answer)
        guard let answerLanguageCode = recognizer.dominantLanguage?.rawValue else {
            return true
        }
        let shortAnswerCode = String(answerLanguageCode.prefix(2))
        return shortAnswerCode == shortQueryCode
    }

    private func shouldExpandResponse(
        _ text: String,
        query: String,
        responseProfile: ResponseProfile,
        structuredOutputRequested: Bool
    ) -> Bool {
        guard responseProfile == .interviewConcise, !structuredOutputRequested else { return false }

        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let sentenceSeparators = CharacterSet(charactersIn: ".!?")
        let sentenceCount = text
            .components(separatedBy: sentenceSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
        let normalizedQuery = query.lowercased()
        let questionStarters = [
            "who", "what", "when", "where", "why", "how",
            "kim", "ne", "neden", "nasıl", "hangi", "kac", "kaç"
        ]
        let isQuestion = query.contains("?") || questionStarters.contains { normalizedQuery.hasPrefix($0 + " ") }

        return isQuestion && (wordCount < 18 || sentenceCount < 2)
    }

    private func sanitizeCitationArtifacts(in text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: #"\[\^\d+\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\[\d+(?:,\s*\d+)*\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #" \n"#, with: "\n", options: .regularExpression)
        return cleaned
    }
}
