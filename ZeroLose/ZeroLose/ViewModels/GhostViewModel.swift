import Foundation
import SwiftUI
import Cocoa
import Observation
import PDFKit
import NaturalLanguage
import Combine
import os

// MARK: - Chat History Models
struct ChatMessage: Identifiable, Sendable {
    enum AssistantOrigin: Sendable {
        case system
        case cache
        case groundedFastPath
        case aiGenerated
    }

    let id: UUID
    let text: String
    let isUser: Bool
    let type: MessageType
    let assistantOrigin: AssistantOrigin?
    let relatedQuery: String?
    
    enum MessageType: Sendable {
        case text
        case image
        case error
        case thinking
    }
    let imageData: Data?

    var allowsAIRefinement: Bool {
        guard !isUser else { return false }
        guard let relatedQuery, !relatedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let assistantOrigin else { return false }
        switch assistantOrigin {
        case .cache, .groundedFastPath:
            return true
        case .system, .aiGenerated:
            return false
        }
    }

    var assistantBadgeText: String? {
        switch assistantOrigin {
        case .cache:
            return "CACHE"
        case .groundedFastPath:
            return "FAST"
        default:
            return nil
        }
    }
    
    init(
        id: UUID = UUID(),
        text: String,
        isUser: Bool,
        type: MessageType,
        imageData: Data? = nil,
        assistantOrigin: AssistantOrigin? = nil,
        relatedQuery: String? = nil
    ) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.type = type
        self.imageData = imageData
        self.assistantOrigin = assistantOrigin
        self.relatedQuery = relatedQuery
    }
}

/// Represents a query waiting to be processed
enum PendingQuery: Sendable {
    case text(
        query: String,
        source: String,
        language: String? = nil,
        webSearchMode: WebSearchMode = .automatic,
        allowAgentActions: Bool = false,
        processingMode: IntelligenceService.ProcessingMode = .automatic,
        showUserMessage: Bool = true,
        targetAssistantMessageID: UUID? = nil
    )
    case vision(data: Data, source: String, query: String?)
}

@Observable
@MainActor
class GhostViewModel {
    var messages: [ChatMessage] = []
    var isBusy: Bool = false
    var statusMessage: String = "Ready"
    var currentModelDisplay: String = "Gemini 3 Flash"
    var isClipboardActive: Bool = false
    var isListeningActive: Bool = false
    var attachedFileData: Data? = nil
    var attachedFileName: String? = nil
    
    // Indexing State
    var isIndexing: Bool = false
    var indexingStatus: String = ""
    
    // Queuing System
    private var queryQueue: [PendingQuery] = []
    
    // Services
    private let ollamaService: OllamaService
    private let visionService: VisionService
    private let clipboardService: ClipboardService
    private let screenshotWatcher: ScreenshotWatcherService
    private let audioService: AudioService
    private let intelligenceService: IntelligenceService
    let zeroOperator: ZeroOperator
    private let responseCacheService = ResponseCacheService.shared
    
    // RAG Services for PDF processing
    private let documentProcessor: DocumentProcessor
    private let embeddingService: OllamaEmbeddingService
    private let vectorStore: VectorStore
    
    private let logger = Logger.app
    
    // Active AI Task for cancellation
    private var activeTask: Task<Void, Never>? = nil
    
    // Settings
    var isAutoScreenshotActive: Bool = GhostViewModel.userDefaultsBool("autoAnalyze", defaultValue: true)
    
    private let chatHistoryService: ChatHistoryService?
    
    // Keep enough visible context but avoid large batch removals that look like a UI refresh.
    private let maxMessages = 220
    private let maxTrimBatch = 12
    
