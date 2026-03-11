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

    private struct MultiQuestionResolution {
        let directAnswer: String?
        let promptContext: String
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
        let normalizedQueryTokenCount = InterviewKnowledgeMatcher
            .normalize(query)
            .split(separator: " ")
            .count
        let normalizedQueryForIntent = InterviewKnowledgeMatcher.normalize(query)
        let compensationIntent = isCompensationIntent(normalizedQueryForIntent)
        let selfIntroIntent = isSelfIntroIntent(normalizedQueryForIntent)
        let questionSegments = Self.splitQuestionSegments(query)
        let isMultiQuestionQuery = questionSegments.count >= 2

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

        var interviewMatches: [InterviewKnowledgeMatch] = []
        var interviewFallbackAnchors: [InterviewKnowledgeMatch] = []
        var multiQuestionPromptContext = ""
        if imageData == nil {
            await MainActor.run { onStatusUpdate("Checking interview notes + vault...") }
            let vaultResultLimit: Int = {
                if responseProfile == .interviewConcise {
                    return normalizedQueryTokenCount <= 5 ? 2 : 3
                }
                return 5
            }()
            interviewMatches = await retrieveInterviewMatches(
                for: query,
                maxResults: vaultResultLimit,
                minimumScore: 0.16
            )

            let strongestPrimaryScore = interviewMatches.first?.score ?? 0
            if responseProfile == .interviewConcise {
                if strongestPrimaryScore < 0.28 {
                    interviewFallbackAnchors = await retrieveInterviewMatches(
                        for: query,
                        maxResults: normalizedQueryTokenCount <= 5 ? 3 : 4,
                        minimumScore: 0.0
                    )
                } else {
                    interviewFallbackAnchors = Array(interviewMatches.prefix(3))
                }

                if isMultiQuestionQuery {
                    let resolution = await resolveMultiQuestionQuery(
                        segments: questionSegments,
                        expectedLanguageCode: finalLanguageCode
                    )
                    multiQuestionPromptContext = resolution.promptContext

                    if searchDecision != .required, let direct = resolution.directAnswer {
                        let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
                        let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: direct, images: nil)
                        conversationHistory.append(userMessage)
                        conversationHistory.append(assistantMessage)
                        if conversationHistory.count > maxHistoryLimit * 2 {
                            conversationHistory.removeFirst(2)
                        }
                        await MainActor.run {
                            onStatusUpdate("Ready (Interview x\(questionSegments.count))")
                            onPartialResponse(direct)
                        }
                        return direct
                    }
                }
            }
        }
        let strongestInterviewScore = interviewMatches.first?.score ?? 0
        let shouldPreferInterviewKnowledgeOverCache =
            isMultiQuestionQuery ||
            strongestInterviewScore >= 0.34 ||
            (compensationIntent && strongestInterviewScore >= 0.20) ||
            (selfIntroIntent && strongestInterviewScore >= 0.28)
        let interviewContext = buildVaultContext(
            from: interviewMatches,
            maxEntries: responseProfile == .interviewConcise ? 1 : 4,
            questionLimit: responseProfile == .interviewConcise ? 160 : 220,
            answerLimit: responseProfile == .interviewConcise ? 260 : 420
        )
        let interviewFallbackContext = buildVaultContext(
            from: interviewFallbackAnchors,
            maxEntries: responseProfile == .interviewConcise ? 2 : 3,
            questionLimit: responseProfile == .interviewConcise ? 120 : 180,
            answerLimit: responseProfile == .interviewConcise ? 200 : 320,
            header: "[INTERVIEW FALLBACK ANCHORS]"
        )

        let bypassCache = shouldBypassCache(for: searchDecision)
        
        // 0. CACHE CHECK
        if !bypassCache, !shouldPreferInterviewKnowledgeOverCache, let cachedAnswer = cacheService.getResponse(for: query) {
            logger.info("Cache HIT for query: \(self.sanitize(query))")
            await MainActor.run {
                onStatusUpdate("Ready")
                onPartialResponse(cachedAnswer)
            }
            return cachedAnswer
        } else if bypassCache {
            logger.info("Cache bypassed due to freshness-sensitive query")
        } else if shouldPreferInterviewKnowledgeOverCache {
            logger.info("Cache bypassed due to interview notes/vault priority")
        }

        // Variant-aware direct interview answer for low-latency interview flow.
        if imageData == nil,
           searchDecision != .required,
           responseProfile == .interviewConcise,
           let topInterviewMatch = interviewMatches.first {
            let secondInterviewScore = interviewMatches.dropFirst().first?.score ?? 0
            let directInterviewAnswer = topInterviewMatch.record.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let introIntentFastPath =
                selfIntroIntent &&
                topInterviewMatch.score >= 0.36 &&
                topInterviewMatch.matchedTokenCount >= 1
            let compensationIntentFastPath =
                compensationIntent &&
                isCompensationRecord(topInterviewMatch.record) &&
                topInterviewMatch.score >= 0.20
            let generalInterviewFastPath =
                topInterviewMatch.score >= 0.56 &&
                topInterviewMatch.matchedTokenCount >= 1 &&
                (topInterviewMatch.score - secondInterviewScore) >= 0.03

            if !directInterviewAnswer.isEmpty,
               (
                canUseDirectVaultFastPath(
                queryTokenCount: normalizedQueryTokenCount,
                topMatch: topInterviewMatch,
                secondBestScore: secondInterviewScore
                ) || introIntentFastPath || compensationIntentFastPath || generalInterviewFastPath
               ),
               canUseDirectVaultAnswer(
                queryLanguageCode: finalLanguageCode,
                answer: directInterviewAnswer
               ) {
                logger.info("Direct interview-knowledge reply used (score: \(topInterviewMatch.score, privacy: .public))")
                let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
                let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: directInterviewAnswer, images: nil)
                conversationHistory.append(userMessage)
                conversationHistory.append(assistantMessage)
                if conversationHistory.count > maxHistoryLimit * 2 {
                    conversationHistory.removeFirst(2)
                }
                await MainActor.run {
                    onStatusUpdate("Ready (Interview)")
                    onPartialResponse(directInterviewAnswer)
                }
                return directInterviewAnswer
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
        let interviewPriorityHint = strongestInterviewScore >= 0.30
            ? "Strong interview match detected (score: \(String(format: "%.2f", strongestInterviewScore))). Use Interview Notes/Vault content first and do not invent numbers."
            : "If interview match is weak or absent, use persona/memory/web/general reasoning in that order."
        let interviewFallbackHint = interviewFallbackContext.isEmpty
            ? "If there is no direct interview answer, generate a cautious answer from [USER PERSONA] only and keep uncertainty explicit."
            : "If there is no direct interview answer, synthesize from [USER PERSONA] and [INTERVIEW FALLBACK ANCHORS] without inventing precise facts."
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
           - First: [INTERVIEW VAULT MATCHES] (includes Interview Notes + Interview Vault)
           - Second: [USER PERSONA]
           - Third: [RETRIEVED FROM MEMORY]
           - Fourth: CONTEXT FROM SEARCH
           - Fifth: General reasoning fallback
           - \(interviewPriorityHint)
           - \(interviewFallbackHint)
           - If query is unclear/noise, ask one short clarification question instead of guessing.
        2. CONTEXTUAL INTELLIGENCE:
           \(interviewContext)
           \(interviewFallbackContext)
           \(multiQuestionPromptContext)
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
           - For short interview prompts, use only the single strongest interview match; do not merge unrelated topics.
           - If user asks multiple questions in one message, answer each question in the same order in separate short paragraphs.
           - Do not mention private contact details or salary unless explicitly asked.
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

    static func splitQuestionSegments(_ query: String) -> [String] {
        let compact = query
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return [] }

        let questionMarks = compact.filter { $0 == "?" }.count
        if questionMarks == 0 {
            return []
        }

        var segments: [String] = []
        var seen = Set<String>()
        let rawSegments = compact.components(separatedBy: "?")
        for raw in rawSegments {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 4 else { continue }
            let normalized = InterviewKnowledgeMatcher.normalize(cleaned)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            segments.append(cleaned + "?")
        }
        return Array(segments.prefix(3))
    }

    private func resolveMultiQuestionQuery(
        segments: [String],
        expectedLanguageCode: String?
    ) async -> MultiQuestionResolution {
        guard segments.count >= 2 else {
            return MultiQuestionResolution(directAnswer: nil, promptContext: "")
        }

        var directAnswers: [String] = []
        var contextParts: [String] = [
            "[MULTI-QUESTION BREAKDOWN]",
            "User asked \(segments.count) questions in one message.",
            "Answer each question in the same order (Q1, Q2, ...)."
        ]
        var hasUnresolvedSegment = false

        for (index, segment) in segments.enumerated() {
            contextParts.append("Q\(index + 1): \(segment)")
            let normalizedSegment = InterviewKnowledgeMatcher.normalize(segment)
            let tokenCount = normalizedSegment.split(separator: " ").count
            let segmentIntroIntent = isSelfIntroIntent(normalizedSegment)
            let segmentCompensationIntent = isCompensationIntent(normalizedSegment)

            let strongMatches = await retrieveInterviewMatches(
                for: segment,
                maxResults: 3,
                minimumScore: 0.16
            )
            let topStrong = strongMatches.first

            var anchorMatches = strongMatches
            if anchorMatches.isEmpty || (anchorMatches.first?.score ?? 0) < 0.24 {
                anchorMatches = await retrieveInterviewMatches(
                    for: segment,
                    maxResults: 2,
                    minimumScore: 0.0
                )
            }

            if let topStrong {
                let answer = topStrong.record.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                let canUseDirect = canUseDirectMultiQuestionMatch(
                    topMatch: topStrong,
                    queryTokenCount: tokenCount,
                    isIntroIntent: segmentIntroIntent,
                    isCompensationIntent: segmentCompensationIntent
                ) && canUseDirectVaultAnswer(
                    queryLanguageCode: expectedLanguageCode,
                    answer: answer
                )
                if !answer.isEmpty && canUseDirect {
                    directAnswers.append(answer)
                } else {
                    hasUnresolvedSegment = true
                }
            } else {
                hasUnresolvedSegment = true
            }

            let anchorContext = buildVaultContext(
                from: anchorMatches,
                maxEntries: 2,
                questionLimit: 120,
                answerLimit: 190,
                header: "[Q\(index + 1) ANCHORS]"
            )
            if !anchorContext.isEmpty {
                contextParts.append(anchorContext)
            }
        }

        let directAnswer: String?
        if !hasUnresolvedSegment && directAnswers.count == segments.count {
            let uniqueAnswerCount = Set(directAnswers.map { InterviewKnowledgeMatcher.normalize($0) }).count
            if uniqueAnswerCount >= segments.count {
                directAnswer = mergeMultiQuestionAnswers(directAnswers, expectedLanguageCode: expectedLanguageCode)
            } else {
                directAnswer = nil
            }
        } else {
            directAnswer = nil
        }

        return MultiQuestionResolution(
            directAnswer: directAnswer,
            promptContext: contextParts.joined(separator: "\n") + "\n"
        )
    }

    private func canUseDirectMultiQuestionMatch(
        topMatch: InterviewKnowledgeMatch,
        queryTokenCount: Int,
        isIntroIntent: Bool,
        isCompensationIntent: Bool
    ) -> Bool {
        if isCompensationIntent && isCompensationRecord(topMatch.record) && topMatch.score >= 0.20 {
            return true
        }
        if isIntroIntent && topMatch.score >= 0.34 && topMatch.matchedTokenCount >= 1 {
            return true
        }

        let isShort = queryTokenCount <= 6
        let threshold = isShort ? 0.30 : 0.42
        return topMatch.score >= threshold && topMatch.matchedTokenCount >= 1
    }

    private func mergeMultiQuestionAnswers(_ answers: [String], expectedLanguageCode: String?) -> String {
        guard answers.count > 1 else { return answers.first ?? "" }
        let code = expectedLanguageCode?.lowercased() ?? ""

        return answers.enumerated().map { index, answer in
            let label: String
            if code.hasPrefix("fi") {
                label = "Kysymys \(index + 1):"
            } else if code.hasPrefix("tr") {
                label = "Soru \(index + 1):"
            } else {
                label = "Question \(index + 1):"
            }
            return "\(label)\n\(answer)"
        }.joined(separator: "\n\n")
    }

    private func isSelfIntroIntent(_ normalizedQuery: String) -> Bool {
        let introPatterns = [
            "puhu sinusta", "kerro itsestasi", "kerro itsestäsi",
            "esittele itsesi", "introduce yourself", "tell me about yourself",
            "who are you", "kuka sina olet", "kuka sinä olet"
        ]
        if introPatterns.contains(where: { normalizedQuery.contains($0) }) {
            return true
        }

        let introTokens = [
            "itsestasi", "itsestäsi", "sinusta", "aboutyourself", "yourself", "introduce", "intro"
        ]
        return containsAnyToken(in: normalizedQuery, tokens: introTokens)
    }

    private func isCompensationIntent(_ normalizedQuery: String) -> Bool {
        let compensationTokens = [
            "palkka", "palkkatoive", "palkkatavoite", "palkkavaatimus", "palkkataso",
            "salary", "compensation", "wage", "brutto", "euro"
        ]
        if containsAnyToken(in: normalizedQuery, tokens: compensationTokens) {
            return true
        }

        let canonicalKeywords = InterviewKnowledgeMatcher.canonicalKeywords(from: normalizedQuery)
        return canonicalKeywords.contains("salary")
    }

    private func isCompensationRecord(_ record: InterviewKnowledgeRecord) -> Bool {
        let corpus = [
            record.category,
            record.question,
            record.answer,
            record.keyPoints.joined(separator: " ")
        ].joined(separator: " ")
        let canonicalKeywords = InterviewKnowledgeMatcher.canonicalKeywords(from: corpus)
        return canonicalKeywords.contains("salary")
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
        let needsReadabilityPolish = shouldPolishForReadability(
            trimmed,
            responseProfile: responseProfile,
            structuredOutputRequested: structuredOutputRequested
        )
        guard needsLanguageFix || needsCondense || needsExpansion || needsReadabilityPolish else { return trimmed }
        
        // Latency guard: avoid second model call for short/acceptable answers.
        let shouldRewriteForLanguage = needsLanguageFix && trimmed.count > 120
        let shouldRewriteForLength = needsCondense && trimmed.count > 520
        let shouldRewriteForExpansion = needsExpansion && trimmed.count < 180
        let shouldRewriteForReadability = needsReadabilityPolish && trimmed.count > 170
        guard shouldRewriteForLanguage || shouldRewriteForLength || shouldRewriteForExpansion || shouldRewriteForReadability else {
            return trimmed
        }
        let expansionRule = shouldRewriteForExpansion
            ? "- Expand to 2-4 short sentences without adding new facts."
            : ""
        let readabilityRule = shouldRewriteForReadability
            ? "- If answer is a long block, split into short paragraphs with one blank line every 2 sentences."
            : ""
        
        let rewritePrompt = """
        USER QUESTION:
        \(query)
        
        ORIGINAL ANSWER:
        \(trimmed)
        
        Rewrite with strict rules:
        - Keep EXACT meaning; do not add any new facts.
        - Fix malformed wording, spelling, and grammar while preserving facts.
        - Output only \(languageName(for: expectedLanguageCode)).
        \(rewriteStyleRules(for: responseProfile))
        \(expansionRule)
        \(readabilityRule)
        
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

    private func retrieveInterviewMatches(
        for query: String,
        maxResults: Int,
        minimumScore: Double = 0.16
    ) async -> [InterviewKnowledgeMatch] {
        let snapshot = await MainActor.run { VaultService.shared.categories }
        let queryLanguageCode = InterviewKnowledgeMatcher.dominantLanguageCode(for: query)

        let notesRecords = loadInterviewNotesRecords()
        let vaultRecords = snapshot.flatMap { category in
            category.items.map { item in
                InterviewKnowledgeRecord(
                    category: "Interview Vault > \(category.title)",
                    question: item.question,
                    answer: item.answerFinnish,
                    keyPoints: item.keyPoints
                )
            }
        }
        
        var records: [InterviewKnowledgeRecord] = []
        records.reserveCapacity(notesRecords.count + vaultRecords.count)
        var seenQuestionKeys = Set<String>()
        
        for record in notesRecords {
            let key = InterviewKnowledgeMatcher.normalize(record.question)
            guard !key.isEmpty, seenQuestionKeys.insert(key).inserted else { continue }
            records.append(record)
        }
        
        for record in vaultRecords {
            let key = InterviewKnowledgeMatcher.normalize(record.question)
            guard !key.isEmpty, seenQuestionKeys.insert(key).inserted else { continue }
            records.append(record)
        }
        
        guard !records.isEmpty else { return [] }

        let rawResultLimit: Int = {
            if minimumScore <= 0.01 {
                return max(maxResults * 4, maxResults + 6)
            }
            return max(maxResults * 2, maxResults + 2)
        }()
        let rawMatches = InterviewKnowledgeMatcher.topMatches(
            query: query,
            records: records,
            maxResults: rawResultLimit,
            minimumScore: minimumScore
        )
        guard !rawMatches.isEmpty else { return [] }

        let reranked = rawMatches
            .map { match -> InterviewKnowledgeMatch in
                let adjusted = adjustedVaultMatchScore(match, queryLanguageCode: queryLanguageCode)
                return InterviewKnowledgeMatch(
                    record: match.record,
                    score: adjusted,
                    matchedTokenCount: match.matchedTokenCount
                )
            }
            .filter { $0.score >= minimumScore }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.matchedTokenCount > rhs.matchedTokenCount
                }
                return lhs.score > rhs.score
            }

        return Array(reranked.prefix(maxResults))
    }

    private func loadInterviewNotesRecords() -> [InterviewKnowledgeRecord] {
        let rawNotes = UserDefaults.standard.string(forKey: "teleprompterText") ?? ""
        let blocks = parseInterviewNoteBlocks(from: rawNotes)
        guard !blocks.isEmpty else { return [] }
        
        return blocks.map { block in
            InterviewKnowledgeRecord(
                category: "Interview Notes",
                question: block.question,
                answer: block.details,
                keyPoints: block.keyPoints
            )
        }
    }

    private func parseInterviewNoteBlocks(from rawText: String) -> [(question: String, details: String, keyPoints: [String])] {
        let lines = rawText.components(separatedBy: .newlines)
        var blocks: [(question: String, details: String, keyPoints: [String])] = []
        var currentQuestion: String?
        var currentBodyLines: [String] = []
        
        func flushCurrent() {
            guard let currentQuestion else { return }
            let details = currentBodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let keyPoints = extractInterviewNoteKeyPoints(from: currentQuestion + "\n" + details)
            blocks.append((question: currentQuestion, details: details, keyPoints: keyPoints))
            currentBodyLines.removeAll(keepingCapacity: true)
        }
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isInterviewNoteQuestionLine(line) {
                flushCurrent()
                currentQuestion = cleanedInterviewQuestionLine(from: line)
                continue
            }
            
            guard currentQuestion != nil else { continue }
            if isInterviewNoteSeparatorLine(line) {
                currentBodyLines.append("")
                continue
            }
            currentBodyLines.append(rawLine)
        }
        
        flushCurrent()
        return blocks
    }

    private func isInterviewNoteQuestionLine(_ line: String) -> Bool {
        guard !line.isEmpty, line.contains("?"), line.count <= 180 else { return false }
        let normalized = InterviewKnowledgeMatcher.normalize(line)
        guard !normalized.isEmpty else { return false }
        
        let blockedPrefixes = [
            "turkcesi", "turkcesi:", "fince cevap", "daha kisa", "daha net", "ornek", "example"
        ]
        if blockedPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return false
        }
        return !isInterviewNoteSeparatorLine(line)
    }

    private func isInterviewNoteSeparatorLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let separatorChars = CharacterSet(charactersIn: "-_—–=•*|")
        let filtered = line.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !filtered.isEmpty else { return false }
        let separatorCount = filtered.filter { separatorChars.contains($0) }.count
        return separatorCount >= max(8, Int(Double(filtered.count) * 0.8))
    }

    private func cleanedInterviewQuestionLine(from line: String) -> String {
        let removedNumbering = line.replacingOccurrences(
            of: #"^\s*\d+\s*[\.\)]\s*"#,
            with: "",
            options: .regularExpression
        )
        return removedNumbering.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractInterviewNoteKeyPoints(from text: String) -> [String] {
        let normalized = InterviewKnowledgeMatcher.normalize(text)
        let tokens = normalized.split(separator: " ").map(String.init)
        let filtered = tokens.filter { $0.count >= 4 }
        return Array(Set(filtered)).sorted().prefix(8).map { $0 }
    }

    private func buildVaultContext(
        from matches: [InterviewKnowledgeMatch],
        maxEntries: Int = 3,
        questionLimit: Int = 220,
        answerLimit: Int = 420,
        header: String = "[INTERVIEW VAULT MATCHES]"
    ) -> String {
        guard !matches.isEmpty else { return "" }

        let maxCharacters = 2_600
        var usedCharacters = 0
        var lines: [String] = [header]

        for (index, match) in matches.prefix(maxEntries).enumerated() {
            let entry = """
            [\(index + 1)] Category: \(match.record.category) | Score: \(String(format: "%.2f", match.score))
            Q: \(compactVaultText(match.record.question, limit: questionLimit))
            A: \(compactVaultText(match.record.answer, limit: answerLimit))
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

    private func canUseDirectVaultFastPath(
        queryTokenCount: Int,
        topMatch: InterviewKnowledgeMatch,
        secondBestScore: Double
    ) -> Bool {
        let isShortQuery = queryTokenCount <= 3
        let scoreThreshold = isShortQuery ? 0.72 : 0.64
        let separationThreshold = isShortQuery ? 0.12 : 0.07
        guard topMatch.score >= scoreThreshold else { return false }
        guard (topMatch.score - secondBestScore) >= separationThreshold else { return false }
        if isShortQuery && topMatch.matchedTokenCount == 0 {
            return false
        }
        return true
    }

    private func adjustedVaultMatchScore(
        _ match: InterviewKnowledgeMatch,
        queryLanguageCode: String?
    ) -> Double {
        var adjusted = match.score
        if match.record.category.hasPrefix("Interview Notes") {
            adjusted += 0.12
        } else if match.record.category.hasPrefix("Interview Vault >") {
            adjusted += 0.04
        }
        guard let queryLanguageCode else { return min(adjusted, 1.0) }
        let shortQueryCode = String(queryLanguageCode.prefix(2))
        guard !shortQueryCode.isEmpty else { return min(adjusted, 1.0) }

        if let questionLanguageCode = InterviewKnowledgeMatcher.dominantLanguageCode(for: match.record.question),
           String(questionLanguageCode.prefix(2)) != shortQueryCode {
            adjusted *= 0.78
        }

        if let answerLanguageCode = InterviewKnowledgeMatcher.dominantLanguageCode(for: match.record.answer),
           String(answerLanguageCode.prefix(2)) != shortQueryCode {
            adjusted *= 0.86
        }

        return min(adjusted, 1.0)
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

    private func shouldPolishForReadability(
        _ text: String,
        responseProfile: ResponseProfile,
        structuredOutputRequested: Bool
    ) -> Bool {
        guard !structuredOutputRequested, responseProfile != .detailedTable else { return false }
        guard !text.contains("```"), !text.contains("|") else { return false }
        guard !text.contains("\n\n") else { return false }

        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let sentenceSeparators = CharacterSet(charactersIn: ".!?")
        let sentenceCount = text
            .components(separatedBy: sentenceSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count

        return wordCount >= 36 && sentenceCount >= 3 && !text.contains("\n")
    }

    private func sanitizeCitationArtifacts(in text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: #"\[\^\d+\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\[\d+(?:,\s*\d+)*\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned
    }
}
