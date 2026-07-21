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
    struct ProcessedResponse: Sendable {
        let text: String
        let origin: ResponseOrigin
    }

    enum ResponseOrigin: Sendable {
        case instantCache
        case storedCache
        case groundedFastPath
        case model

        var allowsAIRefinement: Bool {
            switch self {
            case .instantCache, .storedCache, .groundedFastPath:
                return true
            case .model:
                return false
            }
        }
    }

    enum ProcessingMode: Sendable {
        case automatic
        case forceAIReasoning
    }

    private let ollamaService: OllamaService
    private let tavilyService: TavilyService
    private let cacheService: ResponseCacheService
    private let semanticRetriever: SemanticRetriever?
    private let chatHistoryService: ChatHistoryService?
    private let systemStatusService: SystemStatusService?
    private let logger = Logger.intelligence
    
    private var conversationHistory: [OllamaService.ChatMessage] = []
    private let maxHistoryLimit = 15 // Keep last 15 messages for context
    private let conciseHistoryLimit = 8
    private var transientPersonaContext: String = ""
    private var cachedActiveRoleDescription: String = ""
    private var cachedActiveRoleProfile: ActiveRoleProfile?
    private var lastFollowUpContext: FollowUpContext?
    private var cachedInterviewKnowledgeIndex: InterviewKnowledgeIndex?
    
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

    nonisolated private static let codingVaultCategoryTokens: [String] = [
        "kodlama", "coding", "code", "algoritma", "algorithm", "debug", "bug",
        "technical", "teknik", "system design", "architecture", "leetcode"
    ]

    private struct MultiQuestionResolution {
        let directAnswer: String?
        let promptContext: String
    }

    private struct FollowUpContext {
        let previousQuestion: String
        let previousAnswer: String
        let groundedQuestion: String
        let groundedAnswer: String
        let activeRoleContext: String
        let languageCode: String?
    }

    private struct InterviewKnowledgeIndex {
        let signature: String
        let allRecords: [InterviewKnowledgeRecord]
        let codingRecords: [InterviewKnowledgeRecord]
    }
    
    func clearHistory() {
        conversationHistory.removeAll()
        lastFollowUpContext = nil
        logger.info("🗑️ Conversation history cleared in IntelligenceService")
    }
    
    func setTransientPersonaContext(_ context: String) {
        transientPersonaContext = context
    }
    
    func clearTransientPersonaContext() {
        transientPersonaContext = ""
    }

    private func currentActiveRoleProfile() -> ActiveRoleProfile? {
        let currentDescription = UserDefaults.standard.string(forKey: ActiveRoleProfileService.userDefaultsKey) ?? ""
        if currentDescription != cachedActiveRoleDescription {
            cachedActiveRoleDescription = currentDescription
            cachedActiveRoleProfile = ActiveRoleProfileService.profile(from: currentDescription)
        }
        return cachedActiveRoleProfile
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
        processingMode: ProcessingMode = .automatic,
        detectedLanguage: String? = nil,
        onStatusUpdate: @escaping (String) -> Void,
        onPartialResponse: @escaping (String) -> Void
    ) async throws -> ProcessedResponse {
        let lowerQuery = query.lowercased()
        let responseProfile = responseProfile(for: lowerQuery)
        let forceAIReasoning = processingMode == .forceAIReasoning
        var finalLanguageCode = Self.supportedResponseLanguageCode(
            for: query,
            providedLanguageCode: detectedLanguage
        )
        let followUpContext = imageData == nil ? followUpContextIfNeeded(for: query) : nil
        let isFollowUpQuery = followUpContext != nil
        let followUpAwareQuery = followUpContext.map {
            Self.followUpRetrievalQuery(
                currentQuery: query,
                previousQuestion: $0.groundedQuestion.isEmpty ? $0.previousQuestion : $0.groundedQuestion,
                previousAnswer: $0.groundedAnswer.isEmpty ? $0.previousAnswer : $0.groundedAnswer
            )
        } ?? query
        let normalizedQueryTokenCount = InterviewKnowledgeMatcher
            .normalize(query)
            .split(separator: " ")
            .count
        let normalizedQueryForIntent = InterviewKnowledgeMatcher.normalize(query)
        let compensationIntent = isCompensationIntent(normalizedQueryForIntent)
        let selfIntroIntent = isSelfIntroIntent(normalizedQueryForIntent)
        let isCodingQuery = imageData == nil && Self.isCodingRelatedQuery(normalizedQueryForIntent)
        let isSelfContainedCodingQuery = imageData == nil && Self.isSelfContainedCodingDebugQuery(query)
        let activeRoleProfile = currentActiveRoleProfile()
        let activeRoleGroundingContext = isSelfContainedCodingQuery ? "" : (activeRoleProfile.map {
            ActiveRoleProfileService.groundingContext(
                for: followUpAwareQuery,
                profile: $0,
                maxResults: isCodingQuery ? 4 : 3
            )
        } ?? "")
        let strongestRoleScore = isSelfContainedCodingQuery ? 0 : (activeRoleProfile.map {
            ActiveRoleProfileService.strongestMatchScore(for: followUpAwareQuery, profile: $0)
        } ?? 0)
        let followUpGroundingContext = followUpContext.map {
            buildFollowUpGroundingContext(for: query, context: $0)
        } ?? ""
        let questionSegments = Self.splitQuestionSegments(query)
        let isMultiQuestionQuery = questionSegments.count >= 2
        let activeHistoryLimit = responseProfile == .interviewConcise ? conciseHistoryLimit : maxHistoryLimit

        let searchDecision: SearchDecision
        if imageData != nil {
            searchDecision = .notNeeded
        } else {
            switch webSearchMode {
            case .automatic:
                searchDecision = searchDecisionForQuery(query)
            case .forceOn:
                if Self.shouldSuppressAutomaticWebSearch(for: query) {
                    logger.info("Forced web search suppressed for self-contained coding/debugging question")
                    searchDecision = .notNeeded
                } else {
                    searchDecision = .required
                }
            }
        }

        if !forceAIReasoning,
           imageData == nil,
           Self.canUseInstantInterviewCache(
            isInterviewConcise: responseProfile == .interviewConcise,
            requiresWebSearch: searchDecision == .required,
            isCodingQuery: isCodingQuery,
            isFollowUpQuery: isFollowUpQuery,
            strongestRoleScore: strongestRoleScore,
            cacheIsWarm: cacheService.isWarmupComplete()
           ),
           let quickAnswer = cacheService.getResponse(for: query) {
            let localizedQuickAnswer = await localizedDirectVaultAnswer(
                quickAnswer,
                queryLanguageCode: finalLanguageCode
            )
            logger.info("Instant interview cache reply used")
            let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
            let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: localizedQuickAnswer, images: nil)
            appendConversationTurn(userMessage, assistantMessage, limit: activeHistoryLimit)
            updateFollowUpContext(
                query: query,
                answer: localizedQuickAnswer,
                interviewMatches: [],
                activeRoleGroundingContext: activeRoleGroundingContext,
                languageCode: finalLanguageCode
            )
            await MainActor.run {
                onStatusUpdate("Ready (Cache)")
                onPartialResponse(localizedQuickAnswer)
            }
            return ProcessedResponse(text: localizedQuickAnswer, origin: .instantCache)
        }

        var interviewMatches: [InterviewKnowledgeMatch] = []
        var interviewFallbackAnchors: [InterviewKnowledgeMatch] = []
        var multiQuestionPromptContext = ""
        if imageData == nil && !isSelfContainedCodingQuery {
            await MainActor.run { onStatusUpdate("Checking interview notes + vault...") }
            let vaultResultLimit: Int = {
                if responseProfile == .interviewConcise {
                    return normalizedQueryTokenCount <= 5 ? 2 : 3
                }
                return 5
            }()
            interviewMatches = await retrieveInterviewMatches(
                for: followUpAwareQuery,
                maxResults: vaultResultLimit,
                minimumScore: 0.16,
                codingOnly: isCodingQuery
            )
            finalLanguageCode = resolvedInterviewLanguageCode(
                currentLanguageCode: finalLanguageCode,
                topMatch: interviewMatches.first
            )

            let strongestPrimaryScore = interviewMatches.first?.score ?? 0
            if responseProfile == .interviewConcise && !isCodingQuery {
                if strongestPrimaryScore < 0.28 {
                    let fallbackCandidates = await retrieveInterviewMatches(
                        for: followUpAwareQuery,
                        maxResults: normalizedQueryTokenCount <= 5 ? 2 : 3,
                        minimumScore: 0.14,
                        codingOnly: false
                    )
                    interviewFallbackAnchors = filteredFallbackAnchors(
                        primary: interviewMatches,
                        fallback: fallbackCandidates,
                        maxEntries: 2
                    )
                }

                if isMultiQuestionQuery {
                    let resolution = await resolveMultiQuestionQuery(
                        segments: questionSegments,
                        expectedLanguageCode: finalLanguageCode
                    )
                    multiQuestionPromptContext = resolution.promptContext

                    if !forceAIReasoning, searchDecision != .required, let direct = resolution.directAnswer {
                        let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
                        let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: direct, images: nil)
                        appendConversationTurn(userMessage, assistantMessage, limit: activeHistoryLimit)
                        await MainActor.run {
                            onStatusUpdate("Ready (Interview x\(questionSegments.count))")
                            onPartialResponse(direct)
                        }
                        return ProcessedResponse(text: direct, origin: .groundedFastPath)
                    }
                }
            }
        }
        let strongestInterviewScore = interviewMatches.first?.score ?? 0
        let shouldPreferInterviewKnowledgeOverCache =
            isCodingQuery ||
            isMultiQuestionQuery ||
            isFollowUpQuery ||
            strongestRoleScore >= 0.26 ||
            strongestInterviewScore >= 0.34 ||
            (compensationIntent && strongestInterviewScore >= 0.20) ||
            (selfIntroIntent && strongestInterviewScore >= 0.28)
        let interviewGroundingContext = buildInterviewGroundingContext(
            primaryMatches: interviewMatches,
            fallbackMatches: interviewFallbackAnchors,
            profile: responseProfile
        )

        let bypassCache = forceAIReasoning || shouldBypassCache(for: searchDecision)
        
        // 0. CACHE CHECK
        if !bypassCache, !shouldPreferInterviewKnowledgeOverCache, let cachedAnswer = cacheService.getResponse(for: query) {
            logger.info("Cache HIT for query: \(self.sanitize(query))")
            let localizedCachedAnswer = await localizedDirectVaultAnswer(
                cachedAnswer,
                queryLanguageCode: finalLanguageCode
            )
            await MainActor.run {
                onStatusUpdate("Ready")
                onPartialResponse(localizedCachedAnswer)
            }
            return ProcessedResponse(text: localizedCachedAnswer, origin: .storedCache)
        } else if bypassCache {
            if forceAIReasoning {
                logger.info("Cache bypassed due to forced AI reasoning")
            } else {
                let modeLabel = webSearchMode == .forceOn ? "forceOn" : "automatic"
                logger.info("Cache bypassed due to required web search (\(modeLabel, privacy: .public))")
            }
        } else if shouldPreferInterviewKnowledgeOverCache {
            if isSelfContainedCodingQuery {
                logger.info("Cache bypassed due to self-contained coding query")
            } else if isCodingQuery {
                logger.info("Cache bypassed due to coding query path")
            } else {
                logger.info("Cache bypassed due to interview notes/vault priority")
            }
        }

        // Variant-aware direct interview answer for low-latency interview flow.
        if !forceAIReasoning,
           imageData == nil,
           !isFollowUpQuery,
           searchDecision != .required,
           responseProfile == .interviewConcise,
           let topInterviewMatch = interviewMatches.first {
            let secondInterviewScore = interviewMatches.dropFirst().first?.score ?? 0
            let directInterviewAnswer = topInterviewMatch.record.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTopQuestion = InterviewKnowledgeMatcher.normalize(topInterviewMatch.record.question)
            let queryConcepts = InterviewKnowledgeMatcher.canonicalKeywords(from: followUpAwareQuery)
            let topRecordConcepts = InterviewKnowledgeMatcher.canonicalKeywords(
                from: [
                    topInterviewMatch.record.question,
                    topInterviewMatch.record.answer,
                    topInterviewMatch.record.keyPoints.joined(separator: " ")
                ].joined(separator: " ")
            )
            let hasDirectConceptCoverage = Self.hasRequiredInterviewConceptCoverage(
                queryConcepts: queryConcepts,
                recordConcepts: topRecordConcepts
            )
            let isExactQuestionMatch = normalizedTopQuestion == normalizedQueryForIntent
            let isStrongLexicalMatch =
                topInterviewMatch.score >= 0.34 &&
                topInterviewMatch.matchedTokenCount >= max(2, min(4, normalizedQueryTokenCount))
            let introIntentFastPath =
                selfIntroIntent &&
                topInterviewMatch.score >= 0.36 &&
                topInterviewMatch.matchedTokenCount >= 1
            let compensationIntentFastPath =
                compensationIntent &&
                isCompensationRecord(topInterviewMatch.record) &&
                topInterviewMatch.score >= 0.20
            let generalInterviewFastPath =
                topInterviewMatch.score >= 0.46 &&
                topInterviewMatch.matchedTokenCount >= 1 &&
                (topInterviewMatch.score - secondInterviewScore) >= 0.02
            let codingInterviewFastPath =
                isCodingQuery &&
                topInterviewMatch.score >= 0.62 &&
                topInterviewMatch.matchedTokenCount >= max(1, min(3, normalizedQueryTokenCount)) &&
                (topInterviewMatch.score - secondInterviewScore) >= 0.08

            if !directInterviewAnswer.isEmpty,
               hasDirectConceptCoverage,
               (
                codingInterviewFastPath ||
                (
                    !isCodingQuery &&
                    (
                        isExactQuestionMatch ||
                        isStrongLexicalMatch ||
                        canUseDirectVaultFastPath(
                            queryTokenCount: normalizedQueryTokenCount,
                            topMatch: topInterviewMatch,
                            secondBestScore: secondInterviewScore
                        ) ||
                        introIntentFastPath ||
                        compensationIntentFastPath ||
                        generalInterviewFastPath
                    )
                )
               ) {
                let localizedDirectAnswer = await localizedDirectVaultAnswer(
                    directInterviewAnswer,
                    queryLanguageCode: finalLanguageCode
                )
                logger.info("Direct interview-knowledge reply used (score: \(topInterviewMatch.score, privacy: .public))")
                let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: nil)
                let assistantMessage = OllamaService.ChatMessage(role: "assistant", content: localizedDirectAnswer, images: nil)
                appendConversationTurn(userMessage, assistantMessage, limit: activeHistoryLimit)
                updateFollowUpContext(
                    query: query,
                    answer: localizedDirectAnswer,
                    interviewMatches: interviewMatches,
                    activeRoleGroundingContext: activeRoleGroundingContext,
                    languageCode: finalLanguageCode
                )
                await MainActor.run {
                    onStatusUpdate("Ready (Interview)")
                    onPartialResponse(localizedDirectAnswer)
                }
                return ProcessedResponse(text: localizedDirectAnswer, origin: .groundedFastPath)
            }
        }
        
        await MainActor.run { onStatusUpdate("Thinking...") }
        
        // 0.4 GATHER SYSTEM CONTEXT
        let systemContext = await systemStatusService?.getSystemContextSummary() ?? ""
        
        // 0.5 RAG RETRIEVAL (if enabled)
        var ragContext = ""
        
        let shouldSkipRAGForInterview =
            responseProfile == .interviewConcise &&
            imageData == nil &&
            !interviewGroundingContext.isEmpty &&
            searchDecision != .required &&
            !isFollowUpQuery

        if shouldSkipRAGForInterview {
            logger.info("Skipping RAG retrieval due to interview-grounded fast path")
        }

        if !isCodingQuery, !shouldSkipRAGForInterview, let retriever = semanticRetriever {
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
                // Interview latency path: optional web gate should not add an extra LLM roundtrip.
                if responseProfile == .interviewConcise {
                    shouldSearchWeb = false
                } else {
                    shouldSearchWeb = (try? await decideWebSearchUsingLLMGate(query: query)) ?? false
                }
            case .notNeeded:
                shouldSearchWeb = false
            }
            
            if shouldSearchWeb {
                webSearchAttempted = true
                do {
                    await MainActor.run { onStatusUpdate("Searching web...") }
                    let searchDetailLevel: TavilyService.DetailLevel =
                        responseProfile == .interviewConcise ? .brief : .detailed
                    let preparedWebQuery = TavilyService.preferredQuery(from: query)
                    searchContext = try await tavilyService.search(query: preparedWebQuery, detailLevel: searchDetailLevel)
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
            appendConversationTurn(userMessage, assistantMessage, limit: activeHistoryLimit)
            await MainActor.run {
                onPartialResponse(fallback)
                onStatusUpdate("Web unavailable")
            }
            return ProcessedResponse(text: fallback, origin: .model)
        }
        
        // 2. CONSTRUCT SYSTEM PROMPT
        let rolePrompt: String = (imageData != nil) ? 
            "senior software engineer identifying issues from a screen capture. CRITICAL: Identify language of text in image FIRST, then respond IN THAT LANGUAGE." : 
            (isSelfContainedCodingQuery
             ? "senior software engineer debugging and fixing production code quickly and clearly"
             : (isCodingQuery
             ? "senior software engineer solving a coding problem quickly and clearly"
             : "senior software engineer assistant in a live interview/meeting")
            )
            
        let storedPersona = UserDefaults.standard.string(forKey: "userPersonaContext") ?? ""
        let persistentPersona = storedPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionPersona = transientPersonaContext.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let mergedPersonaRaw: String
        if !persistentPersona.isEmpty && !sessionPersona.isEmpty {
            mergedPersonaRaw = """
            \(persistentPersona)
            
            [SESSION INTERVIEW CONTEXT]
            \(sessionPersona)
            """
        } else if !persistentPersona.isEmpty {
            mergedPersonaRaw = persistentPersona
        } else if !sessionPersona.isEmpty {
            mergedPersonaRaw = sessionPersona
        } else {
            mergedPersonaRaw = "No specific persona defined. Act as a helpful AI assistant."
        }
        let mergedPersona = compactContextText(
            mergedPersonaRaw,
            maxCharacters: responseProfile == .interviewConcise ? 1_400 : 2_100
        )
        var languageInstruction = "Respond in the EXACT SAME LANGUAGE as the question."

        if let langCode = finalLanguageCode {
            switch langCode {
            case "en", "english": languageInstruction = "The user is asking in ENGLISH. Respond ONLY in ENGLISH."
            case "fi", "finnish": languageInstruction = "The user is asking in FINNISH. CRITICAL: Use 'Professional Puheenkieli'."
            case "tr", "turkish": languageInstruction = "The user is asking in TURKISH. Respond ONLY in TURKISH."
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
        let codingInstruction = isCodingQuery
            ? """
            - This is a coding-focused request. Answer the coding question directly without overthinking aloud.
            - If [INTERVIEW GROUNDING] contains coding-vault guidance relevant to the question, use that first.
            - If [ACTIVE ROLE GROUNDING] contains stack requirements relevant to the question, keep the solution compatible with that stack.
            - Prefer the concrete solution first. If code is useful, provide it immediately.
            - Keep explanations short and practical.
            - When you write code, include only brief, useful inline comments.
            - Ignore unrelated non-coding interview context.
            \(Self.requiresCorrectedCodeResponse(query) ? "- The user pasted concrete code and asked what is wrong/how to fix it. First list the main issues in 2-4 short bullets, then provide a corrected code block, then end with 1-2 short sentences explaining why the fix is safer." : "")
            """
            : ""
        let interviewPriorityHint = strongestInterviewScore >= 0.30
            ? "Strong interview grounding detected (score: \(String(format: "%.2f", strongestInterviewScore))). Stay anchored to [INTERVIEW GROUNDING]."
            : "Interview grounding is weak. Prefer [USER PERSONA], then memory/web, and keep uncertainty explicit."
        let rolePriorityHint: String = {
            guard activeRoleProfile != nil else {
                return "No active role grounding loaded."
            }
            if strongestRoleScore >= 0.24 {
                return "Strong active-role grounding detected (score: \(String(format: "%.2f", strongestRoleScore))). Use [ACTIVE ROLE GROUNDING] for company, stack, and expectation-specific questions."
            }
            return "Active role is loaded. Use [ACTIVE ROLE GROUNDING] whenever the question references the current company, role, stack, or project expectations."
        }()
        let includeRAGContext = !isCodingQuery && (responseProfile != .interviewConcise || max(strongestInterviewScore, strongestRoleScore) < 0.30)
        let ragContextBlock = includeRAGContext ? ragContext : ""
        let searchContextBlock = searchContext.isEmpty ? "" : "CONTEXT FROM SEARCH:\n\(searchContext)\n"
        let automationContext = allowAgentActions ? AutomationLibrary.getPromptContext() : ""
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
        let contextualBlocks = [
            followUpGroundingContext,
            interviewGroundingContext,
            activeRoleGroundingContext,
            multiQuestionPromptContext,
            ragContextBlock,
            searchContextBlock,
            webSearchStatusHint.isEmpty ? "" : "\(webSearchStatusHint)\n",
            systemContext.isEmpty ? "" : "SYSTEM CONTEXT:\n\(systemContext)\n"
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        
        let systemPrompt = """
        [IDENTITY & ROLE]
        You are a \(rolePrompt). 
        Default voice: clear, interview-ready spoken sentences.
        
        [USER PERSONA]:
        \(mergedPersona)
        
        [INSTRUCTIONS]
        1. KNOWLEDGE PRIORITY:
           - If [FOLLOW-UP CONTEXT] is present, treat the current question as a continuation of the previous topic.
           - First: [INTERVIEW GROUNDING] (includes Interview Notes + Interview Vault)
           - Second: [ACTIVE ROLE GROUNDING]
           - Third: [USER PERSONA]
           - Fourth: [RETRIEVED FROM MEMORY]
           - Fifth: CONTEXT FROM SEARCH
           - Sixth: General reasoning fallback
           - \(interviewPriorityHint)
           - \(rolePriorityHint)
           - If query is unclear/noise, ask one short clarification question instead of guessing.
        2. CONTEXTUAL INTELLIGENCE:
           \(contextualBlocks)
        
        3. LANGUAGE LOCK: \(languageInstruction)
           Never switch language mid-answer. Never mix unrelated languages.
           If user writes informally, keep professional spoken tone.
        
        4. RESPONSE STYLE:
           \(responseStyleInstruction)
           \(codingInstruction)
           - Write in natural spoken language for read-aloud (not robotic, no slang overload).
           - Understand the exact question before answering; avoid irrelevant detours.
           - For short interview prompts, use only the single strongest interview match; do not merge unrelated topics.
           - If [FOLLOW-UP CONTEXT] is present and the user asks for more detail, stay consistent with the previous answer.
           - If there is no exact stored answer for a follow-up, expand conservatively from the previous answer, active role, and persona without contradicting known facts.
           - If user asks multiple questions in one message, answer each question in the same order in separate short paragraphs.
           - If any segment is marked [Qx FALLBACK REQUIRED], answer that segment from [ACTIVE ROLE GROUNDING] and [USER PERSONA] instead of forcing weak vault anchors.
           - Do not mention private contact details or salary unless explicitly asked.
           - Avoid markdown/list/table unless explicitly requested by the user.
        
        5. FACTUAL SAFETY:
           - Do not invent facts, names, or metrics.
           - Do not invent benchmark scores or release details. If unverified, say that clearly.
           - Never output fake citation markers like [1], [2], [^1].
           - If fresh verification is required and web search is unavailable, clearly say verification is unavailable now and do not guess.
           - If uncertain, say so briefly and give the safest answer.
        
        \(actionPolicy)
        
        \(automationContext)
        """
        
        // 3. CONSTRUCT MESSAGE ARRAY
        var messages: [OllamaService.ChatMessage] = []
        
        // A. Add System Prompt
        messages.append(OllamaService.ChatMessage(role: "system", content: systemPrompt, images: nil))
        
        // B. Add Curated History (only last N to prevent bloat)
        let contextHistory = conversationHistory.suffix(activeHistoryLimit)
        messages.append(contentsOf: contextHistory)
        
        // C. Add Current Query
        var requestUserContent = Self.modelFacingQuery(
            originalQuery: query,
            expectedLanguageCode: finalLanguageCode,
            isSelfContainedCodingQuery: isSelfContainedCodingQuery
        )
        if isMultiQuestionQuery && !isSelfContainedCodingQuery {
            requestUserContent = Self.multiQuestionModelFacingQuery(
                baseQuery: requestUserContent,
                segments: questionSegments,
                expectedLanguageCode: finalLanguageCode
            )
        }
        var chatImages: [String]? = nil
        if let data = imageData {
             chatImages = [data.base64EncodedString()]
        }
        let userMessage = OllamaService.ChatMessage(role: "user", content: query, images: chatImages)
        let requestUserMessage = OllamaService.ChatMessage(role: "user", content: requestUserContent, images: chatImages)
        messages.append(requestUserMessage)
        
        // 4. MODEL EXECUTION (streaming by default, single-shot when answer is already grounded)
        var model = (imageData != nil) ? AIModelNames.vision : AIModelNames.reasoning
        let isSlashCommand = query.starts(with: "/")
        let isSystemCommand = query.count < 30 && ["mute", "unmute", "volume", "trash", "empty", "pause", "play", "stop"].contains { lowerQuery.contains($0) }
        let structuredOutputRequested = isStructuredOutputRequested(lowerQuery) || responseProfile == .detailedTable
        let shouldUseActionFastPath = allowAgentActions && (isSlashCommand || isSystemCommand)
        let strongestInterviewGroundingScore = interviewMatches.first?.score ?? 0
        let shouldUseFastInterviewFallback =
            imageData == nil &&
            responseProfile == .interviewConcise &&
            !isCodingQuery &&
            !isFollowUpQuery &&
            !shouldUseActionFastPath &&
            searchDecision != .required
        let shouldUseSingleShotInterviewReply =
            shouldSkipRAGForInterview &&
            !shouldUseActionFastPath &&
            strongestInterviewGroundingScore >= 0.16

        if shouldUseFastInterviewFallback {
            model = AIModelNames.fast
        }
        
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

            if shouldUseSingleShotInterviewReply {
                logger.info("Using single-shot interview-grounded reply path (score: \(strongestInterviewGroundingScore, privacy: .public))")
                fullAnswer = try await ollamaService.generate(messages: messages, model: model)
            } else {
                try await ollamaService.generateStreaming(messages: messages, model: model) { partialAnswer in
                    fullAnswer = partialAnswer
                    onPartialResponse(partialAnswer)
                }
            }
            
            var finalizedAnswer = await enforceOutputContractIfNeeded(
                answer: fullAnswer,
                query: query,
                expectedLanguageCode: finalLanguageCode,
                structuredOutputRequested: structuredOutputRequested,
                responseProfile: responseProfile,
                skipPostProcessing: imageData != nil || shouldUseActionFastPath,
                allowAgentActions: allowAgentActions
            )
            
            // Coding Sandbox Auto-Compiler Correction Loop
            var swiftBlocks = self.extractSwiftCodeBlocks(from: finalizedAnswer)
            var hasVerifiedBadge = false
            
            if !swiftBlocks.isEmpty {
                var attempts = 0
                while attempts < 2 {
                    var allCompiled = true
                    var compileErrors = ""
                    
                    for block in swiftBlocks {
                        let res = CodingSandboxService.shared.verifySwiftCode(block)
                        if !res.success {
                            allCompiled = false
                            compileErrors += "Errors in Swift code block:\n\(res.diagnostics)\n\n"
                        }
                    }
                    
                    if allCompiled {
                        hasVerifiedBadge = true
                        break
                    }
                    
                    attempts += 1
                    logger.info("Swift sandbox compilation failed. Running correction loop attempt \(attempts)...")
                    
                    let correctionPrompt = """
                    The generated Swift code block has compilation errors. Please fix the compiler errors and output the corrected response containing the updated ```swift block.
                    
                    Compiler Errors:
                    \(compileErrors)
                    
                    Original Response:
                    \(finalizedAnswer)
                    """
                    
                    do {
                        let correctionMessages = messages + [
                            OllamaService.ChatMessage(role: "assistant", content: finalizedAnswer, images: nil),
                            OllamaService.ChatMessage(role: "user", content: correctionPrompt, images: nil)
                        ]
                        let correctedResponse = try await ollamaService.generate(messages: correctionMessages, model: model)
                        finalizedAnswer = correctedResponse
                        swiftBlocks = self.extractSwiftCodeBlocks(from: finalizedAnswer)
                    } catch {
                        logger.error("Correction loop failed: \(error.localizedDescription)")
                        break
                    }
                }
                
                if hasVerifiedBadge {
                    finalizedAnswer += "\n\n> 🛡️ **[Compile Verified in local Swift sandbox]**"
                }
            }
            
            // 5. UPDATE INTERNAL HISTORY
            appendConversationTurn(
                userMessage,
                OllamaService.ChatMessage(role: "assistant", content: finalizedAnswer, images: nil),
                limit: activeHistoryLimit
            )
            updateFollowUpContext(
                query: query,
                answer: finalizedAnswer,
                interviewMatches: interviewMatches,
                activeRoleGroundingContext: activeRoleGroundingContext,
                languageCode: finalLanguageCode
            )
            
            return await MainActor.run {
                onPartialResponse(finalizedAnswer)
                onStatusUpdate("Ready")
                return ProcessedResponse(text: finalizedAnswer, origin: .model)
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

    private func appendConversationTurn(
        _ userMessage: OllamaService.ChatMessage,
        _ assistantMessage: OllamaService.ChatMessage,
        limit: Int
    ) {
        conversationHistory.append(userMessage)
        conversationHistory.append(assistantMessage)
        trimConversationHistory(limit: limit)
    }

    private func trimConversationHistory(limit: Int) {
        let maxItems = max(2, limit * 2)
        guard conversationHistory.count > maxItems else { return }
        let overflowCount = conversationHistory.count - maxItems
        conversationHistory.removeFirst(overflowCount)
    }
    
    private func shouldBypassCache(for decision: SearchDecision) -> Bool {
        decision == .required
    }
    
    private func searchDecisionForQuery(_ query: String) -> SearchDecision {
        let normalized = query.lowercased()

        // Self-contained coding/debugging questions should stay local unless the user explicitly asks for web/docs/current info.
        if Self.shouldSuppressAutomaticWebSearch(for: query) {
            return .notNeeded
        }
        
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
            "library", "framework", "which one", "trend",
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

    nonisolated static func preferredLanguageCode(
        for query: String,
        providedLanguageCode: String? = nil
    ) -> String? {
        if let providedLanguageCode {
            let normalizedProvidedLanguage = providedLanguageCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !normalizedProvidedLanguage.isEmpty {
                return normalizedProvidedLanguage
            }
        }

        let probeText = languageDetectionProbeText(from: query)
        return InterviewKnowledgeMatcher.dominantLanguageCode(for: probeText)?.lowercased()
    }

    nonisolated static func languageDetectionProbeText(from query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var candidates: [String] = [trimmed]
        let preprocessed = trimmed
            .replacingOccurrences(of: "```", with: "\n")
            .replacingOccurrences(of: "=>", with: "\n")
            .replacingOccurrences(of: "{", with: "\n")
            .replacingOccurrences(of: "}", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")

        let lineFragments = preprocessed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        candidates.append(contentsOf: lineFragments)

        let sentenceFragments = preprocessed
            .components(separatedBy: CharacterSet(charactersIn: "?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        candidates.append(contentsOf: sentenceFragments)

        let normalizedStarters = [
            "mika", "mikä", "mita", "mitä", "miksi", "miten", "kuka", "millainen",
            "milloin", "onko", "voitko", "voisitko", "haluatko", "puhu",
            "why", "what", "how", "when", "who", "which",
            "neden", "nasıl", "nasil", "hangi", "kim", "ne zaman"
        ]

        let bestCandidate = candidates
            .map { candidate -> (text: String, score: Double) in
                let score = naturalLanguageCandidateScore(
                    candidate,
                    normalizedStarters: normalizedStarters
                )
                return (candidate, score)
            }
            .filter { $0.score > 0 }
            .max { lhs, rhs in lhs.score < rhs.score }

        return bestCandidate?.text ?? trimmed
    }

    nonisolated private static func naturalLanguageCandidateScore(
        _ text: String,
        normalizedStarters: [String]
    ) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return 0 }

        let normalized = InterviewKnowledgeMatcher.normalize(trimmed)
        guard !normalized.isEmpty else { return 0 }

        let letters = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        let symbols = trimmed.unicodeScalars.filter {
            !CharacterSet.letters.contains($0) &&
            !CharacterSet.decimalDigits.contains($0) &&
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.count
        let tokenCount = normalized.split(separator: " ").count
        guard letters >= 3, tokenCount >= 2 else { return 0 }

        let letterRatio = Double(letters) / Double(max(trimmed.count, 1))
        let symbolRatio = Double(symbols) / Double(max(trimmed.count, 1))
        var score = (letterRatio * 2.2) - (symbolRatio * 0.9)

        if trimmed.contains("?") {
            score += 0.8
        }
        if normalizedStarters.contains(where: { normalized.hasPrefix($0 + " ") || normalized == $0 }) {
            score += 1.6
        }
        if trimmed.range(of: #"[äöüğıçşÄÖÜĞIİÇŞ]"#, options: .regularExpression) != nil {
            score += 0.35
        }
        if looksCodeLikeForLanguageDetection(trimmed) {
            score -= 1.8
        }

        return score
    }

    nonisolated private static func looksCodeLikeForLanguageDetection(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let codeSignals = [
            "const ", "let ", "var ", "function ", "return ", "await ", "async ",
            "class ", "struct ", "interface ", "=>", "{", "}", "db.", "sql", "select ",
            "insert ", "update ", "delete ", "from ", "where ", "id =", "amount", "userid"
        ]
        let hitCount = codeSignals.reduce(into: 0) { count, signal in
            if normalized.contains(signal) {
                count += 1
            }
        }
        return hitCount >= 2
    }

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

    nonisolated private static func looksLikeQuestionClause(_ text: String) -> Bool {
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

    private static func ensureQuestionMark(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "?.! \n\t"))
        return trimmed.isEmpty ? text : trimmed + "?"
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
            "Answer each question in the same order (Q1, Q2, ...).",
            "Do not merge multiple questions into one generic answer.",
            "If a segment is marked [Qx FALLBACK REQUIRED], build that segment from [ACTIVE ROLE GROUNDING] and [USER PERSONA]."
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
                    minimumScore: 0.14
                )
            }
            if let topStrong {
                let extraAnchors = filteredFallbackAnchors(
                    primary: [topStrong],
                    fallback: anchorMatches,
                    maxEntries: 1
                )
                anchorMatches = [topStrong] + extraAnchors
            } else {
                anchorMatches = filteredFallbackAnchors(
                    primary: [],
                    fallback: anchorMatches,
                    maxEntries: 2
                )
            }

            let topStrongLanguageAligned = topStrong.map {
                canUseDirectVaultAnswer(
                    queryLanguageCode: expectedLanguageCode,
                    answer: $0.record.answer
                )
            } ?? false
            let fallbackRequired = Self.multiQuestionRequiresPersonaFallback(
                topScore: topStrong?.score,
                matchedTokenCount: topStrong?.matchedTokenCount ?? 0,
                queryTokenCount: tokenCount,
                isIntroIntent: segmentIntroIntent,
                isCompensationIntent: segmentCompensationIntent,
                languageAligned: topStrongLanguageAligned
            )
            if fallbackRequired {
                hasUnresolvedSegment = true
                contextParts.append("[Q\(index + 1) FALLBACK REQUIRED]")
                contextParts.append(
                    "No reliable direct vault answer for this segment. Build a concise answer from [ACTIVE ROLE GROUNDING] and [USER PERSONA], then keep it interview-ready."
                )
            }

            if let topStrong {
                let answer = topStrong.record.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                let canUseDirect = canUseDirectMultiQuestionMatch(
                    topMatch: topStrong,
                    queryTokenCount: tokenCount,
                    isIntroIntent: segmentIntroIntent,
                    isCompensationIntent: segmentCompensationIntent
                ) && topStrongLanguageAligned && !fallbackRequired
                if !answer.isEmpty && canUseDirect {
                    directAnswers.append(answer)
                } else {
                    hasUnresolvedSegment = true
                }
            } else {
                hasUnresolvedSegment = true
            }

            if !fallbackRequired {
                let reliableAnchors = anchorMatches.filter { match in
                    guard match.score >= 0.22 else { return false }
                    guard match.matchedTokenCount >= 1 else { return false }
                    return canUseDirectVaultAnswer(
                        queryLanguageCode: expectedLanguageCode,
                        answer: match.record.answer
                    )
                }
                let anchorContext = buildVaultContext(
                    from: reliableAnchors,
                    maxEntries: 2,
                    questionLimit: 120,
                    answerLimit: 190,
                    header: "[Q\(index + 1) ANCHORS]"
                )
                if !anchorContext.isEmpty {
                    contextParts.append(anchorContext)
                }
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

    nonisolated static func multiQuestionRequiresPersonaFallback(
        topScore: Double?,
        matchedTokenCount: Int,
        queryTokenCount: Int,
        isIntroIntent: Bool,
        isCompensationIntent: Bool,
        languageAligned: Bool
    ) -> Bool {
        guard let topScore else { return true }
        guard languageAligned else { return true }
        guard matchedTokenCount >= 1 else { return true }

        if isCompensationIntent {
            return topScore < 0.20
        }
        if isIntroIntent {
            return topScore < 0.30
        }

        let threshold = queryTokenCount <= 6 ? 0.24 : 0.28
        return topScore < threshold
    }

    private func mergeMultiQuestionAnswers(_ answers: [String], expectedLanguageCode: String?) -> String {
        guard answers.count > 1 else { return answers.first ?? "" }
        let code = expectedLanguageCode?.lowercased() ?? ""

        return answers.enumerated().map { index, answer in
            let label: String
            if code.hasPrefix("fi") {
                label = "Kysymys \(index + 1):"
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
        let gateQuery = TavilyService.preferredQuery(from: query, maxLength: 240)
        let searchDecisionPrompt = """
        Query: "\(gateQuery)"
        Decide if this question REQUIRES live web data for accuracy.
        If the query asks about release status, benchmark, leadership/person/title, or current events, answer YES.
        If this is a self-contained coding/debugging question or pasted code snippet that can be answered from provided context, answer NO.
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
        case "en", "english": return "English"
        case "fi", "finnish": return "Finnish"
        case "tr", "turkish": return "Turkish"
        default: return "the user's language"
        }
    }

    private func liveWebVerificationUnavailableMessage(languageCode: String?) -> String {
        let code = languageCode?.lowercased() ?? ""
        switch code {
        case "fi", "finnish":
            return "Tämä kysymys vaatii ajantasaisen verkkovarmistuksen, mutta verkkohaku epäonnistui juuri nyt. En halua arvata väärin, joten varmennettua vastausta ei voi antaa tällä hetkellä."
        case "tr", "turkish":
            return "Bu soru güncel bir web doğrulaması gerektiriyor, ancak şu anda web araması başarısız oldu. Yanlış bilgi vermemek adına şu anda doğrulanmış bir yanıt sunamıyorum."
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
            let fallback: String
            switch expectedLanguageCode?.lowercased() {
            case "fi", "finnish": fallback = "Olen valmis. Esitä kysymyksesi lyhyesti, niin vastaan selkeästi."
            case "tr", "turkish": fallback = "Hazırım. Sorun neyse sor, net cevap vereyim."
            default: fallback = "I'm ready. Ask your question concisely and I'll give a clear answer."
            }
            return allowAgentActions ? answer : fallback
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
        let isCodingQuery = Self.isCodingRelatedQuery(InterviewKnowledgeMatcher.normalize(query))
        let needsCorrectedCodePass =
            isCodingQuery &&
            Self.requiresCorrectedCodeResponse(query) &&
            !trimmed.contains("```")
        guard needsLanguageFix || needsCondense || needsExpansion || needsReadabilityPolish || needsCorrectedCodePass else { return trimmed }
        let shouldPreserveStreamingStability =
            responseProfile == .interviewConcise ||
            isCodingQuery
        if shouldPreserveStreamingStability && !needsLanguageFix && !needsCorrectedCodePass {
            return trimmed
        }
        
        // Latency guard: avoid second model call for short/acceptable answers.
        let shouldRewriteForLanguage = needsLanguageFix && (isCodingQuery || trimmed.count > 80)
        let shouldRewriteForLength = needsCondense && trimmed.count > 520
        let shouldRewriteForExpansion = needsExpansion && trimmed.count < 180
        let shouldRewriteForReadability = needsReadabilityPolish && trimmed.count > 170
        let shouldRewriteForCorrectedCode = needsCorrectedCodePass
        guard shouldRewriteForLanguage || shouldRewriteForLength || shouldRewriteForExpansion || shouldRewriteForReadability || shouldRewriteForCorrectedCode else {
            return trimmed
        }
        let expansionRule = shouldRewriteForExpansion
            ? "- Expand to 2-4 short sentences without adding new facts."
            : ""
        let readabilityRule = shouldRewriteForReadability
            ? "- If answer is a long block, split into short paragraphs with one blank line every 2 sentences."
            : ""
        
        let rewritePrompt: String
        if shouldRewriteForCorrectedCode {
            rewritePrompt = """
            USER QUESTION:
            \(query)

            CURRENT ANSWER:
            \(trimmed)

            Rewrite with strict rules:
            - Answer in \(languageName(for: expectedLanguageCode)).
            - Keep the diagnosis aligned with the current answer; do not invent unrelated issues.
            - Start with 2-4 short bullets naming the production risks.
            - Then provide a corrected code block using markdown fences.
            - End with 1-2 short sentences explaining why the corrected version is safer.
            - Keep inline comments brief and useful.

            Return only the improved answer.
            """
        } else if isCodingQuery && needsLanguageFix {
            rewritePrompt = """
            USER QUESTION:
            \(query)

            ORIGINAL ANSWER:
            \(trimmed)

            Rewrite with strict rules:
            - Keep EXACT technical meaning; do not add new facts.
            - Rewrite the explanatory prose only into \(languageName(for: expectedLanguageCode)).
            - Keep code, identifiers, SQL, API names, and stack names unchanged unless translating them would reduce clarity.
            - Preserve markdown and code fences if present.
            - Fix malformed wording, spelling, and grammar while preserving facts.

            Return only rewritten answer.
            """
        } else {
            rewritePrompt = """
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
        }
        
        let rewriteModel = shouldRewriteForCorrectedCode ? AIModelNames.coding : AIModelNames.fast
        guard let rewritten = try? await ollamaService.generate(
            messages: [OllamaService.ChatMessage(role: "user", content: rewritePrompt, images: nil)],
            model: rewriteModel
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
    
    private func extractSwiftCodeBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        let scanner = Scanner(string: text)
        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("```swift")
            guard scanner.scanString("```swift") != nil else { break }
            if let content = scanner.scanUpToString("```") {
                blocks.append(content)
            }
            _ = scanner.scanString("```")
        }
        return blocks
    }
    
    nonisolated static func isCodingRelatedQuery(_ normalizedQuery: String) -> Bool {
        let normalized = InterviewKnowledgeMatcher.normalize(normalizedQuery)
        guard !normalized.isEmpty else { return false }

        let debuggingSignals = [
            "bug", "debug", "fix", "compile", "syntax", "stack trace", "exception", "error", "crash",
            "refactor", "unit test", "integration test", "xcode", "swift", "swiftui", "regex",
            "sql", "docker", "kubernetes", "hata", "derleme", "birim testi", "test senaryosu",
            "duzelt", "düzelt", "cokuyor", "çöküyor"
        ]
        if debuggingSignals.contains(where: normalized.contains) {
            return true
        }

        let authoringVerbs = [
            "write", "implement", "create", "generate", "build", "show", "draft",
            "kirjoita", "yaz", "olustur", "oluştur", "uret", "üret", "goster", "göster",
            "implementoi", "tee", "example", "snippet", "ornek", "örnek"
        ]
        let strongImplementationTargets = [
            "authentication", "auth", "authorize", "authorization", "jwt", "session",
            "login", "signup", "oauth", "endpoint", "route", "handler", "middleware",
            "repository", "repo", "database", "schema", "function", "class", "struct",
            "interface", "algorithm", "sql", "regex"
        ]
        let frameworkTargets = [
            "react", "node", "next js", "nextjs", "nestjs", "express",
            "swift", "swiftui", "typescript", "javascript", "python", "java", "kotlin", "go", "rust",
            "docker", "kubernetes", "xcode"
        ]
        let generalCodingWords = [
            "code", "coding", "algorithm", "function", "class", "struct", "interface",
            "api", "backend", "frontend", "pull request", "commit", "diff",
            "kod", "kodlama", "fonksiyon", "sinif", "sınıf", "algoritma"
        ]

        let hasAuthoringVerb = authoringVerbs.contains(where: normalized.contains)
        let hasImplementationTarget = strongImplementationTargets.contains(where: normalized.contains)
        let hasFrameworkTarget = frameworkTargets.contains(where: normalized.contains)
        let hasGeneralCodingWord = generalCodingWords.contains(where: normalized.contains)

        if hasAuthoringVerb && (hasImplementationTarget || hasFrameworkTarget || hasGeneralCodingWord) {
            return true
        }

        let codeLikeTokens = [
            "```", "func ", "class ", "struct ", "interface ", "def ",
            "select ", "insert into ", "update ", "delete from ", "create table ",
            "public ", "private ", "return "
        ]
        if codeLikeTokens.contains(where: normalized.contains) {
            return true
        }

        let canonicalKeywords = InterviewKnowledgeMatcher.canonicalKeywords(from: normalized)
        let frameworkKeywords = [
            "frontend", "backend", "react", "api", "service", "test"
        ]
        if hasAuthoringVerb && frameworkKeywords.contains(where: canonicalKeywords.contains) {
            return true
        }

        return false
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

    nonisolated static func scopedVaultCategories(
        _ categories: [VaultInterviewCategory],
        codingOnly: Bool
    ) -> [VaultInterviewCategory] {
        guard codingOnly else { return categories }
        return categories.filter(Self.isCodingVaultCategory)
    }

    nonisolated private static func isCodingVaultCategory(_ category: VaultInterviewCategory) -> Bool {
        let title = InterviewKnowledgeMatcher.normalize(category.title)
        let icon = category.icon.lowercased()

        if Self.codingVaultCategoryTokens.contains(where: title.contains) {
            return true
        }

        let codingIconSignals = [
            "forwardslash",
            "curlybraces",
            "terminal"
        ]
        return codingIconSignals.contains(where: icon.contains)
    }

    private func retrieveInterviewMatches(
        for query: String,
        maxResults: Int,
        minimumScore: Double = 0.16,
        codingOnly: Bool = false
    ) async -> [InterviewKnowledgeMatch] {
        let index = await currentInterviewKnowledgeIndex()
        let queryLanguageCode = InterviewKnowledgeMatcher.dominantLanguageCode(for: query)
        let records = codingOnly ? index.codingRecords : index.allRecords
        
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

    private func retrievalKey(for record: InterviewKnowledgeRecord) -> String {
        let category = InterviewKnowledgeMatcher.normalize(record.category)
        let question = InterviewKnowledgeMatcher.normalize(record.question)
        return "\(category)|\(question)"
    }

    private func loadInterviewNotesRecords() -> [InterviewKnowledgeRecord] {
        let rawNotes = UserDefaults.standard.string(forKey: "teleprompterText") ?? ""
        return Self.loadInterviewNotesRecords(from: rawNotes)
    }

    static func interviewNoteCacheEntries(from rawNotes: String) -> [(question: String, answer: String, category: String)] {
        loadInterviewNotesRecords(from: rawNotes).map {
            (
                question: $0.question,
                answer: $0.answer,
                category: $0.category
            )
        }
    }

    private static func loadInterviewNotesRecords(from rawNotes: String) -> [InterviewKnowledgeRecord] {
        let blocks = parseInterviewNoteBlocks(from: rawNotes)
        guard !blocks.isEmpty else { return [] }
        
        return blocks.map { block in
            InterviewKnowledgeRecord(
                category: "Interview Notes",
                question: block.question,
                answer: block.details,
                keyPoints: block.keyPoints,
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: block.question,
                    answer: block.details,
                    keyPoints: block.keyPoints,
                    category: "Interview Notes"
                )
            )
        }
    }

    private func currentInterviewKnowledgeIndex() async -> InterviewKnowledgeIndex {
        let snapshot = await MainActor.run { VaultService.shared.categories }
        let rawNotes = UserDefaults.standard.string(forKey: "teleprompterText") ?? ""
        let signature = interviewKnowledgeSignature(categories: snapshot, rawNotes: rawNotes)

        if let cachedInterviewKnowledgeIndex, cachedInterviewKnowledgeIndex.signature == signature {
            return cachedInterviewKnowledgeIndex
        }

        let notesRecords = Self.loadInterviewNotesRecords(from: rawNotes)
        let allVaultRecords = snapshot.flatMap { category in
            category.items.map { item in
                InterviewKnowledgeRecord(
                    category: "Interview Vault > \(category.title)",
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
            }
        }

        let codingCategories = Self.scopedVaultCategories(snapshot, codingOnly: true)
        let codingVaultRecords = codingCategories.flatMap { category in
            category.items.map { item in
                InterviewKnowledgeRecord(
                    category: "Interview Vault > \(category.title)",
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
            }
        }

        let allRecords = deduplicatedInterviewRecords(notesRecords + allVaultRecords)
        let codingRecords = deduplicatedInterviewRecords(codingVaultRecords)
        let index = InterviewKnowledgeIndex(
            signature: signature,
            allRecords: allRecords,
            codingRecords: codingRecords
        )
        cachedInterviewKnowledgeIndex = index
        return index
    }

    private func deduplicatedInterviewRecords(_ records: [InterviewKnowledgeRecord]) -> [InterviewKnowledgeRecord] {
        var deduplicated: [InterviewKnowledgeRecord] = []
        deduplicated.reserveCapacity(records.count)
        var seenQuestionKeys = Set<String>()

        for record in records {
            let key = retrievalKey(for: record)
            guard !key.isEmpty, seenQuestionKeys.insert(key).inserted else { continue }
            deduplicated.append(record)
        }

        return deduplicated
    }

    private func interviewKnowledgeSignature(
        categories: [VaultInterviewCategory],
        rawNotes: String
    ) -> String {
        let categoryPayload = categories.map { category in
            let itemsPayload = category.items.map { item in
                [
                    item.question,
                    item.answerFinnish,
                    item.translationTr,
                    item.keyPoints.joined(separator: "|")
                ].joined(separator: "§")
            }.joined(separator: "¶")

            return [
                category.title,
                category.icon,
                itemsPayload
            ].joined(separator: "¤")
        }.joined(separator: "∆")

        return "\(categoryPayload)|notes:\(rawNotes)".sha256()
    }

    private static func parseInterviewNoteBlocks(from rawText: String) -> [(question: String, details: String, keyPoints: [String])] {
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

    private static func isInterviewNoteQuestionLine(_ line: String) -> Bool {
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

    private static func isInterviewNoteSeparatorLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let separatorChars = CharacterSet(charactersIn: "-_—–=•*|")
        let filtered = line.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !filtered.isEmpty else { return false }
        let separatorCount = filtered.filter { separatorChars.contains($0) }.count
        return separatorCount >= max(8, Int(Double(filtered.count) * 0.8))
    }

    private static func cleanedInterviewQuestionLine(from line: String) -> String {
        let removedNumbering = line.replacingOccurrences(
            of: #"^\s*\d+\s*[\.\)]\s*"#,
            with: "",
            options: .regularExpression
        )
        return removedNumbering.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractInterviewNoteKeyPoints(from text: String) -> [String] {
        let normalized = InterviewKnowledgeMatcher.normalize(text)
        let tokens = normalized.split(separator: " ").map(String.init)
        let filtered = tokens.filter { $0.count >= 4 }
        return Array(Set(filtered)).sorted().prefix(8).map { $0 }
    }

    private func compactContextText(_ text: String, maxCharacters: Int) -> String {
        let compacted = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compacted.count > maxCharacters else { return compacted }
        return String(compacted.prefix(maxCharacters)) + " ..."
    }

    private func filteredFallbackAnchors(
        primary: [InterviewKnowledgeMatch],
        fallback: [InterviewKnowledgeMatch],
        maxEntries: Int
    ) -> [InterviewKnowledgeMatch] {
        guard !fallback.isEmpty else { return [] }

        let primaryScore = primary.first?.score ?? 0
        let scoreFloor = max(0.18, primaryScore > 0 ? primaryScore - 0.20 : 0.18)
        var seenQuestionKeys = Set(primary.map { InterviewKnowledgeMatcher.normalize($0.record.question) })
        var filtered: [InterviewKnowledgeMatch] = []

        for match in fallback where match.score >= scoreFloor {
            let key = InterviewKnowledgeMatcher.normalize(match.record.question)
            guard !key.isEmpty, seenQuestionKeys.insert(key).inserted else { continue }
            filtered.append(match)
            if filtered.count >= maxEntries {
                break
            }
        }

        return filtered
    }

    private func buildInterviewGroundingContext(
        primaryMatches: [InterviewKnowledgeMatch],
        fallbackMatches: [InterviewKnowledgeMatch],
        profile: ResponseProfile
    ) -> String {
        guard !primaryMatches.isEmpty || !fallbackMatches.isEmpty else { return "" }

        let primaryContext = buildVaultContext(
            from: primaryMatches,
            maxEntries: profile == .interviewConcise ? 1 : 3,
            questionLimit: profile == .interviewConcise ? 150 : 220,
            answerLimit: profile == .interviewConcise ? 240 : 380,
            header: "[INTERVIEW GROUNDING]"
        )

        let fallbackContext = buildVaultContext(
            from: fallbackMatches,
            maxEntries: profile == .interviewConcise ? 1 : 2,
            questionLimit: profile == .interviewConcise ? 120 : 180,
            answerLimit: profile == .interviewConcise ? 180 : 280,
            header: "[INTERVIEW GROUNDING BACKUP]"
        )

        if primaryContext.isEmpty { return fallbackContext }
        if fallbackContext.isEmpty { return primaryContext }
        return primaryContext + "\n" + fallbackContext
    }

    private func buildVaultContext(
        from matches: [InterviewKnowledgeMatch],
        maxEntries: Int = 3,
        questionLimit: Int = 220,
        answerLimit: Int = 420,
        header: String = "[INTERVIEW VAULT MATCHES]"
    ) -> String {
        guard !matches.isEmpty else { return "" }

        let maxCharacters = 1_900
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

    private func resolvedInterviewLanguageCode(
        currentLanguageCode: String?,
        topMatch: InterviewKnowledgeMatch?
    ) -> String? {
        let normalizedCurrent = String((currentLanguageCode ?? "en").lowercased().prefix(2))
        guard let topMatch else { return normalizedCurrent }

        // Keep current lock when evidence is weak.
        guard topMatch.score >= 0.28 else { return normalizedCurrent }

        let questionLanguage = InterviewKnowledgeMatcher
            .dominantLanguageCode(for: topMatch.record.question)?
            .lowercased()
        let answerLanguage = InterviewKnowledgeMatcher
            .dominantLanguageCode(for: topMatch.record.answer)?
            .lowercased()

        let shortQuestionLanguage = String((questionLanguage ?? "").prefix(2))
        let shortAnswerLanguage = String((answerLanguage ?? "").prefix(2))

        // If detection defaulted to English but strongest vault evidence is Finnish, lock to Finnish.
        if normalizedCurrent == "en",
           (shortQuestionLanguage == "fi" || shortAnswerLanguage == "fi") {
            return "fi"
        }

        if normalizedCurrent == "fi" {
            return "fi"
        }

        return normalizedCurrent
    }

    private func localizedDirectVaultAnswer(
        _ answer: String,
        queryLanguageCode: String?
    ) async -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return answer }
        guard let queryLanguageCode else { return trimmed }
        let shortCode = String(queryLanguageCode.lowercased().prefix(2))
        guard shortCode == "fi" || shortCode == "en" || shortCode == "tr" else { return trimmed }

        guard !canUseDirectVaultAnswer(queryLanguageCode: shortCode, answer: trimmed) else {
            return trimmed
        }

        let targetLanguageName = languageName(for: shortCode)
        let translationPrompt = """
        Rewrite this interview answer into \(targetLanguageName).
        - Keep EXACT meaning.
        - Keep tone concise and interview-ready.
        - Do not add new facts.
        - Output only the rewritten answer.

        ANSWER:
        \(trimmed)
        """

        guard let rewritten = try? await ollamaService.generate(
            messages: [OllamaService.ChatMessage(role: "user", content: translationPrompt, images: nil)],
            model: AIModelNames.fast
        ) else {
            return trimmed
        }

        let finalized = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalized.isEmpty ? trimmed : finalized
    }

    private func canUseDirectVaultFastPath(
        queryTokenCount: Int,
        topMatch: InterviewKnowledgeMatch,
        secondBestScore: Double
    ) -> Bool {
        let isShortQuery = queryTokenCount <= 3
        let scoreThreshold = isShortQuery ? 0.64 : 0.46
        let separationThreshold = isShortQuery ? 0.08 : 0.04
        guard topMatch.score >= scoreThreshold else { return false }
        guard (topMatch.score - secondBestScore) >= separationThreshold else { return false }
        if isShortQuery && topMatch.matchedTokenCount == 0 {
            return false
        }
        return true
    }

    nonisolated static func hasRequiredInterviewConceptCoverage(
        queryConcepts: Set<String>,
        recordConcepts: Set<String>
    ) -> Bool {
        if queryConcepts.contains("problem") && !recordConcepts.contains("problem") {
            return false
        }

        let actorConcepts = queryConcepts.intersection(["client", "coworker"])
        if !actorConcepts.isEmpty && !actorConcepts.isSubset(of: recordConcepts) {
            return false
        }

        return true
    }

    nonisolated static func canUseInstantInterviewCache(
        isInterviewConcise: Bool,
        requiresWebSearch: Bool,
        isCodingQuery: Bool,
        isFollowUpQuery: Bool,
        strongestRoleScore: Double,
        cacheIsWarm: Bool
    ) -> Bool {
        guard cacheIsWarm else { return false }
        guard isInterviewConcise else { return false }
        guard !requiresWebSearch else { return false }
        guard !isFollowUpQuery else { return false }
        _ = isCodingQuery
        _ = strongestRoleScore
        return true
    }

    nonisolated static func supportedResponseLanguageCode(
        for query: String,
        providedLanguageCode: String? = nil
    ) -> String? {
        let lowerQuery = query.lowercased()
        
        // Match Turkish unique characters first
        if lowerQuery.contains("ğ") || lowerQuery.contains("ı") || lowerQuery.contains("ş") || lowerQuery.contains("ç") {
            return "tr"
        }
        
        let normalized = InterviewKnowledgeMatcher.normalize(query)
        let words = normalized.split(separator: " ").map(String.init)
        
        let turkishSignals = [
            "neden", "nasil", "nasıl", "hangi", "kim", "ne zaman",
            "anlat", "soru", "yardim", "yardım", "selam", "merhaba",
            "nedir", "nelerdir", "yap", "acikla", "açıkla", "mi", "mı", "mu", "mü",
            "misin", "mısın", "musun", "müsün", "gerek", "gerekir"
        ]
        if turkishSignals.contains(where: { words.contains($0) }) {
            return "tr"
        }
        
        let finnishSignals = [
            "mika", "mikä", "mita", "mitä", "miten", "miksi",
            "millainen", "milloin", "onko", "voitko", "voisitko",
            "kysymys", "suomi", "finnish", "ja", "tai", "eli", "mutta"
        ]
        if finnishSignals.contains(where: { words.contains($0) }) {
            return "fi"
        }

        let preferred = preferredLanguageCode(for: query, providedLanguageCode: providedLanguageCode)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if preferred.hasPrefix("fi") || preferred == "finnish" {
            return "fi"
        }
        if preferred.hasPrefix("tr") || preferred == "turkish" {
            return "tr"
        }
        if preferred.hasPrefix("en") || preferred == "english" {
            return "en"
        }

        return "en"
    }

    nonisolated static func shouldSuppressAutomaticWebSearch(for query: String) -> Bool {
        let normalized = InterviewKnowledgeMatcher.normalize(query)
        let lowered = query.lowercased()
        let inlineCodeSignals = ["const ", "let ", "type ", "function ", "async ", "await ", "=>", "{", "}"]
        let looksSelfContainedCode = inlineCodeSignals.contains(where: lowered.contains)
        guard isCodingRelatedQuery(normalized) || looksSelfContainedCode else { return false }

        let explicitWebIntentTokens = [
            "latest", "güncel", "en son", "current", "docs", "documentation",
            "source", "sources", "web", "internet", "benchmark", "release", "released",
            "recommend", "best", "compare", "vs", "library", "framework"
        ]
        if explicitWebIntentTokens.contains(where: normalized.contains) {
            return false
        }

        if looksSelfContainedCode && query.contains("?") {
            return true
        }

        return TavilyService.preferredQuery(from: query, maxLength: 220).count < query.count || query.count > 260
    }

    nonisolated static func containsConcreteCodeSnippet(_ query: String) -> Bool {
        let lowered = query.lowercased()
        let codeSignals = [
            "```", "const ", "let ", "var ", "type ", "interface ", "class ", "struct ",
            "function ", "async ", "await ", "return ", "=>", "{", "}", "db.", ";"
        ]
        let hitCount = codeSignals.reduce(into: 0) { count, signal in
            if lowered.contains(signal) {
                count += 1
            }
        }

        if lowered.contains("```") {
            return true
        }

        if query.contains("\n") && hitCount >= 3 {
            return true
        }

        return hitCount >= 5
    }

    nonisolated static func requiresCorrectedCodeResponse(_ query: String) -> Bool {
        let normalized = InterviewKnowledgeMatcher.normalize(query)
        guard isCodingRelatedQuery(normalized), containsConcreteCodeSnippet(query) else { return false }

        let fixTokens = [
            "what is wrong", "whats wrong", "problem", "issues", "fix", "correct", "safer",
            "vikaa", "ongelmia", "ongelma", "mita ongelmia", "mitä ongelmia", "korjaisit",
            "korjaa", "duzelt", "düzelt", "yanlis", "yanlış"
        ]

        return fixTokens.contains(where: normalized.contains)
    }

    nonisolated static func isSelfContainedCodingDebugQuery(_ query: String) -> Bool {
        shouldSuppressAutomaticWebSearch(for: query) && requiresCorrectedCodeResponse(query)
    }

    nonisolated static func modelFacingQuery(
        originalQuery: String,
        expectedLanguageCode: String?,
        isSelfContainedCodingQuery: Bool
    ) -> String {
        guard isSelfContainedCodingQuery else { return originalQuery }

        let languageName: String = {
            switch expectedLanguageCode?.lowercased() {
            case "tr", "turkish":
                return "Turkish"
            case "fi", "finnish":
                return "Finnish"
            case "en", "english":
                return "English"
            default:
                return "the user's language"
            }
        }()

        return """
        Review the pasted code and answer the user's debugging question directly.

        Required output format:
        - Start with 2-4 short bullets naming the main production risks.
        - Then provide the corrected code in a fenced markdown code block.
        - End with 1-2 short sentences explaining why the corrected version is safer.
        - Answer in \(languageName).
        - Do not omit the code block.
        - Keep comments brief and useful.

        USER QUESTION:
        \(originalQuery)
        """
    }

    nonisolated static func multiQuestionModelFacingQuery(
        baseQuery: String,
        segments: [String],
        expectedLanguageCode: String?
    ) -> String {
        guard segments.count >= 2 else { return baseQuery }

        let languageInstruction: String = {
            switch expectedLanguageCode?.lowercased() {
            case "fi", "finnish":
                return "Answer only in Finnish."
            case "en", "english":
                return "Answer only in English."
            default:
                return "Answer in the same language as the user's message."
            }
        }()

        let segmentLines = segments.enumerated().map { index, segment in
            "Q\(index + 1): \(segment)"
        }.joined(separator: "\n")

        return """
        \(baseQuery)

        [MULTI-QUESTION OUTPUT CONTRACT]
        - You must answer all \(segments.count) questions in order.
        - Use one short paragraph per question.
        - Do not merge questions into a single generic paragraph.
        - If [Qx FALLBACK REQUIRED] appears in context, generate that segment from [ACTIVE ROLE GROUNDING] and [USER PERSONA].
        - \(languageInstruction)

        [DETECTED QUESTIONS]
        \(segmentLines)
        """
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

    private func followUpContextIfNeeded(for query: String) -> FollowUpContext? {
        guard Self.isFollowUpQuestion(query) else { return nil }
        return lastFollowUpContext
    }

    private func updateFollowUpContext(
        query: String,
        answer: String,
        interviewMatches: [InterviewKnowledgeMatch],
        activeRoleGroundingContext: String,
        languageCode: String?
    ) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !trimmedAnswer.isEmpty else { return }

        let topRecord = interviewMatches.first?.record
        lastFollowUpContext = FollowUpContext(
            previousQuestion: trimmedQuery,
            previousAnswer: trimmedAnswer,
            groundedQuestion: topRecord?.question.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            groundedAnswer: topRecord?.answer.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            activeRoleContext: compactContextText(activeRoleGroundingContext, maxCharacters: 360),
            languageCode: languageCode
        )
    }

    private func buildFollowUpGroundingContext(
        for query: String,
        context: FollowUpContext
    ) -> String {
        var lines = [
            "[FOLLOW-UP CONTEXT]",
            "The current question appears to continue the immediately previous topic.",
            "Current follow-up question: \(query)",
            "Previous user question: \(context.previousQuestion)"
        ]

        if !context.groundedQuestion.isEmpty,
           InterviewKnowledgeMatcher.normalize(context.groundedQuestion) != InterviewKnowledgeMatcher.normalize(context.previousQuestion) {
            lines.append("Previous matched topic: \(context.groundedQuestion)")
        }

        let groundedAnswer = context.groundedAnswer.isEmpty ? context.previousAnswer : context.groundedAnswer
        let answerSnippet = compactVaultText(groundedAnswer, limit: 260)
        if !answerSnippet.isEmpty {
            lines.append("Previous grounded answer: \(answerSnippet)")
        }

        if !context.activeRoleContext.isEmpty {
            lines.append(context.activeRoleContext)
        }

        if let languageCode = context.languageCode, !languageCode.isEmpty {
            lines.append("Previous answer language: \(languageCode)")
        }

        lines.append("Answer the current question as a follow-up. Keep it consistent with the previous answer. If exact detail is missing, extend it conservatively using the same topic, the active role, and the user persona.")
        return lines.joined(separator: "\n") + "\n"
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