    // Pre-compiled Regex for faster cleaning during streaming.
    // These patterns are compile-time string literals — try! is safe and intentional here.
    private let actionRegex = try! NSRegularExpression(pattern: #"(?s)\[ACTION:\s*(\{.*?\})\]"#, options: [])
    private let codeBlockRegex = try! NSRegularExpression(pattern: #"(?s)```.*?```"#, options: [])
    private let infoTagRegex = try! NSRegularExpression(pattern: #"(?s)\[[A-ZÇĞİÖŞÜ ]+:.*?\]"#, options: [])
    
    // Streaming render pipeline (coalesced updates for smooth UI)
    private var streamingRenderTask: Task<Void, Never>? = nil
    private var pendingStreamingText: String? = nil
    private var streamingTargetIndex: Int? = nil
    private var lastRenderedStreamingText: String = ""
    private let streamingRenderInterval: Duration = .milliseconds(50)
    private var slashFileContextPath: String? = nil
    private var slashFileContextPreview: String = ""
    private var activeQuerySource: String? = nil
    private var lastHandledVoiceQuestionSignature: String = ""
    private var lastHandledVoiceQuestionAt: Date = .distantPast
    private let voiceQuestionDedupWindow: TimeInterval = 3
    
    init(
        ollamaService: OllamaService,
        visionService: VisionService,
        clipboardService: ClipboardService,
        screenshotWatcher: ScreenshotWatcherService,
        audioService: AudioService,
        intelligenceService: IntelligenceService,
        documentProcessor: DocumentProcessor,
        embeddingService: OllamaEmbeddingService,
        vectorStore: VectorStore,
        zeroOperator: ZeroOperator,
        chatHistoryService: ChatHistoryService? = nil
    ) {
        self.ollamaService = ollamaService
        self.visionService = visionService
        self.clipboardService = clipboardService
        self.screenshotWatcher = screenshotWatcher
        self.audioService = audioService
        self.intelligenceService = intelligenceService
        self.documentProcessor = documentProcessor
        self.embeddingService = embeddingService
        self.vectorStore = vectorStore
        self.zeroOperator = zeroOperator
        self.chatHistoryService = chatHistoryService
        
        setupObservations()
    }
    
    private func setupObservations() {
        // Observe voice transcripts reactively — no polling, event-driven via @Published.values
        Task { @MainActor in
            for await transcript in audioService.$lastVoiceTranscript.values {
                guard !Task.isCancelled, !transcript.isEmpty else { continue }
                let language = audioService.lastVoiceLanguage
                processVoiceTranscript(transcript, language: language)
            }
        }

        // Observe clipboard changes reactively — no polling, event-driven via @Published.values
        Task { @MainActor in
            for await copiedText in clipboardService.$copiedText.values {
                guard !Task.isCancelled, !copiedText.isEmpty else { continue }
                guard isClipboardActive else { continue }
                logger.info("Clipboard change detected, adding to queue: \(copiedText.prefix(20))...")
                analyzeCopiedText(copiedText)
            }
        }

        // Observe screenshots reactively — already correct, no changes needed
        Task { @MainActor in
            var lastHandledDataHash: Int? = nil
            for await data in screenshotWatcher.$lastScreenshotData.values {
                guard !Task.isCancelled, let data else { continue }

                self.isAutoScreenshotActive = Self.userDefaultsBool("autoAnalyze", defaultValue: true)

                let currentHash = data.hashValue
                guard currentHash != lastHandledDataHash else { continue }
                lastHandledDataHash = currentHash

                guard isAutoScreenshotActive else {
                    logger.info("📸 Screenshot detected but auto-analyze is disabled")
                    continue
                }

                logger.info("📸 New auto-screenshot detected, analyzing immediately...")
                analyzeImage(data, source: "Auto Screenshot")
            }
        }
    }

    nonisolated static func userDefaultsBool(_ key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
    
    // MARK: - Actions
    
    func clearHistory() {
        messages.removeAll()
        intelligenceService.clearHistory() // Add this method to IntelligenceService
        addMessage("History Cleared.", isUser: false)
    }
    
    func toggleClipboard() {
        isClipboardActive.toggle()
        statusMessage = isClipboardActive ? "Clipboard: ON" : "Clipboard: OFF"
    }
    
    func toggleListening() {
        if audioService.isListening {
            audioService.stopListening()
            statusMessage = "Listening Stopped"
            isListeningActive = false
        } else {
            audioService.startListening()
            statusMessage = "Listening (Gatekeeper Active)..."
            isListeningActive = true
        }
    }
    
    func stopResponse() {
        guard isBusy, let task = activeTask else { return }
        task.cancel()
        activeTask = nil
        activeQuerySource = nil
        isBusy = false
        statusMessage = "Interrupted"
        
        // Mark last AI message as interrupted if it's still thinking/streaming
        if let lastMsg = messages.last, !lastMsg.isUser {
            let index = messages.count - 1
            let currentText = lastMsg.text == "Thinking..." ? "" : lastMsg.text
            messages[index] = ChatMessage(
                id: lastMsg.id,
                text: currentText + " [Stopped by user]",
                isUser: false,
                type: .text,
                assistantOrigin: lastMsg.assistantOrigin,
                relatedQuery: lastMsg.relatedQuery
            )
        }
        
        // Clear queue on manual stop
        if !queryQueue.isEmpty {
            logger.info("Clearing \(self.queryQueue.count) pending items from queue.")
            queryQueue.removeAll()
        }
        
        resetStreamingRenderState()
    }
    
    private func processNextInQueue() {
        guard !isBusy, !queryQueue.isEmpty else { return }
        let next = queryQueue.removeFirst()
        logger.info("Processing next query from queue. Remaining: \(self.queryQueue.count)")
        
        switch next {
        case .text(
            let query,
            let source,
            let language,
            let webSearchMode,
            let allowAgentActions,
            let processingMode,
            let showUserMessage,
            let targetAssistantMessageID
        ):
            processQuestion(
                query,
                source: source,
                language: language,
                webSearchMode: webSearchMode,
                allowAgentActions: allowAgentActions,
                processingMode: processingMode,
                showUserMessage: showUserMessage,
                targetAssistantMessageID: targetAssistantMessageID
            )
        case .vision(let data, let source, let query):
            analyzeImage(data, source: source, customQuery: query)
        }
    }
    
    func askQuestion(_ text: String, webSearchMode: WebSearchMode = .automatic) {
        if let attachmentData = attachedFileData {
            let query = text.isEmpty ? "Analyze this document/image." : text
            analyzeImage(attachmentData, source: attachedFileName ?? "Attachment", customQuery: query)
            clearAttachment()
        } else {
            processQuestion(text, source: "Manual Input", webSearchMode: webSearchMode)
        }
    }

    func refineAnswerWithAI(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
              message.allowsAIRefinement,
              let query = message.relatedQuery else {
            return
        }

        processQuestion(
            query,
            source: "AI Refine",
            processingMode: .forceAIReasoning,
            showUserMessage: false,
            targetAssistantMessageID: messageID
        )
    }
    
    func clearAttachment() {
        attachedFileData = nil
        attachedFileName = nil
    }

    private func assistantOrigin(
        for origin: IntelligenceService.ResponseOrigin
    ) -> ChatMessage.AssistantOrigin {
        switch origin {
        case .instantCache, .storedCache:
            return .cache
        case .groundedFastPath:
            return .groundedFastPath
        case .model:
            return .aiGenerated
        }
    }
    
    // MARK: - Logic
    
    func analyzeCopiedText(_ text: String) -> Void {
        guard isClipboardActive else { return }
        
        // Detect language of copied text
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var detectedLang = recognizer.dominantLanguage?.rawValue
        
        // Fallback for short text or low confidence
        if detectedLang == nil || text.count < 20 {
            // If "auto" is selected, default to nil (let LLM decide), otherwise use the explicit setting
            let manualLang = UserDefaults.standard.string(forKey: "audioLanguage")
            if manualLang != "auto" {
                detectedLang = manualLang
            }
        }
        
        processQuestion(text, source: "Clipboard", language: detectedLang)
    }
    
    private func addMessage(
        _ text: String,
        isUser: Bool,
        type: ChatMessage.MessageType? = nil,
        imageData: Data? = nil,
        assistantOrigin: ChatMessage.AssistantOrigin? = nil,
        relatedQuery: String? = nil
    ) {
        let finalType = type ?? (imageData != nil ? .image : .text)
        let msg = ChatMessage(
            text: text,
            isUser: isUser,
            type: finalType,
            imageData: imageData,
            assistantOrigin: assistantOrigin,
            relatedQuery: relatedQuery
        )
        messages.append(msg)
        trimChatHistoryIfNeeded()
        
        // PERSIST TO LONG-TERM MEMORY (Async)
        if type == .text || type == .image {
             Task {
                 try? await chatHistoryService?.addMessage(text: text, isUser: isUser)
             }
        }
    }

    private func processVoiceTranscript(_ transcript: String, language: String?) {
        let detectedQuestions = IntelligenceService.detectedQuestionSegments(transcript)
        guard !detectedQuestions.isEmpty else {
            if isListeningActive && !isBusy {
                statusMessage = "Listening for interviewer questions..."
            }
            logger.debug("Ignoring non-question voice transcript: \(transcript.prefix(80), privacy: .public)")
            return
        }

        let signature = detectedQuestions
            .map(InterviewKnowledgeMatcher.normalize)
            .joined(separator: "|")
        let now = Date()
        if signature == lastHandledVoiceQuestionSignature,
           now.timeIntervalSince(lastHandledVoiceQuestionAt) < voiceQuestionDedupWindow {
            logger.debug("Skipping duplicate voice question: \(signature, privacy: .public)")
            return
        }

        lastHandledVoiceQuestionSignature = signature
        lastHandledVoiceQuestionAt = now

        let query = detectedQuestions.joined(separator: " ")
        logger.info("Voice question detected (\(detectedQuestions.count) segment(s)): \(query.prefix(120), privacy: .public)")
        processQuestion(query, source: "Voice Question", language: language)
    }

    private func trimChatHistoryIfNeeded() {
        guard messages.count > maxMessages else { return }
        let excessCount = messages.count - maxMessages
        let trimCount = min(max(excessCount, 1), maxTrimBatch)
        messages.removeFirst(trimCount)
        logger.info("Chat history trimmed by \(trimCount) messages (current: \(self.messages.count))")
    }
    
    private func beginStreamingRender(at messageIndex: Int) {
        resetStreamingRenderState()
        streamingTargetIndex = messageIndex
    }
    
    private func scheduleStreamingRender(_ partial: String, at messageIndex: Int) {
        streamingTargetIndex = messageIndex
        pendingStreamingText = partial
        
        guard streamingRenderTask == nil else { return }
        
        streamingRenderTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled {
                guard let targetIndex = self.streamingTargetIndex,
                      let latestText = self.pendingStreamingText else { break }
                
                self.pendingStreamingText = nil
                self.applyStreamingText(latestText, at: targetIndex)
                
                do {
                    try await Task.sleep(for: self.streamingRenderInterval)
                } catch {
                    break
                }
                
                if self.pendingStreamingText == nil {
                    break
                }
            }
            
            self.streamingRenderTask = nil
        }
    }
    
    private func applyStreamingText(_ text: String, at messageIndex: Int) {
        let cleaned = cleanActionTags(from: text)
        guard cleaned != lastRenderedStreamingText else { return }
        lastRenderedStreamingText = cleaned
        
        if messages.count > messageIndex {
            let existingMessage = messages[messageIndex]
            messages[messageIndex] = ChatMessage(
                id: existingMessage.id,
                text: cleaned,
                isUser: false,
                type: cleaned.isEmpty ? .thinking : .text,
                assistantOrigin: existingMessage.assistantOrigin,
                relatedQuery: existingMessage.relatedQuery
            )
        }
    }
    
    private func flushStreamingRender() {
        guard let targetIndex = streamingTargetIndex,
              let latestText = pendingStreamingText else { return }
        
        pendingStreamingText = nil
        applyStreamingText(latestText, at: targetIndex)
    }
    
    private func resetStreamingRenderState() {
        streamingRenderTask?.cancel()
        streamingRenderTask = nil
        pendingStreamingText = nil
        streamingTargetIndex = nil
        lastRenderedStreamingText = ""
    }
    
    func processQuestion(
        _ text: String,
        source: String,
        language: String? = nil,
        webSearchMode: WebSearchMode = .automatic,
        allowAgentActions: Bool? = nil,
        processingMode: IntelligenceService.ProcessingMode = .automatic,
        showUserMessage: Bool = true,
        targetAssistantMessageID: UUID? = nil
    ) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        let isSlashCommand = cleanedText.hasPrefix("/")
        let resolvedAllowActions = isSlashCommand ? false : (allowAgentActions ?? shouldAllowAgentActions(for: cleanedText))

        if isBusy {
            logger.info("AI Busy. Queuing text query: \(cleanedText.prefix(20))...")
            let pendingQuery: PendingQuery =
                .text(
                    query: cleanedText,
                    source: source,
                    language: language,
                    webSearchMode: webSearchMode,
                    allowAgentActions: resolvedAllowActions,
                    processingMode: processingMode,
                    showUserMessage: showUserMessage,
                    targetAssistantMessageID: targetAssistantMessageID
                )

            if source == "Voice Question" {
                queryQueue.removeAll { queued in
                    if case .text(
                        query: _,
                        source: let queuedSource,
                        language: _,
                        webSearchMode: _,
                        allowAgentActions: _,
                        processingMode: _,
                        showUserMessage: _,
                        targetAssistantMessageID: _
                    ) = queued {
                        return queuedSource == "Voice Question"
                    }
                    return false
                }
                queryQueue.insert(pendingQuery, at: 0)
                statusMessage = "Prioritizing latest voice question..."

                if activeQuerySource == "Voice Question" {
                    logger.info("Interrupting in-flight voice reply for latest interviewer question")
                    activeTask?.cancel()
                }
            } else {
                queryQueue.append(pendingQuery)
                statusMessage = "Queued (\(queryQueue.count) pending)"
            }
            return
        }
        
        if isSlashCommand {
            executeSlashCommand(cleanedText, source: source)
            return
        }
        
        isBusy = true
        activeQuerySource = source
        statusMessage = "Thinking (\(source))..."

        if showUserMessage {
            addMessage(text, isUser: true)
        }

        let index: Int
        if let targetAssistantMessageID,
           let existingIndex = messages.firstIndex(where: { $0.id == targetAssistantMessageID }) {
            messages[existingIndex] = ChatMessage(
                id: targetAssistantMessageID,
                text: "Thinking...",
                isUser: false,
                type: .thinking,
                relatedQuery: cleanedText
            )
            index = existingIndex
        } else {
            addMessage("Thinking...", isUser: false, type: .thinking, relatedQuery: cleanedText)
            index = messages.count - 1
        }
        beginStreamingRender(at: index)
        
        activeTask = Task { @MainActor in
            do {
                let processedResponse = try await intelligenceService.process(
                    query: text,
                    imageData: nil,
                    webSearchMode: webSearchMode,
                    allowAgentActions: resolvedAllowActions,
                    processingMode: processingMode,
                    detectedLanguage: language,
                    onStatusUpdate: { [weak self] status in
                        Task { @MainActor in
                            self?.statusMessage = status
                        }
                    },
                    onPartialResponse: { [weak self] partial in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.scheduleStreamingRender(partial, at: index)
                        }
                    }
                )
                
                flushStreamingRender()
                
                // Handle actions only for explicit action commands.
                let cleanedText: String
                if resolvedAllowActions {
                    cleanedText = await self.handleActions(in: processedResponse.text)
                } else {
                    cleanedText = self.sanitizeNonActionResponse(processedResponse.text)
                }
                if self.messages.count > index {
                    let displayText = self.preferredDisplayedAssistantText(
                        streamedText: self.messages[index].text,
                        finalizedText: cleanedText
                    )
                    let assistantOrigin = self.assistantOrigin(for: processedResponse.origin)
                    let relatedQuery = processedResponse.origin.allowsAIRefinement
                        ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                    self.messages[index] = ChatMessage(
                        id: self.messages[index].id,
                        text: displayText,
                        isUser: false,
                        type: .text,
                        assistantOrigin: assistantOrigin,
                        relatedQuery: relatedQuery
                    )
                }
                
                Task {
                    try? await self.chatHistoryService?.addMessage(text: cleanedText, isUser: false)
                }
                
                statusMessage = "Ready"
            } catch is CancellationError {
                logger.info("AI Task Cancelled by user")
                statusMessage = "Stopped"
            } catch {
                logger.error("Failed to process question: \(error.localizedDescription)")
                if self.messages.count > index {
                    self.messages[index] = ChatMessage(
                        id: self.messages[index].id,
                        text: "Error: \(error.localizedDescription)",
                        isUser: false,
                        type: .error,
                        relatedQuery: cleanedText
                    )
                }
                statusMessage = "Error"
            }
            resetStreamingRenderState()
            isBusy = false
            activeQuerySource = nil
            activeTask = nil
            processNextInQueue()
        }
    }
    
    private func shouldAllowAgentActions(for text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        
        if normalized.count < 30 {
            let commandTokens = ["mute", "unmute", "volume", "trash", "empty", "pause", "play", "stop"]
            if commandTokens.contains(where: { normalized.contains($0) }) {
                return true
            }
        }
        
        return false
    }
    
    private func sanitizeNonActionResponse(_ text: String) -> String {
        let cleaned = cleanActionTags(from: text)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            return "Hazırım. Sorunu kısa yaz, net cevap vereyim."
        }
        
        let looksLikeActionJSON =
            trimmed.contains("\"type\"") &&
            trimmed.contains("\"payload\"") &&
            (trimmed.contains("applescript") || trimmed.contains("shell") || trimmed.contains("stop"))
        
        if looksLikeActionJSON {
            return "Hazırım. Sorunu kısa yaz, net cevap vereyim."
        }
        
        return trimmed
    }

    private func preferredDisplayedAssistantText(streamedText: String, finalizedText: String) -> String {
        let streamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalized = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalized.isEmpty else { return streamed }
        guard !streamed.isEmpty, streamed != "Thinking..." else { return finalized }

        let normalizedStreamed = normalizeDisplayComparisonText(streamed)
        let normalizedFinalized = normalizeDisplayComparisonText(finalized)

        if normalizedStreamed == normalizedFinalized {
            return finalized
        }

        if normalizedFinalized.hasPrefix(normalizedStreamed) || normalizedStreamed.hasPrefix(normalizedFinalized) {
            let delta = abs(finalized.count - streamed.count)
            if delta <= 36 {
                return finalized
            }
        }

        // Preserve the streamed wording if the finalized version drifted too far.
        return streamed
    }

    private func normalizeDisplayComparisonText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private struct SlashCommandPlan {
        let statusLabel: String
        let execution: SlashCommandExecution
        let successMessage: String
    }

    private enum SlashCommandExecution {
        case none
        case appleScript(String)
        case openURL(URL)
        case fileOperation(FileSystemOperation)
    }

    private enum FileSystemOperation {
        case pwd
        case list(path: String)
        case read(path: String)
        case makeDirectory(path: String)
        case createFile(path: String)
        case write(path: String, content: String, append: Bool)
        case move(source: String, destination: String)
        case replace(path: String?, find: String, replace: String)
        case replaceDirectory(path: String, find: String, replace: String)
        case context
        case sudo(command: String)
    }
    
    private enum SlashCommandError: LocalizedError {
        case usage(String)
        case unsupported(String)
        
        var errorDescription: String? {
            switch self {
            case .usage(let message), .unsupported(let message):
                return message
            }
        }
    }
    
    private func executeSlashCommand(_ commandText: String, source: String) {
        isBusy = true
        statusMessage = "Executing slash command (\(source))..."
        
        addMessage(commandText, isUser: true)
        addMessage("Running command...", isUser: false, type: .thinking)
        let index = messages.count - 1
        
        activeTask = Task { @MainActor in
            defer {
                isBusy = false
                activeTask = nil
                processNextInQueue()
            }
            
            do {
                let plan = try parseSlashCommand(commandText)
                statusMessage = plan.statusLabel
                
                let finalText: String
                switch plan.execution {
                case .appleScript(let script):
                    let raw = try await zeroOperator.executeAppleScript(script)
                    finalText = formatSlashResult(rawResult: raw, fallback: plan.successMessage)
                case .openURL(let url):
                    finalText = openURL(url) ? plan.successMessage : "URL açılamadı: \(url.absoluteString)"
                case .fileOperation(let operation):
                    finalText = try await executeFileSystemOperation(operation)
                case .none:
                    finalText = plan.successMessage
                }

                let displayText = formatSlashDisplay(commandText: commandText, result: finalText)
                
                updateAssistantMessage(at: index, text: displayText, type: .text)
                
                Task {
                    try? await chatHistoryService?.addMessage(text: displayText, isUser: false)
                }
                
                statusMessage = "Ready"
            } catch is CancellationError {
                logger.info("Slash command task cancelled")
                updateAssistantMessage(at: index, text: "Komut durduruldu.", type: .error)
                statusMessage = "Stopped"
            } catch let error as SlashCommandError {
                let message = error.localizedDescription
                updateAssistantMessage(at: index, text: message, type: .error)
                statusMessage = "Ready"
            } catch {
                logger.error("Slash command failed: \(error.localizedDescription)")
                updateAssistantMessage(at: index, text: error.localizedDescription, type: .error)
                statusMessage = "Error"
            }
        }
    }
    
    private func updateAssistantMessage(at index: Int, text: String, type: ChatMessage.MessageType) {
        guard messages.indices.contains(index) else { return }
        messages[index] = ChatMessage(
            id: messages[index].id,
            text: text,
            isUser: false,
            type: type,
            assistantOrigin: messages[index].assistantOrigin,
            relatedQuery: messages[index].relatedQuery
        )
    }
    
    private func formatSlashResult(rawResult: String, fallback: String) -> String {
        let cleaned = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        
        let normalized = cleaned.lowercased()
        if normalized == "success" || normalized == "missing value" {
            return fallback
        }
        return cleaned
    }

    private func formatSlashDisplay(commandText: String, result: String) -> String {
        let normalizedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalResult = normalizedResult.isEmpty ? "Komut tamamlandı." : normalizedResult

        let shouldUseCodeBlock = finalResult.contains("\n") || finalResult.count > 90
        let renderedResult: String
        if shouldUseCodeBlock {
            renderedResult = """
            ```text
            \(finalResult)
            ```
            """
        } else {
            renderedResult = "✅ \(finalResult)"
        }

        return """
        [SLASH_COMMAND] \(commandText)

        \(renderedResult)
        """
    }
    
    private func parseSlashCommand(_ input: String) throws -> SlashCommandPlan {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw SlashCommandError.unsupported("Slash komutu '/' ile başlamalı.")
        }
        
        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else {
            throw SlashCommandError.usage(buildSlashHelpText())
        }
        
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let command = parts.first?.lowercased() else {
            throw SlashCommandError.usage(buildSlashHelpText())
        }
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) : ""
        
        switch command {
        case "help":
            return SlashCommandPlan(
                statusLabel: "Slash Help",
                execution: .none,
                successMessage: buildSlashHelpText()
            )
        case "trash":
            return SlashCommandPlan(
                statusLabel: "Trash",
                execution: .appleScript(AutomationLibrary.System.safeEmptyTrash),
                successMessage: "Çöp kutusu boşaltıldı."
            )
        case "desktop":
            return SlashCommandPlan(
                statusLabel: "Desktop Cleanup",
                execution: .appleScript(AutomationLibrary.Finder.cleanDesktop),
                successMessage: "Masaüstü düzenlendi."
            )
        case "mute":
            return SlashCommandPlan(
                statusLabel: "Mute",
                execution: .appleScript(AutomationLibrary.System.mute),
                successMessage: "Ses kapatıldı."
            )
        case "unmute":
            return SlashCommandPlan(
                statusLabel: "Unmute",
                execution: .appleScript(AutomationLibrary.System.unmute),
                successMessage: "Ses açıldı."
            )
        case "volume":
            guard let value = Int(args), (0...100).contains(value) else {
                throw SlashCommandError.usage("Kullanım: /Volume 0-100")
            }
            return SlashCommandPlan(
                statusLabel: "Volume \(value)",
                execution: .appleScript(String(format: AutomationLibrary.System.setVolume, value)),
                successMessage: "Ses seviyesi \(value) olarak ayarlandı."
            )
        case "lock":
            return SlashCommandPlan(
                statusLabel: "Lock Screen",
                execution: .appleScript(AutomationLibrary.System.lockScreen),
                successMessage: "Ekran kilitlendi."
            )
        case "sleep":
            return SlashCommandPlan(
                statusLabel: "Sleep",
                execution: .appleScript(AutomationLibrary.System.sleep),
                successMessage: "Mac uyku moduna alındı."
            )
        case "screensaver":
            return SlashCommandPlan(
                statusLabel: "Screensaver",
                execution: .appleScript(AutomationLibrary.System.screenSaver),
                successMessage: "Ekran koruyucu başlatıldı."
            )
        case "screenshot":
            return SlashCommandPlan(
                statusLabel: "Screenshot",
                execution: .appleScript(AutomationLibrary.System.screenshotClipboard),
                successMessage: "Ekran görüntüsü panoya alındı."
            )
        case "google":
            let query = args.isEmpty ? "macOS automation" : args
            guard let url = URL(string: "https://www.google.com/search?q=\(urlEncoded(query))") else {
                throw SlashCommandError.usage("Google URL üretilemedi. Geçerli bir arama yaz.")
            }
            return SlashCommandPlan(
                statusLabel: "Google Search",
                execution: .openURL(url),
                successMessage: "Google araması açıldı."
            )
        case "youtube":
            let query = args.isEmpty ? "interview tips" : args
            guard let url = URL(string: "https://www.youtube.com/results?search_query=\(urlEncoded(query))") else {
                throw SlashCommandError.usage("YouTube URL üretilemedi. Geçerli bir arama yaz.")
            }
            return SlashCommandPlan(
                statusLabel: "YouTube Search",
                execution: .openURL(url),
                successMessage: "YouTube araması açıldı."
            )
        case "github":
            let query = args.isEmpty ? "trending" : args
            let url: String
            if query.contains("/") && !query.contains(" ") {
                url = "https://github.com/\(urlEncoded(query))"
            } else {
                url = "https://github.com/search?q=\(urlEncoded(query))"
            }
            guard let finalURL = URL(string: url) else {
                throw SlashCommandError.usage("GitHub URL üretilemedi.")
            }
            return SlashCommandPlan(
                statusLabel: "GitHub",
                execution: .openURL(finalURL),
                successMessage: "GitHub açıldı."
            )
        case "news":
            let query = args.isEmpty ? "technology" : args
            guard let url = URL(string: "https://news.google.com/search?q=\(urlEncoded(query))") else {
                throw SlashCommandError.usage("News URL üretilemedi.")
            }
            return SlashCommandPlan(
                statusLabel: "News Search",
                execution: .openURL(url),
                successMessage: "Haber araması açıldı."
            )
        case "music":
            return try parseMediaCommand(appName: "Music", args: args)
        case "spotify":
            return try parseSpotifyCommand(args: args)
        case "app":
            return try parseAppCommand(args: args)
        case "fs", "file", "files":
            return try parseFileSystemCommand(args: args)
        case "open":
            guard !args.isEmpty else { throw SlashCommandError.usage("Kullanım: /Open Safari") }
            return SlashCommandPlan(
                statusLabel: "Open \(args)",
                execution: .appleScript(AutomationLibrary.AppControl.activateApp(args)),
                successMessage: "\(args) açıldı."
            )
        case "close":
            guard !args.isEmpty else { throw SlashCommandError.usage("Kullanım: /Close Safari") }
            return SlashCommandPlan(
                statusLabel: "Close \(args)",
                execution: .appleScript(AutomationLibrary.AppControl.closeApp(args)),
                successMessage: "\(args) kapatıldı."
            )
        default:
            throw SlashCommandError.unsupported("Tanımsız slash komutu: /\(command)\n\n\(buildSlashHelpText())")
        }
    }
    
    private func parseMediaCommand(appName: String, args: String) throws -> SlashCommandPlan {
        let action = args.lowercased()
        switch action {
        case "", "toggle", "play", "pause":
            return SlashCommandPlan(
                statusLabel: "\(appName) Play/Pause",
                execution: .appleScript(AutomationLibrary.Media.musicPlayPause),
                successMessage: "\(appName) play/pause komutu gönderildi."
            )
        case "next":
            return SlashCommandPlan(
                statusLabel: "\(appName) Next",
                execution: .appleScript("tell application \"Music\" to next track"),
                successMessage: "Sonraki parçaya geçildi."
            )
        case "prev", "previous":
            return SlashCommandPlan(
                statusLabel: "\(appName) Previous",
                execution: .appleScript("tell application \"Music\" to previous track"),
                successMessage: "Önceki parçaya geçildi."
            )
        default:
            throw SlashCommandError.usage("Kullanım: /Music play|pause|next|prev")
        }
    }
    
    private func parseSpotifyCommand(args: String) throws -> SlashCommandPlan {
        let action = args.lowercased()
        switch action {
        case "", "toggle", "play", "pause":
            return SlashCommandPlan(
                statusLabel: "Spotify Play/Pause",
                execution: .appleScript(AutomationLibrary.Media.spotifyPlayPause),
                successMessage: "Spotify play/pause komutu gönderildi."
            )
        case "next":
            return SlashCommandPlan(
                statusLabel: "Spotify Next",
                execution: .appleScript(AutomationLibrary.Media.spotifyNext),
                successMessage: "Spotify sonraki parçaya geçti."
            )
        case "prev", "previous":
            return SlashCommandPlan(
                statusLabel: "Spotify Previous",
                execution: .appleScript(AutomationLibrary.Media.spotifyPrev),
                successMessage: "Spotify önceki parçaya geçti."
            )
        default:
            throw SlashCommandError.usage("Kullanım: /Spotify play|pause|next|prev")
        }
    }
    
    private func parseAppCommand(args: String) throws -> SlashCommandPlan {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else {
            throw SlashCommandError.usage("Kullanım: /App open Safari veya /App close Safari")
        }
        
        let action = parts[0].lowercased()
        let appName = parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !appName.isEmpty else {
            throw SlashCommandError.usage("Uygulama adı eksik.")
        }
        
        switch action {
        case "open", "start":
            return SlashCommandPlan(
                statusLabel: "Open \(appName)",
                execution: .appleScript(AutomationLibrary.AppControl.activateApp(appName)),
                successMessage: "\(appName) açıldı."
            )
        case "close", "quit":
            return SlashCommandPlan(
                statusLabel: "Close \(appName)",
                execution: .appleScript(AutomationLibrary.AppControl.closeApp(appName)),
                successMessage: "\(appName) kapatıldı."
            )
        default:
            throw SlashCommandError.usage("Kullanım: /App open Safari veya /App close Safari")
        }
    }
    
    private func buildSlashHelpText() -> String {
        let topCommands = [
            "/Trash",
            "/Desktop",
            "/Mute",
            "/Unmute",
            "/Volume 50",
            "/Lock",
            "/Sleep",
            "/Screenshot",
            "/Google query",
            "/Youtube query",
            "/GitHub owner/repo",
            "/News topic",
            "/Music play|pause|next|prev",
            "/Spotify play|pause|next|prev",
            "/App open Safari",
            "/App close Safari",
            "/Fs pwd",
            "/Fs ls ~/Desktop",
            "/Fs read ~/Desktop/file.txt",
            "/Fs write ~/Desktop/file.txt | Merhaba",
            "/Fs mv ~/Desktop/a.txt -> ~/Desktop/b.txt",
            "/Fs replace eski => yeni",
            "/Fs replace-dir ~/Desktop/proje | old => new",
            "/Fs context",
            "/Fs sudo ls /var/root"
        ]
        return "Kullanılabilir slash komutları:\n" + topCommands.joined(separator: "\n")
    }

    private func parseFileSystemCommand(args: String) throws -> SlashCommandPlan {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let action = parts.first?.lowercased() else {
            throw SlashCommandError.usage(fileSystemUsageText())
        }
        let payload = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch action {
        case "pwd":
            return SlashCommandPlan(
                statusLabel: "File System PWD",
                execution: .fileOperation(.pwd),
                successMessage: ""
            )
        case "ls", "list":
            let path = payload.isEmpty ? "." : payload
            return SlashCommandPlan(
                statusLabel: "List Directory",
                execution: .fileOperation(.list(path: path)),
                successMessage: ""
            )
        case "read", "cat":
            guard !payload.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs read <dosya-yolu>")
            }
            return SlashCommandPlan(
                statusLabel: "Read File",
                execution: .fileOperation(.read(path: payload)),
                successMessage: ""
            )
        case "mkdir":
            guard !payload.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs mkdir <klasor-yolu>")
            }
            return SlashCommandPlan(
                statusLabel: "Create Directory",
                execution: .fileOperation(.makeDirectory(path: payload)),
                successMessage: "Klasör oluşturuldu."
            )
        case "touch":
            guard !payload.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs touch <dosya-yolu>")
            }
            return SlashCommandPlan(
                statusLabel: "Create File",
                execution: .fileOperation(.createFile(path: payload)),
                successMessage: "Dosya oluşturuldu."
            )
        case "write":
            guard let (path, content) = splitOnce(payload, separator: "|"),
                  !path.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs write <dosya-yolu> | <icerik>")
            }
            return SlashCommandPlan(
                statusLabel: "Write File",
                execution: .fileOperation(.write(path: path, content: content, append: false)),
                successMessage: "Dosya yazıldı."
            )
        case "append":
            guard let (path, content) = splitOnce(payload, separator: "|"),
                  !path.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs append <dosya-yolu> | <icerik>")
            }
            return SlashCommandPlan(
                statusLabel: "Append File",
                execution: .fileOperation(.write(path: path, content: content, append: true)),
                successMessage: "Dosyaya ekleme yapıldı."
            )
        case "mv", "move":
            guard let (source, destination) = splitOnce(payload, separator: "->"),
                  !source.isEmpty, !destination.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs mv <kaynak> -> <hedef>")
            }
            return SlashCommandPlan(
                statusLabel: "Move Item",
                execution: .fileOperation(.move(source: source, destination: destination)),
                successMessage: "Taşıma tamamlandı."
            )
        case "replace", "edit", "edit-last":
            if let (pathPart, replacePart) = splitOnce(payload, separator: "|"),
               let (find, replacement) = splitOnce(replacePart, separator: "=>"),
               !pathPart.isEmpty {
                return SlashCommandPlan(
                    statusLabel: "Edit File",
                    execution: .fileOperation(.replace(path: pathPart, find: find, replace: replacement)),
                    successMessage: "Dosya güncellendi."
                )
            }

            guard let (find, replacement) = splitOnce(payload, separator: "=>") else {
                throw SlashCommandError.usage("Kullanım: /Fs replace eski => yeni  veya  /Fs replace <dosya> | eski => yeni")
            }
            return SlashCommandPlan(
                statusLabel: "Edit Context File",
                execution: .fileOperation(.replace(path: nil, find: find, replace: replacement)),
                successMessage: "Bağlam dosyası güncellendi."
            )
        case "replace-dir", "editdir", "batch-edit":
            guard let (pathPart, replacePart) = splitOnce(payload, separator: "|"),
                  let (find, replacement) = splitOnce(replacePart, separator: "=>"),
                  !pathPart.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs replace-dir <klasor> | eski => yeni")
            }
            return SlashCommandPlan(
                statusLabel: "Batch Edit Directory",
                execution: .fileOperation(.replaceDirectory(path: pathPart, find: find, replace: replacement)),
                successMessage: "Klasörde toplu güncelleme tamamlandı."
            )
        case "context":
            return SlashCommandPlan(
                statusLabel: "File Context",
                execution: .fileOperation(.context),
                successMessage: ""
            )
        case "sudo":
            guard !payload.isEmpty else {
                throw SlashCommandError.usage("Kullanım: /Fs sudo <shell-komutu>")
            }
            return SlashCommandPlan(
                statusLabel: "Privileged Shell",
                execution: .fileOperation(.sudo(command: payload)),
                successMessage: "Sudo komutu çalıştırıldı."
            )
        default:
            throw SlashCommandError.usage(fileSystemUsageText())
        }
    }

    private func executeFileSystemOperation(_ operation: FileSystemOperation) async throws -> String {
        let fileManager = FileManager.default

        switch operation {
        case .pwd:
            return "Current directory:\n\(fileManager.currentDirectoryPath)"
        case .list(let rawPath):
            let path = resolvePath(rawPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SlashCommandError.usage("Klasör bulunamadı: \(path)")
            }
            let items = try fileManager.contentsOfDirectory(atPath: path).sorted()
            let limitedItems = Array(items.prefix(150))
            let formatted = limitedItems.map { item -> String in
                let fullPath = (path as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
                return isDir.boolValue ? "\(item)/" : item
            }
            let suffix = items.count > limitedItems.count ? "\n... (\(items.count - limitedItems.count) more)" : ""
            return "Directory: \(path)\n" + formatted.joined(separator: "\n") + suffix
        case .read(let rawPath):
            let path = resolvePath(rawPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw SlashCommandError.usage("Dosya bulunamadı: \(path)")
            }
            let content = try readTextFile(at: path)
            let previewLimit = 3500
            let preview = content.count > previewLimit
                ? String(content.prefix(previewLimit)) + "\n\n... (truncated)"
                : content

            slashFileContextPath = path
            slashFileContextPreview = preview
            return "File loaded into context: \(path)\n\n\(preview)"
        case .makeDirectory(let rawPath):
            let path = resolvePath(rawPath)
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            return "Directory created: \(path)"
        case .createFile(let rawPath):
            let path = resolvePath(rawPath)
            let parent = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: path) {
                let created = fileManager.createFile(atPath: path, contents: Data())
                if !created {
                    throw SlashCommandError.usage("Dosya oluşturulamadı: \(path)")
                }
            }
            return "File ready: \(path)"
        case .write(let rawPath, let content, let append):
            let path = resolvePath(rawPath)
            let parent = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)

            let payload = Data(content.utf8)
            if append {
                if !fileManager.fileExists(atPath: path) {
                    let created = fileManager.createFile(atPath: path, contents: Data())
                    if !created {
                        throw SlashCommandError.usage("Dosya oluşturulamadı: \(path)")
                    }
                }
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: URL(fileURLWithPath: path), options: .atomic)
            }

            slashFileContextPath = path
            slashFileContextPreview = content.count > 1200 ? String(content.prefix(1200)) + "\n... (truncated)" : content
            return append ? "Appended: \(path)" : "Written: \(path)"
        case .move(let rawSource, let rawDestination):
            let source = resolvePath(rawSource)
            let destination = resolvePath(rawDestination)
            guard fileManager.fileExists(atPath: source) else {
                throw SlashCommandError.usage("Kaynak bulunamadı: \(source)")
            }
            if fileManager.fileExists(atPath: destination) {
                throw SlashCommandError.usage("Hedef zaten var: \(destination)")
            }
            let parent = (destination as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try fileManager.moveItem(atPath: source, toPath: destination)

            if slashFileContextPath == source {
                slashFileContextPath = destination
            }
            return "Moved:\n\(source)\n->\n\(destination)"
        case .replace(let rawPathOrNil, let findRaw, let replaceRaw):
            let find = findRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = replaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !find.isEmpty else {
                throw SlashCommandError.usage("Aranacak metin boş olamaz.")
            }

            let targetPath: String
            if let rawPath = rawPathOrNil {
                targetPath = resolvePath(rawPath)
            } else if let contextPath = slashFileContextPath {
                targetPath = contextPath
            } else {
                throw SlashCommandError.usage("Bağlam dosyası yok. Önce /Fs read <dosya> komutunu çalıştır.")
            }

            let original = try readTextFile(at: targetPath)
            let occurrences = max(0, original.components(separatedBy: find).count - 1)
            guard occurrences > 0 else {
                return "No match found in file: \(targetPath)"
            }

            let updated = original.replacingOccurrences(of: find, with: replacement)
            try Data(updated.utf8).write(to: URL(fileURLWithPath: targetPath), options: .atomic)
            slashFileContextPath = targetPath
            slashFileContextPreview = updated.count > 1200 ? String(updated.prefix(1200)) + "\n... (truncated)" : updated
            return "Updated file: \(targetPath)\nReplacements: \(occurrences)"
        case .replaceDirectory(let rawPath, let findRaw, let replaceRaw):
            let basePath = resolvePath(rawPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: basePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SlashCommandError.usage("Klasör bulunamadı: \(basePath)")
            }

            let find = findRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = replaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !find.isEmpty else {
                throw SlashCommandError.usage("Aranacak metin boş olamaz.")
            }

            let textExtensions = Set([
                "txt", "md", "markdown", "swift", "m", "mm", "h", "hpp",
                "c", "cpp", "json", "yaml", "yml", "toml", "ini", "cfg",
                "js", "jsx", "ts", "tsx", "css", "scss", "html", "xml",
                "py", "java", "kt", "kts", "go", "rs", "sh", "zsh"
            ])

            guard let enumerator = fileManager.enumerator(atPath: basePath) else {
                throw SlashCommandError.usage("Klasör okunamadı: \(basePath)")
            }
            let relativePaths = (enumerator.allObjects as? [String]) ?? []

            var changedFiles = 0
            var replacementCount = 0
            var firstChangedPath: String? = nil

            for relative in relativePaths {
                let fullPath = (basePath as NSString).appendingPathComponent(relative)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                    continue
                }

                let ext = URL(fileURLWithPath: fullPath).pathExtension.lowercased()
                guard textExtensions.contains(ext) else { continue }

                guard let original = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
                let localCount = max(0, original.components(separatedBy: find).count - 1)
                guard localCount > 0 else { continue }

                let updated = original.replacingOccurrences(of: find, with: replacement)
                try Data(updated.utf8).write(to: URL(fileURLWithPath: fullPath), options: .atomic)

                if firstChangedPath == nil {
                    firstChangedPath = fullPath
                    slashFileContextPreview = updated.count > 1200 ? String(updated.prefix(1200)) + "\n... (truncated)" : updated
                }
                changedFiles += 1
                replacementCount += localCount
            }

            if let firstChangedPath {
                slashFileContextPath = firstChangedPath
            }

            return "Batch edit finished in: \(basePath)\nChanged files: \(changedFiles)\nTotal replacements: \(replacementCount)"
        case .context:
            guard let contextPath = slashFileContextPath else {
                return "Aktif dosya bağlamı yok. Önce /Fs read <dosya> çalıştır."
            }
            let preview = slashFileContextPreview.isEmpty ? "(boş)" : slashFileContextPreview
            return "Context file:\n\(contextPath)\n\nPreview:\n\(preview)"
        case .sudo(let command):
            let approved = presentPrivilegedExecutionConfirmation(command: command)
            guard approved else {
                return "Sudo komutu iptal edildi."
            }
            let output = try await zeroOperator.executePrivilegedShell(command)
            if output.isEmpty || output.lowercased() == "success" {
                return "Sudo komutu tamamlandı."
            }
            return output
        }
    }

    private func readTextFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let iso = String(data: data, encoding: .isoLatin1) {
            return iso
        }
        throw SlashCommandError.usage("Dosya metin formatında değil veya çözümlenemedi: \(path)")
    }

    private func resolvePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let baseURL: URL
        if expanded.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: expanded)
        } else {
            baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        }
        return baseURL.standardizedFileURL.path
    }

    private func splitOnce(_ text: String, separator: String) -> (String, String)? {
        guard let range = text.range(of: separator) else { return nil }
        let left = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let right = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (left, right)
    }

    private func fileSystemUsageText() -> String {
        """
        File system slash komutları:
        /Fs pwd
        /Fs ls <klasor-yolu>
        /Fs mkdir <klasor-yolu>
        /Fs touch <dosya-yolu>
        /Fs read <dosya-yolu>
        /Fs write <dosya-yolu> | <icerik>
        /Fs append <dosya-yolu> | <icerik>
        /Fs mv <kaynak> -> <hedef>
        /Fs replace eski => yeni
        /Fs replace <dosya> | eski => yeni
        /Fs replace-dir <klasor> | eski => yeni
        /Fs context
        /Fs sudo <shell-komutu>
        """
    }

    private func presentPrivilegedExecutionConfirmation(command: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Sudo komutu çalıştırılsın mı?"
        alert.informativeText = """
        Bu komut yönetici yetkisiyle çalışacak ve sistemde kalıcı değişiklik yapabilir.

        Komut:
        \(command)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Çalıştır")
        alert.addButton(withTitle: "İptal")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
    
    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
    
    func analyzeImage(_ data: Data, source: String, customQuery: String? = nil) {
        if isBusy {
            logger.info("AI Busy. Queuing vision query for: \(source)")
            queryQueue.append(.vision(data: data, source: source, query: customQuery))
            statusMessage = "Queued (\(queryQueue.count) pending)"
            return
        }

        isBusy = true
        statusMessage = "Analyzing \(source)..."
        
        let userText = customQuery ?? "[Analyzing Image: \(source)]"
        addMessage(userText, isUser: true, imageData: data)
        
        addMessage("Scanning...", isUser: false, type: .thinking)
        let index = messages.count - 1
        beginStreamingRender(at: index)
        
        activeTask = Task { @MainActor in
            do {
                let visionQuery = customQuery ?? "Analyze this image. Identify technical content and provide solutions."
                
                let processedResponse = try await intelligenceService.process(
                    query: visionQuery,
                    imageData: data,
                    onStatusUpdate: { [weak self] status in
                        Task { @MainActor in
                            self?.statusMessage = status
                        }
                    },
                    onPartialResponse: { [weak self] partial in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.scheduleStreamingRender(partial, at: index)
                        }
                    }
                )
                
                flushStreamingRender()
                
                // Handle Actions on RAW response
                let cleanedText = await self.handleActions(in: processedResponse.text)
                if self.messages.count > index {
                    self.messages[index] = ChatMessage(
                        id: self.messages[index].id,
                        text: cleanedText,
                        isUser: false,
                        type: .text
                    )
                }
                
                Task {
                    try? await self.chatHistoryService?.addMessage(text: cleanedText, isUser: false)
                }
                
                statusMessage = "Ready"
            } catch is CancellationError {
                logger.info("AI Vision Task Cancelled by user")
                statusMessage = "Stopped"
            } catch {
                logger.error("Failed to analyze image: \(error.localizedDescription)")
                if self.messages.count > index {
                    self.messages[index] = ChatMessage(
                        id: self.messages[index].id,
                        text: "Error: \(error.localizedDescription)",
                        isUser: false,
                        type: .error
                    )
                }
                statusMessage = "Error"
            }
            resetStreamingRenderState()
            isBusy = false
            activeTask = nil
            processNextInQueue()
        }
    }
    
    func analyzeScreen() {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Capturing..."
        
        Task {
            guard let image = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow()) else {
                statusMessage = "Capture Failed"
                isBusy = false
                return
            }
            
            var jpegData: Data? = nil
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            
            isBusy = false
            if let data = jpegData {
                // Save to app-specific cache instead of Desktop (Privacy)
                let savedPath = saveToInternalCache(data: data)
                if let path = savedPath {
                    logger.info("📸 Screen capture saved to internal cache: \(path)")
                }
                analyzeImage(data, source: "Screen Capture")
            }
        }
    }
    
    private func saveToInternalCache(data: Data) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "Capture_\(timestamp).jpg"
        
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let capturesURL = appSupportURL.appendingPathComponent("ZeroLose/Captures", isDirectory: true)
        
        do {
            if !fileManager.fileExists(atPath: capturesURL.path) {
                try fileManager.createDirectory(at: capturesURL, withIntermediateDirectories: true)
            }
            
            let fileURL = capturesURL.appendingPathComponent(fileName)
            try data.write(to: fileURL)
            return fileURL.path
        } catch {
            logger.error("❌ Failed to save capture internally: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Interview Prep
    @discardableResult
    func warmUpInterviewContext() -> String {
        let activeRoleContext = ActiveRoleProfileService.warmUpContext(for: ActiveRoleProfileService.currentProfile())
        let baseContext = """
        [INTERVIEW MODE ACTIVATED]
        \(activeRoleContext)

        Identity Rules:
        - Use only the loaded Persona & Context, active role, interview notes, and vault entries as facts about the candidate.
        - If a personal detail is missing, do not invent a name, background, location, or years of experience.

        Language Rules:
        - Match the interviewer’s language exactly.
        - For Finnish, use professional spoken Finnish with natural tech terms.
        
        RESPONSE RULES:
        - Keep answers concise, interview-ready and factual.
        - Prefer active role grounding for company, stack, and expectation-specific questions.
        - Use memory only when directly relevant to the question.
        """
        
        let categories = VaultService.shared.categories
        let allItems: [(category: String, item: VaultInterviewItem)] = categories.flatMap { category in
            category.items.map { (category.title, $0) }
        }
        let rawNotes = UserDefaults.standard.string(forKey: "teleprompterText") ?? ""
        let noteCacheEntries = IntelligenceService.interviewNoteCacheEntries(from: rawNotes)
        let totalItems = allItems.count
        
        guard totalItems > 0 || !noteCacheEntries.isEmpty else {
            intelligenceService.setTransientPersonaContext(baseContext)
            let message = "⚠️ Vault ve Interview Notes boş. Sadece temel interview context yüklendi."
            statusMessage = message
            resetWarmUpStatus(expectedMessage: message)
            return message
        }
        
        // 1) Rebuild cache from current vault snapshot (strict warm-up consistency).
        responseCacheService.clearCache()

        // 2) Load ALL vault entries into fast response cache for instant interview replies.
        let vaultCacheEntries = allItems.map { entry in
            ResponseCacheService.InterviewCacheEntry(
                question: entry.item.question,
                answer: entry.item.answerFinnish,
                category: entry.category,
                translation: entry.item.translationTr,
                keyPoints: entry.item.keyPoints
            )
        }
        _ = responseCacheService.primeInterviewVault(entries: vaultCacheEntries)
        _ = responseCacheService.primeInterviewVault(entries: noteCacheEntries)
        let cacheEntries = allItems.map { entry in
            (question: entry.item.question, answer: entry.item.answerFinnish, category: entry.category)
        } + noteCacheEntries
        let coverage = responseCacheService.interviewVaultCoverage(entries: cacheEntries)

        // 3) Keep transient persona compact; avoid injecting full vault answers into system prompt.
        let categoryTitles = categories.map(\.title).joined(separator: ", ")
        let notesSummary = noteCacheEntries.isEmpty ? "No interview notes cached" : "Interview Notes cached: \(noteCacheEntries.count)"
        let warmupContext = """
        [INTERVIEW WARM-UP STATUS]
        Cache coverage: \(coverage.cached)/\(coverage.total)
        Categories: \(categoryTitles)
        \(notesSummary)

        Rules:
        - Use interview vault as the primary source.
        - Use Interview Notes as a secondary direct source when they contain a strong matching answer.
        - Choose a single best-matching vault answer; do not blend unrelated entries.
        - Keep answers concise and interview-ready.
        - Never mention private contact details or salary unless explicitly asked.
        """

        intelligenceService.setTransientPersonaContext("\(baseContext)\n\n\(warmupContext)")

        let message: String
        if coverage.missing == 0 {
            message = "🔥 Warm-up tamam: cache doğrulandı \(coverage.cached)/\(coverage.total)."
        } else {
            message = "⚠️ Warm-up kısmi: cache \(coverage.cached)/\(coverage.total), eksik \(coverage.missing)."
        }

        logger.info("Interview warm-up cache coverage \(coverage.cached)/\(coverage.total)")
        statusMessage = message
        resetWarmUpStatus(expectedMessage: message)
        return message
    }
    
    private func resetWarmUpStatus(expectedMessage: String) {
        Task {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            await MainActor.run {
                if statusMessage == expectedMessage {
                    statusMessage = "Ready"
                }
            }
        }
    }
    
    func attachFile(from url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        
        if fileExtension == "pdf" {
            guard let pdfDocument = PDFDocument(url: url) else {
                logger.error("Failed to load PDF: \(url.lastPathComponent)")
                return
            }
            
            // 1. Visual: Render first page for AI Vision (existing behavior)
            if let pdfPage = pdfDocument.page(at: 0) {
                let pageRect = pdfPage.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0
                let width = Int(pageRect.width * scale)
                let height = Int(pageRect.height * scale)
                
                if let cgImage = pdfPage.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        attachedFileData = jpegData
                        attachedFileName = url.lastPathComponent + " (Page 1 Visual)"
                    }
                }
            }
            
            // 2. RAG: Extract ALL text from PDF and store in VectorStore
            Task {
                do {
                    await MainActor.run {
                        self.isIndexing = true
                        statusMessage = "📄 Indexing PDF to memory..."
                    }
                    
                    let chunks = try await documentProcessor.processPDF(url: url)
                    logger.info("📝 Extracted \(chunks.count) chunks from PDF: \(url.lastPathComponent)")
                    
                    var indexed = 0
                    for chunk in chunks {
                        let embedding = try await embeddingService.embedSingle(text: chunk.text)
                        try await vectorStore.insert(chunk: chunk, embedding: embedding)
                        indexed += 1
                        
                        // Small update during loop but not too frequent
                        if indexed % 5 == 0 {
                            await MainActor.run {
                                statusMessage = "Index: \(indexed)/\(chunks.count)"
                            }
                        }
                    }
                    
                    await MainActor.run {
                        self.isIndexing = false
                        statusMessage = "✅ PDF indexed: \(indexed) chunks"
                        logger.info("✅ Successfully indexed \(indexed) chunks from \(url.lastPathComponent)")
                    }
                } catch {
                    await MainActor.run {
                        self.isIndexing = false
                        statusMessage = "⚠️ PDF indexing failed"
                        logger.error("❌ Failed to index PDF: \(error.localizedDescription)")
                    }
                }
            }
            
        } else {
            // Non-PDF files (images, text)
            do {
                let data = try Data(contentsOf: url)
                attachedFileData = data
                attachedFileName = url.lastPathComponent
                statusMessage = "Attached: \(url.lastPathComponent)"
            } catch {
                logger.error("Error attaching file: \(error.localizedDescription)")
            }
        }
    }
    
    nonisolated private func cleanActionTags(from text: String) -> String {
        // Optimization: Early exit if no special characters are present
        if !text.contains("[") && !text.contains("`") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var cleaned = text
        let nsRange = NSRange(location: 0, length: (cleaned as NSString).length)

        // 1. Remove ONLY completed [ACTION: ...] tags
        cleaned = actionRegex.stringByReplacingMatches(in: cleaned, options: [], range: nsRange, withTemplate: "")
        
        // 2. Remove completed markdown code blocks only if they are likely action-related/redundant
        // For now, let's NOT remove them globally as it might hide real code
        
        // 3. Remove internal info/thinking tags
        let freshRange = NSRange(location: 0, length: (cleaned as NSString).length)
        cleaned = infoTagRegex.stringByReplacingMatches(in: cleaned, options: [], range: freshRange, withTemplate: "")
        
        // 4. Remove partial unclosed ACTION tags at the VERY END to prevent flickering
        // We look for "[ACTION:" until the end of the string
        if let actionStartRange = cleaned.range(of: "[ACTION:", options: .backwards) {
            // Check if there is a closing bracket after this start
            let rangeAfterStart = actionStartRange.upperBound..<cleaned.endIndex
            if !cleaned[rangeAfterStart].contains("]") {
                // Unclosed tag at the end, hide it
                cleaned = String(cleaned[..<actionStartRange.lowerBound])
            }
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    @discardableResult
    private func handleActions(in text: String) async -> String {
        // Use a non-greedy regex to find all [ACTION: {...}] blocks
        let pattern = #"(?s)\[ACTION:\s*(\{.*?\})\]"#
        
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return text
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        if matches.isEmpty {
            return text
        }
        
        // Clean text by removing all matches
        let cleanedText = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        
        for match in matches {
            guard let jsonRange = Range(match.range(at: 1), in: text) else { continue }
            let jsonString = String(text[jsonRange])
            
            do {
                if let data = jsonString.data(using: .utf8),
                   let action = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    let type = action["type"] as? String
                    let payload = action["payload"] as? String ?? ""
                    
                    logger.debug("🚀 Executing Agentic Action: \(type ?? "unknown")")
                    
                    do {
                        switch type {
                        case "stop":
                            self.zeroOperator.stopAllTasks()
                        case "applescript":
                            if let loop = action["loop"] as? [String: Any],
                               let interval = loop["interval"] as? Double,
                               let label = loop["label"] as? String {
                                self.zeroOperator.startRecurringTask(script: payload, interval: interval, label: label)
                            } else {
                                try await self.zeroOperator.executeAppleScript(payload)
                            }
                        case "shell":
                            self.logger.warning("Blocked shell action from model output.")
                            return "Güvenlik nedeniyle shell eylemleri devre dışı."
                        default:
                            break
                        }
                    } catch ZeroOperator.OperatorError.unauthorized {
                        self.logger.warning("🛡️ SafetyGuard blocked an action.")
                        self.zeroOperator.activeAction = "⚠️ Safety Block"
                        return "Güvenlik nedeniyle bu eylem engellendi."
                    } catch {
                        self.logger.error("❌ Action Execution Failed: \(error.localizedDescription)")
                        
                        let errorMsg = error.localizedDescription
                        if errorMsg.contains("JavaScript") && (errorMsg.contains("Google Chrome") || errorMsg.contains("Safari")) {
                            return "Tarayıcı kontrolü kısıtlı: Chrome/Safari menüsünden Görünüm > Geliştirici > Apple Events'ten JavaScript'e İzin Ver seçeneğini aktif etmeniz gerekiyor."
                        }
                        
                        return errorMsg
                    }
                }
            } catch {
                // FALLBACK: Smart JSON Recovery
                if let manualData = self.manuallyParseBrokenJSON(jsonString) {
                    let type = manualData["type"] ?? "unknown"
                    let payload = manualData["payload"] ?? ""
                    
                    logger.warning("⚠️ JSON Parsing failed, but recovered manually. Executing... Type: \(type)")
                    
                    do {
                         switch type {
                         case "stop":
                             self.zeroOperator.stopAllTasks()
                         case "applescript":
                             try await self.zeroOperator.executeAppleScript(payload)
                         case "shell":
                             self.logger.warning("Blocked recovered shell action from model output.")
                             return "Güvenlik nedeniyle shell eylemleri devre dışı."
                         default:
                             break
                         }
                         continue
                         
                    } catch {
                        return "Eylem kurtarıldı fakat çalıştırılamadı: \(error.localizedDescription)"
                    }
                }
                
                logger.error("❌ Failed to parse action JSON: \(error.localizedDescription)")
                return "Eylem kodu cozumlenemedi."
            }
        }
        
        return cleanedText.isEmpty ? "Yapıldı" : cleanedText
    }
    
    // Manual parser for "Fast Model" outputs that forget to escape quotes
    private func manuallyParseBrokenJSON(_ text: String) -> [String: String]? {
        let typePattern = #""type"\s*:\s*"([^"]+)""#
        guard let typeRegex = try? NSRegularExpression(pattern: typePattern),
              let typeMatch = typeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let typeRange = Range(typeMatch.range(at: 1), in: text) else {
            return nil
        }
        let type = String(text[typeRange])
        
        guard let payloadKeyRange = text.range(of: "\"payload\"") else { return nil }
        let afterKey = text[payloadKeyRange.upperBound...]
        
        guard let firstQuote = afterKey.firstIndex(of: "\"") else { return nil }
        let contentStart = afterKey.index(after: firstQuote)
        
        guard let lastQuote = text.lastIndex(of: "\"") else { return nil }
        
        if contentStart < lastQuote {
            let payloadRaw = String(text[contentStart..<lastQuote])
            return ["type": type, "payload": payloadRaw]
        }
        
        return nil
    }
}
