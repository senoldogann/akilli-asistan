import Foundation
import SwiftUI
import Cocoa
import Observation
import PDFKit
import NaturalLanguage
import Combine
import os

@Observable
@MainActor
class GhostViewModel {
    var messages: [ChatMessage] = []
    var isBusy: Bool = false
    var statusMessage: String = "Ready"
    var currentModelDisplay: String {
        let provider = AIModelNames.currentProvider()
        let model = AIModelNames.reasoning(forProvider: provider)
        return "\(provider.displayName) · \(model)"
    }
    /// Approximate context-window fullness derived from the visible messages.
    /// Used by the input-area meter so the user can see how much room remains
    /// before a long conversation starts losing earlier context.
    var contextUsage: ContextUsage {
        let windowTokens = AIModelNames.contextWindow(forProvider: AIModelNames.currentProvider())
        let usedTokens = messages.reduce(0) { partial, message in
            partial + Self.estimateTokens(message.text) + Self.estimateTokens(message.thinking ?? "")
        }
        return ContextUsage(usedTokens: usedTokens, windowTokens: windowTokens)
    }
    var isClipboardActive: Bool = false
    var isListeningActive: Bool = false
    var liveVoicePreview: String = ""
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
    let computerUseService: ComputerUseService
    let browserCDPService: BrowserCDPService
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
    // Incoming cumulative partials from the network (latest wins before render).
    private var pendingStreamingText: String? = nil
    private var streamingTargetIndex: Int? = nil
    // Character-reveal queue so fast streams animate token-by-token instead of
    // jumping straight to the final answer.
    private var revealChunkBuffer: String = ""
    private var revealCursor: Int = 0
    private var lastPaintedText: String = ""
    private let streamingRenderInterval: Duration = .milliseconds(22)
    private let revealTargetTicks: Int = 28
    private var slashFileContextPath: String? = nil
    private var slashFileContextPreview: String = ""
    private var activeQuerySource: String? = nil
    private var lastHandledVoiceQuestionSignature: String = ""
    private var lastHandledVoiceQuestionAt: Date = .distantPast
    private let voiceQuestionDedupWindow: TimeInterval = 3

    /// Rough token estimate: ~4 characters per token for mixed English/Turkish/
    /// Finnish prose. This matches common LLM tokenizer behaviour closely enough
    /// for a fullness gauge without requiring a bundled tokenizer.
    private static func estimateTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }

    init(
        ollamaService: OllamaService,
        visionService: VisionService,
        clipboardService: ClipboardService,
        screenshotWatcher: ScreenshotWatcherService,
        audioService: AudioService,
        computerUseService: ComputerUseService,
        browserCDPService: BrowserCDPService,
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
        self.computerUseService = computerUseService
        self.browserCDPService = browserCDPService
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
                liveVoicePreview = transcript
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
                guard let targetIndex = self.streamingTargetIndex else { break }
                
                // Pull the latest cumulative text if a new batch has arrived.
                if let latestText = self.pendingStreamingText {
                    self.pendingStreamingText = nil
                    self.feedRevealQueue(latestText, at: targetIndex)
                }

                // Advance the reveal queue on a fixed cadence so the tail of a
                // fast burst still animates in even without new network chunks.
                if self.revealCursor < self.revealChunkBuffer.count {
                    self.revealTick(messageIndex: targetIndex)
                }
                
                do {
                    try await Task.sleep(for: self.streamingRenderInterval)
                } catch {
                    break
                }
                
                // Stop once all buffered text is painted and no new text is due.
                if self.pendingStreamingText == nil &&
                    self.revealCursor >= self.revealChunkBuffer.count {
                    break
                }
            }
            
            self.streamingRenderTask = nil
        }
    }
    
    /// Feed the newly received cumulative text into the reveal queue.
    /// The queue discovers the delta since the last painted cursor and reveals
    /// a few characters per tick, so streaming looks smooth even when the
    /// network delivers large chunks in a burst.
    private func feedRevealQueue(_ text: String, at messageIndex: Int) {
        let cleaned = cleanActionTags(from: text)
        guard cleaned != revealChunkBuffer || revealCursor < revealChunkBuffer.count else { return }

        // If this is a brand new target or the buffer was replaced, reset the
        // reveal cursor so we only paint the newly-appended portion.
        if !revealChunkBuffer.isEmpty && cleaned.count < revealChunkBuffer.count {
            revealChunkBuffer = cleaned
            revealCursor = min(revealCursor, revealChunkBuffer.count)
        } else {
            revealChunkBuffer = cleaned
        }
        revealTick(messageIndex: messageIndex)
    }

    /// Paint the next reveal chunk onto the message row.
    private func revealTick(messageIndex: Int) {
        guard messages.count > messageIndex else { return }

        // Adaptive chunk size: spread the remaining buffered characters across a
        // small fixed number of ticks so long answers animate at a steady pace
        // and short bursts still feel smooth rather than jumping.
        let remaining = revealChunkBuffer.count - revealCursor
        let chunkSize = max(1, Int(ceil(Double(remaining) / Double(revealTargetTicks))))
        let endIndex = min(revealCursor + chunkSize, revealChunkBuffer.count)
        revealCursor = endIndex

        let displayed = String(revealChunkBuffer.prefix(revealCursor))
        applyStreamingText(displayed, at: messageIndex)
    }

    private func applyStreamingText(_ text: String, at messageIndex: Int) {
        let cleaned = cleanActionTags(from: text)
        guard cleaned != lastPaintedText else { return }
        lastPaintedText = cleaned

        if messages.count > messageIndex {
            let existingMessage = messages[messageIndex]
            let updated = ChatMessage(
                id: existingMessage.id,
                text: cleaned,
                isUser: false,
                type: cleaned.isEmpty ? .thinking : .text,
                assistantOrigin: existingMessage.assistantOrigin,
                relatedQuery: existingMessage.relatedQuery,
                thinking: existingMessage.thinking
            )
            withAnimation(.easeOut(duration: 0.12)) {
                messages[messageIndex] = updated
            }
        }
    }
    
    private func flushStreamingRender() {
        guard let targetIndex = streamingTargetIndex,
              let latestText = pendingStreamingText else {
            return
        }

        pendingStreamingText = nil
        let cleanedFinal = cleanActionTags(from: latestText)

        // If the reveal queue already painted everything, keep the exact final
        // text so nothing is clipped. Otherwise keep the queue in charge: the
        // reveal loop will continue to animate the tail instead of jumping
        // straight to the full answer.
        if revealCursor >= revealChunkBuffer.count {
            revealChunkBuffer = cleanedFinal
            revealCursor = cleanedFinal.count
            applyStreamingText(cleanedFinal, at: targetIndex)
        } else {
            revealChunkBuffer = cleanedFinal
        }
    }
    
    private func resetStreamingRenderState() {
        streamingRenderTask?.cancel()
        streamingRenderTask = nil
        pendingStreamingText = nil
        streamingTargetIndex = nil
        revealChunkBuffer = ""
        revealCursor = 0
        lastPaintedText = ""
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

        // For natural-language desktop/file requests we run a deterministic
        // executor so the agent always has real facts (file counts, listings,
        // paths) instead of relying on the model to guess an answer. System
        // istekleri (çöp kutusunu boşalt, sesi kıs) doğrulanmış AutomationLibrary
        // betikleriyle çalıştırılır; böylece model halüsinasyonla tehlikeli
        // AppleScript üretmez ve Safety Block'a takılmaz.
        if resolvedAllowActions,
           let systemScript = deterministicSystemIntent(for: cleanedText) {
            // Çöp kutusunu boşaltmak kalıcı bir işlemdir. "Sor" modunda kullanıcı
            // açıkça istediyse de yine de onay iste; "Tam Erişim"/"Otomatik"
            // modlarda doğrudan çalıştır. Bu, kullanıcının "onayladım ama
            // çalışmıyor" ya da "izinsiz mi sildi" şikayetlerini önler.
            let isDestructive = deterministicSystemIntentIsDestructive(cleanedText)
            if isDestructive && approvalMode == .ask {
                let approved = presentSystemConfirmation(
                    title: "Bu işlemi onayla",
                    message: "Çöp kutusundaki öğeler kalıcı olarak silinecek."
                )
                guard approved else {
                    addMessage("İptal edildi: Çöp kutusu boşaltılmadı.", isUser: false, type: .text)
                    statusMessage = "Ready"
                    return
                }
            }

            Task { @MainActor in
                do {
                    let commandLine = "System Automation"
                    let toolMessageID = UUID()
                    messages.append(
                        ChatMessage(
                            id: toolMessageID,
                            text: commandLine,
                            isUser: false,
                            type: .text,
                            toolRun: ChatMessage.ToolRun(
                                kind: "system",
                                command: commandLine,
                                status: .running,
                                output: ""
                            )
                        )
                    )
                    let toolIndex = messages.count - 1

                    let output = try await zeroOperator.executeAppleScript(systemScript)
                    let final = output.isEmpty ? "Komut çalıştırıldı." : output

                    var updated = messages[toolIndex]
                    updated = ChatMessage(
                        id: updated.id,
                        text: updated.text,
                        isUser: false,
                        type: .text,
                        toolRun: ChatMessage.ToolRun(
                            kind: "system",
                            command: commandLine,
                            status: .done,
                            output: final
                        )
                    )
                    messages[toolIndex] = updated
                    statusMessage = "Ready"
                } catch {
                    statusMessage = "Error"
                    if !messages.isEmpty {
                        let idx = messages.count - 1
                        var existing = messages[idx]
                        existing = ChatMessage(
                            id: existing.id,
                            text: existing.text,
                            isUser: false,
                            type: .error,
                            toolRun: ChatMessage.ToolRun(
                                kind: "system",
                                command: existing.text,
                                status: .error(error.localizedDescription),
                                output: ""
                            )
                        )
                        messages[idx] = existing
                    }
                }
            }
            return
        }

        if resolvedAllowActions,
           let intent = deterministicFileIntent(for: cleanedText) {
            Task { @MainActor in
                do {
                    // Komut çalışırken "Running" durumunda görünür bir komut kartı
                    // bas; sonuç gelince aynı mesajı güncelleyip "Done" + çıktı
                    // göster. Böylece kullanıcı sohbette neyin çalıştığını görür.
                    let commandLine = Self.fileOperationCommandLine(intent)
                    let toolMessageID = UUID()
                    messages.append(
                        ChatMessage(
                            id: toolMessageID,
                            text: "\(commandLine)",
                            isUser: false,
                            type: .text,
                            toolRun: ChatMessage.ToolRun(
                                kind: "file",
                                command: commandLine,
                                status: .running,
                                output: ""
                            )
                        )
                    )
                    let toolIndex = messages.count - 1

                    let output = try await executeFileSystemOperation(intent)

                    // Sonucu çalışan kartın üzerine yaz.
                    var updated = messages[toolIndex]
                    updated = ChatMessage(
                        id: updated.id,
                        text: updated.text,
                        isUser: false,
                        type: .text,
                        toolRun: ChatMessage.ToolRun(
                            kind: "file",
                            command: commandLine,
                            status: .done,
                            output: output
                        )
                    )
                    messages[toolIndex] = updated
                    statusMessage = "Ready"
                } catch {
                    statusMessage = "Error"
                    if !messages.isEmpty {
                        let idx = messages.count - 1
                        var existing = messages[idx]
                        existing = ChatMessage(
                            id: existing.id,
                            text: existing.text,
                            isUser: false,
                            type: .error,
                            toolRun: ChatMessage.ToolRun(
                                kind: "file",
                                command: existing.text,
                                status: .error(error.localizedDescription),
                                output: ""
                            )
                        )
                        messages[idx] = existing
                    }
                }
            }
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
                    },
                    onPartialThinking: { [weak self] thinking in
                        guard let self = self else { return }
                        Task { @MainActor in
                            if self.messages.count > index {
                                let existing = self.messages[index]
                                let merged = (existing.thinking ?? "") + thinking
                                self.messages[index] = ChatMessage(
                                    id: existing.id,
                                    text: existing.text,
                                    isUser: existing.isUser,
                                    type: existing.type,
                                    imageData: existing.imageData,
                                    assistantOrigin: existing.assistantOrigin,
                                    relatedQuery: existing.relatedQuery,
                                    thinking: merged
                                )
                            }
                        }
                    }
                )
                
                flushStreamingRender()
                
                // Ajan bilgi araçlarını (web_search, file-read, system_status…)
                // her zaman kullanabilir; mutasyon araçları yalnızca onay varsa
                // çalışır. `handleActions` bu ayrımı `allowMutations` ile yapar.
                let cleanedText = await self.handleActions(
                    in: processedResponse.text,
                    allowMutations: resolvedAllowActions
                )
                if self.messages.count > index {
                    let assistantOrigin = self.assistantOrigin(for: processedResponse.origin)
                    let relatedQuery = processedResponse.origin.allowsAIRefinement
                        ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                    let mergedThinking = processedResponse.thinking ?? self.messages[index].thinking
                    // Keep the already-painted fragment as the visible text and
                    // hand the final, action-sanitized text to the reveal queue.
                    // This keeps the answer animating to completion instead of
                    // swapping in the whole answer at once.
                    self.messages[index] = ChatMessage(
                        id: self.messages[index].id,
                        text: self.lastPaintedText,
                        isUser: false,
                        type: .text,
                        assistantOrigin: assistantOrigin,
                        relatedQuery: relatedQuery,
                        thinking: mergedThinking
                    )
                    self.scheduleStreamingRender(cleanedText, at: index)
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
            isBusy = false
            activeQuerySource = nil
            activeTask = nil
            processNextInQueue()
        }
    }
    
    private func shouldAllowAgentActions(for text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        // "Tam Erişim" seçiliyken kullanıcı her eylemi önceden onaylamış sayılır.
        // Bu, kullanıcının "istediğimi yapamıyorum / safety block" şikayetinin
        // kök nedenidir: aksi hâlde yalnızca İngilizce anahtar kelimeler eylemleri
        // tetikliyordu ve doğal dil onayları ("Onaylıyorum") eyleme dönüşmüyordu.
        if approvalMode == .full {
            return true
        }

        // Detect any request that needs to touch the OS, files, desktop, or a
        // running app. Natural-language requests ("Desktop da ne kadar dosya
        // var", "Safari'yi aç", "şu klasörü listele") must be able to execute
        // actions, otherwise the agent can only reply in words.
        let staticCommandTokens = [
            "mute", "unmute", "volume", "trash", "empty",
            "pause", "play", "stop", "lock", "sleep", "screensaver",
            "screenshot", "capture", "desktop", "masaüstü", "masaustu",
            "dosya", "file", "klasör", "klasor", "folder", "dizin",
            "sil", "delete", "oluştur", "olustur", "create", "taşı", "tasi",
            "move", "yeniden adlandır", "rename", "aç", "ac", "open",
            "kapat", "close", "app", "uygulama", "terminal", "shell",
            "komut", "command", "çalıştır", "calistir", "run", "arama",
            "search", "grep", "find", "liste", "list", "kopyala", "copy",
            "yapıştır", "paste", "konum", "location", "nerede", "where",
            "kaç", "kac", "count", "say",
            // Türkçe sistem/eylem kelimeleri: İngilizce eşdeğerleri olmadan da
            // eylemleri tetikleyebilmek için eklendi. "Çöp kutusunu boşalt",
            // "ekran görüntüsü al", "sesi aç/kıs" gibi ifadeler artık tanınır.
            "boşalt", "bosalt", "çöp", "cop", "temizle", "temiz",
            "sustur", "ses", "ekran", "görüntü", "goruntu", "internet",
            "web", "değiştir", "degistir", "uygula", "göster", "goster",
            // Onay ifadeleri: Ajan bir önceki turda "Onaylıyor musun?" dediyse ve
            // kullanıcı "Onaylıyorum / Evet / Tamam" diyorsa, modelin bekleyen
            // eylemi üretmesine izin ver. Aksi hâlde `allowMutations=false` kalır
            // ve eylem etiketi kırpılıp "Hazırım." fallback'ine dönüşürdü.
            "onaylıyorum", "onay", "onayla", "evet", "tamam", "confirmed",
            "yes", "confirm", "approve"
        ]
        return staticCommandTokens.contains(where: { normalized.contains($0) })
    }

    /// Maps common natural-language file/desktop requests to a concrete
    /// `FileSystemOperation` so the agent can answer with real data. Returns
    /// `nil` when the request is not a clearly deterministic file operation.
    private func deterministicFileIntent(for text: String) -> FileSystemOperation? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Desktop file/folder count.
        if normalized.contains("masaüstü") || normalized.contains("masaustu") || normalized.contains("desktop") {
            if normalized.contains("kaç") || normalized.contains("kac") || normalized.contains("count") ||
               normalized.contains("ne kadar") || normalized.contains("adet") || normalized.contains("dosya") ||
               normalized.contains("file") {
                return .list(path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path)
            }
            if normalized.contains("liste") || normalized.contains("list") || normalized.contains("göster") || normalized.contains("goster") {
                return .list(path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path)
            }
        }

        // pwd / current working directory.
        if normalized.contains("hangi klasör") || normalized.contains("bulunduğum") || normalized.contains("working directory") ||
           normalized == "pwd" || normalized.contains("aktif klasör") {
            return .pwd
        }

        return nil
    }

    /// "Çöp kutusunu boşalt", "sesi kıs", "Safari'yi aç" gibi doğal dil isteklerini
    /// doğrulanmış `AutomationLibrary` betiklerine eşler. Modelin halüsinasyonla
    /// tehlikeli AppleScript üretmesini ve Safety Block'a takılmasını engeller.
    private func deterministicSystemIntent(for text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Çöp kutusunu boşalt (İngilizce veya Türkçe).
        if normalized.contains("trash") || normalized.contains("çöp") || normalized.contains("cop") {
            if normalized.contains("empty") || normalized.contains("boşalt") || normalized.contains("bosalt") ||
               normalized.contains("temizle") || normalized.contains("temiz") {
                return AutomationLibrary.System.safeEmptyTrash
            }
        }

        // Sesi kapat / aç.
        if normalized.contains("ses") || normalized.contains("volume") || normalized.contains("mute") {
            if normalized.contains("kıs") || normalized.contains("kis") || normalized.contains("mute") ||
               normalized.contains("sustur") || normalized.contains("kapat") {
                return AutomationLibrary.System.mute
            }
            if normalized.contains("aç") || normalized.contains("ac") || normalized.contains("unmute") {
                return AutomationLibrary.System.unmute
            }
        }

        // Ekran görüntüsü / ekran analizi.
        if normalized.contains("ekran") || normalized.contains("screen") || normalized.contains("görüntü") ||
           normalized.contains("goruntu") {
            if normalized.contains("görüntü") || normalized.contains("goruntu") || normalized.contains("foto") ||
               normalized.contains("shot") || normalized.contains("capture") {
                return AutomationLibrary.System.screenshotClipboard
            }
        }

        return nil
    }

    /// Kalıcı/destruktif sistem eylemleri için bayrak döndürür. Şu an yalnızca
    /// çöp kutusunu kalıcı olarak boşaltma işlemi bu sınıfa girer.
    private func deterministicSystemIntentIsDestructive(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (normalized.contains("trash") || normalized.contains("çöp") || normalized.contains("cop")) &&
               (normalized.contains("empty") || normalized.contains("boşalt") || normalized.contains("bosalt"))
    }

    /// Belirli bir sistem eylemi için kullanıcıya onay kutusu gösterir.
    private func presentSystemConfirmation(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Onayla")
        alert.addButton(withTitle: "İptal")
        return alert.runModal() == .alertFirstButtonReturn
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

        /// `true` ise bu işlem dosya sistemini sadece okur, değiştirmez.
        /// Bilgi araçları her zaman çalışabilirken mutasyonlar onay ister.
        var isReadOnly: Bool {
            switch self {
            case .pwd, .list, .read, .context:
                return true
            case .makeDirectory, .createFile, .write, .move, .replace,
                 .replaceDirectory, .sudo:
                return false
            }
        }
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
        try await approveIfNeeded(operation)
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

    private enum CommandApprovalMode: String {
        case ask = "ask"
        case auto = "auto"
        case full = "full"
    }

    private var approvalMode: CommandApprovalMode {
        CommandApprovalMode(rawValue: UserDefaults.standard.string(forKey: "commandApprovalMode") ?? "ask") ?? .ask
    }

    /// Read-only operations never need approval. Mutating operations ask for
    /// confirmation unless the user picked "auto" (safe ops only) or "full".
    private func approveIfNeeded(_ operation: FileSystemOperation) async throws {
        switch operation {
        case .pwd, .list, .read, .context:
            return
        default:
            break
        }

        switch approvalMode {
        case .full:
            return
        case .auto:
            // "Benim için onayla": safe write operations run automatically,
            // but anything destructive (move-overwrite / recursive replace) is
            // still gated.
            switch operation {
            case .makeDirectory, .write, .replace:
                return
            default:
                break
            }
            return
        case .ask:
            break
        }

        guard presentFileOperationConfirmation(operation) else {
            throw SlashCommandError.usage("İşlem kullanıcı tarafından iptal edildi.")
        }
    }

    private func presentFileOperationConfirmation(_ operation: FileSystemOperation) -> Bool {
        let description: String
        switch operation {
        case .move(let s, let d): description = "Dosya/klasör taşı:\n\(s) -> \(d)"
        case .replace(let p, let f, let r): description = "Dosya içeriği değiştir:\n\(p ?? "-") (\"\(f)\" -> \"\(r)\")"
        case .replaceDirectory(let p, let f, let r): description = "Klasör genelinde değiştir:\n\(p) (\"\(f)\" -> \"\(r)\")"
        case .write(let p, _, _): description = "Dosyaya yaz:\n\(p)"
        case .createFile(let p): description = "Dosya oluştur:\n\(p)"
        case .makeDirectory(let p): description = "Klasör oluştur:\n\(p)"
        case .sudo(let c): description = "Yönetici komutu çalıştır:\n\(c)"
        default: description = "Bu işlemi onayla"
        }

        let alert = NSAlert()
        alert.messageText = "Bu işlemi onayla"
        alert.informativeText = description
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Onayla")
        alert.addButton(withTitle: "İptal")
        return alert.runModal() == .alertFirstButtonReturn
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
                let cleanedText = await self.handleActions(
                    in: processedResponse.text,
                    allowMutations: false
                )
                if self.messages.count > index {
                    let existing = self.messages[index]
                    self.messages[index] = ChatMessage(
                        id: existing.id,
                        text: self.lastPaintedText,
                        isUser: false,
                        type: .text,
                        assistantOrigin: existing.assistantOrigin,
                        relatedQuery: existing.relatedQuery,
                        thinking: existing.thinking
                    )
                    self.scheduleStreamingRender(cleanedText, at: index)
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

    /// Computer Use hızlı testi: ön plandaki uygulamanın AX ağacını + OCR'ı
    /// sohbete yazar. Ajanın `computer_snapshot` eyleminin çalıştığını doğrular.
    func testComputerUseSnapshot() {
        guard !isBusy else { return }
        let app = ComputerUseService.listRunningApps().first
        guard let pid = app?.pid else {
            addMessage("Önde çalışan bir uygulama yok.", isUser: false, type: .text)
            return
        }
        statusMessage = "Computer Use Snapshot..."
        Task { @MainActor in
            let image = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
            let observation = await computerUseService.snapshot(pid: pid, screenImage: image)
            // Sohbette streaming kart olarak göster (görsel + okunabilir).
            let toolMessageID = UUID()
            messages.append(
                ChatMessage(
                    id: toolMessageID,
                    text: "Ön plandaki uygulamayı oku",
                    isUser: false,
                    type: .text,
                    toolRun: ChatMessage.ToolRun(
                        kind: "computer",
                        command: "Snap: \(app?.name ?? "?") (pid \(pid))",
                        status: .done,
                        output: observation.summary
                    )
                )
            )
            statusMessage = "Ready"
        }
    }

    /// Uçtan uca Computer Use doğrulaması: izinleri kontrol et, ön plandaki
    /// uygulamayı oku, hedef bir buton/metni bul ve tıkla. Tek tıkla kullanıcı
    /// tüm pipeline'ın çalıştığını doğrular. Sonuç streaming kart olarak gösterilir.
    func verifyComputerUseEndToEnd() {
        guard !isBusy else { return }
        statusMessage = "Computer Use doğrulanıyor..."
        let toolMessageID = UUID()
        messages.append(
            ChatMessage(
                id: toolMessageID,
                text: "Computer Use doğrulama",
                isUser: false,
                type: .text,
                toolRun: ChatMessage.ToolRun(
                    kind: "computer",
                    command: "Computer Use öz-test",
                    status: .running,
                    output: ""
                )
            )
        )
        let toolIndex = messages.count - 1

        Task { @MainActor in
            var lines: [String] = []
            // Adım 1: izinler
            let ax = ComputerUseService.hasAccessibilityPermission
            let screen = ComputerUseService.hasScreenRecordingPermission
            lines.append("İzinler:")
            lines.append("  Erişilebilirlik: \(ax ? "✓ var" : "✗ eksik")")
            lines.append("  Ekran Kaydı: \(screen ? "✓ var" : "✗ eksik")")
            guard ax else {
                lines.append("\nSONUÇ: Erişilebilirlik izni eksik. Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik > ZeroLose'u açın ve yeniden başlatın.")
                self.setToolCard(toolIndex: toolIndex, messageID: toolMessageID, command: "Computer Use öz-test", output: lines.joined(separator: "\n"), status: .error(lines.joined(separator: "\n")))
                self.statusMessage = "Ready"
                return
            }

            // Adım 2: ön plandaki uygulamayı bul
            guard let app = ComputerUseService.listRunningApps().first else {
                lines.append("\nSONUÇ: Çalışan bir uygulama yok.")
                self.setToolCard(toolIndex: toolIndex, messageID: toolMessageID, command: "Computer Use öz-test", output: lines.joined(separator: "\n"), status: .done)
                self.statusMessage = "Ready"
                return
            }
            lines.append("\nHedef: \(app.name) (pid \(app.pid))")

            // Adım 3: snapshot (ağacı oku)
            let image = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
            let observation = await computerUseService.snapshot(pid: app.pid, screenImage: image)
            let elementCount = observation.elements.count
            lines.append("Ağaç okundu: \(elementCount) etkileşimli öğe")
            lines.append("İlk öğeler:")
            for line in observation.elements.prefix(4) { lines.append("  \(line)") }

            if elementCount > 0 {
                lines.append("\n✅ SONUÇ: Computer Use end-to-end ÇALIŞIYOR. Gerçek bir tıklama için 'Gönder' / 'Kaydet' gibi bir hedef söyle.")
                self.setToolCard(toolIndex: toolIndex, messageID: toolMessageID, command: "Computer Use öz-test", output: lines.joined(separator: "\n"), status: .done)
            } else {
                lines.append("\n⚠️ SONUÇ: Ağaç boş döndü. Uygulama AX desteği vermiyor olabilir; 'computer_ocr' ile görsel hedefleme denenebilir.")
                self.setToolCard(toolIndex: toolIndex, messageID: toolMessageID, command: "Computer Use öz-test", output: lines.joined(separator: "\n"), status: .done)
            }
            self.statusMessage = "Ready"
        }
    }

    /// Verilen indeksteki araç kartını sonuçla günceller.
    private func setToolCard(
        toolIndex: Int,
        messageID: UUID,
        command: String,
        output: String,
        status: ChatMessage.ToolRun.Status
    ) {
        guard messages.indices.contains(toolIndex) else { return }
        messages[toolIndex] = ChatMessage(
            id: messageID,
            text: command,
            isUser: false,
            type: .text,
            toolRun: ChatMessage.ToolRun(
                kind: "computer",
                command: command,
                status: status,
                output: output
            )
        )
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
    /// Ajanın ürettiği `[ACTION: {...}]` etiketlerini yürütür.
    /// `allowMutations` false ise yalnızca bilgi araçları (web_search, file-read,
    /// salt-okunur shell, screenshot, audio, clipboard, system_status) çalışır;
    /// mutasyonlar (yazma/silme, uygulama kontrolü, stop) engellenir.
    private func handleActions(in text: String, allowMutations: Bool) async -> String {
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
                            if allowMutations {
                                self.zeroOperator.stopAllTasks()
                            }
                            return "İşlem durduruldu."
                        case "web_search":
                            let query = (action["query"] as? String) ?? payload
                            guard !query.isEmpty else {
                                return "Arama sorgusu boş."
                            }
                            return await runToolCard(kind: "web_search", command: "Web ara: \(query.prefix(40))") {
                                do {
                                    let searchOutput = try await self.intelligenceService.performWebSearch(query: query)
                                    return "WEB ARAMA SONUCU:\n\(searchOutput)"
                                } catch {
                                    return "Arama hatası: \(error.localizedDescription)"
                                }
                            }
                        case "shell":
                            // Shell commands still go through the strict
                            // allowlist/safety gate, but now they actually run
                            // instead of being hard-blocked.
                            return await runToolCard(kind: "shell", command: "\(payload.prefix(50))") {
                                do {
                                    let output = try await self.zeroOperator.executeShell(payload)
                                    return output.isEmpty ? "Komut çalıştırıldı." : output
                                } catch {
                                    return "Komut hatası: \(error.localizedDescription)"
                                }
                            }
                        case "screenshot":
                            self.analyzeScreen()
                            return "Ekran analizi başlatıldı."
                        case "audio":
                            self.toggleListening()
                            return "Sesli giriş başlatıldı."
                        case "clipboard":
                            self.toggleClipboard()
                            return "Pano dinleme başlatıldı."
                        case "system_status":
                            return await runToolCard(kind: "system_status", command: "Sistem durumu") {
                                await self.systemStatusSummary()
                            }
                        case "computer_list":
                            return await runToolCard(kind: "computer", command: "Uygulama listesi") {
                                await self.computerUseListApps()
                            }
                        case "computer_status":
                            return await runToolCard(kind: "computer", command: "Computer Use durumu") {
                                ComputerUseService.statusSummary()
                            }
                        case "computer_snapshot":
                            guard let target = self.computerUseResolveTarget(action) else {
                                return "Computer Use hedefi yok. Ön planda bir uygulama açın veya 'app'/'pid' belirtin."
                            }
                            return await runToolCard(kind: "computer", command: "Ekranı oku: \(target.appName) (pid \(target.pid))") {
                                await self.computerUseSnapshot(pid: target.pid)
                            }
                        case "computer_click":
                            guard allowMutations else { return "Computer Use tıklama onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let target = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let index = Int(action["index"] as? String ?? "") ?? -1
                            return await runToolCard(kind: "computer", command: "Tıkla #\(index) (\(target.appName))") {
                                await self.computerUseClick(pid: target.pid, index: index)
                            }
                        case "computer_type":
                            guard allowMutations else { return "Computer Use yazma onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let target = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let text = action["text"] as? String ?? ""
                            let pressKey = action["pressKey"] as? String
                            return await runToolCard(kind: "computer", command: "Yaz: \(text.prefix(30)) (\(target.appName))") {
                                await self.computerUseType(pid: target.pid, text: text, pressKey: pressKey)
                            }
                        case "computer_press":
                            guard allowMutations else { return "Computer Use tuş onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let target = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let key = action["key"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Tuş: \(key) (\(target.appName))") {
                                await self.computerUsePress(pid: target.pid, key: key)
                            }
                        case "computer_scroll":
                            guard allowMutations else { return "Computer Use kaydırma onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let target = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let x = Double(action["x"] as? String ?? "0") ?? 0
                            let y = Double(action["y"] as? String ?? "0") ?? 0
                            let amount = Int(action["amount"] as? String ?? "0") ?? 0
                            return await runToolCard(kind: "computer", command: "Kaydır \(amount)px (\(target.appName))") {
                                await self.computerUseScroll(pid: target.pid, x: CGFloat(x), y: CGFloat(y), amount: amount)
                            }
                        case "computer_clicktext":
                            guard allowMutations else { return "Computer Use metne tıklama onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let target = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let text = action["text"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Metne tıkla: \(text.prefix(30)) (\(target.appName))") {
                                await self.computerUseClickOnText(pid: target.pid, text: text)
                            }
                        case "computer_ocr":
                            let pid = Int(action["pid"] as? String ?? "") ?? 0
                            return await runToolCard(kind: "computer", command: "OCR oku (pid \(pid))") {
                                await self.computerUseOCR(pid: pid_t(pid))
                            }
                        case "computer_launch":
                            return await runToolCard(kind: "computer", command: "Başlat: \((action["name"] as? String ?? ""))") {
                                await self.computerUseLaunch(name: (action["name"] as? String ?? ""))
                            }
                        case "computer_interact":
                            guard allowMutations else { return "Computer Use etkileşim onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let resolved = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let targetText = action["target"] as? String
                            let index = Int(action["index"] as? String ?? "") ?? -1
                            let text = action["text"] as? String
                            let pressKey = action["pressKey"] as? String
                            return await runToolCard(kind: "computer", command: "Etkileşim: \(targetText ?? "#\(index)") (\(resolved.appName))") {
                                await self.computerUseInteract(
                                    pid: resolved.pid,
                                    target: targetText,
                                    index: index,
                                    text: text,
                                    pressKey: pressKey
                                )
                            }
                        case "computer_clicklabel":
                            guard allowMutations else { return "Computer Use etikete tıklama onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let resolved = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let label = action["target"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Etikete tıkla: \(label) (\(resolved.appName))") {
                                await self.computerUseClickLabel(pid: resolved.pid, target: label)
                            }
                        case "computer_inspect":
                            guard let resolved = self.computerUseResolveTarget(action) else {
                                return "Computer Use hedefi yok. Ön planda bir uygulama açın."
                            }
                            let label = action["target"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Hedefi incele: \(label) (\(resolved.appName))") {
                                await self.computerUseInspect(pid: resolved.pid, target: label)
                            }
                        case "computer_drag":
                            guard allowMutations else { return "Computer Use sürükleme onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let resolved = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let fromX = Double(action["fromX"] as? String ?? "0") ?? 0
                            let fromY = Double(action["fromY"] as? String ?? "0") ?? 0
                            let toX = Double(action["toX"] as? String ?? "0") ?? 0
                            let toY = Double(action["toY"] as? String ?? "0") ?? 0
                            return await runToolCard(kind: "computer", command: "Sürükle (\(resolved.appName))") {
                                await self.computerUseDrag(
                                    pid: resolved.pid,
                                    fromX: CGFloat(fromX),
                                    fromY: CGFloat(fromY),
                                    toX: CGFloat(toX),
                                    toY: CGFloat(toY)
                                )
                            }
                        case "computer_setvalue":
                            guard allowMutations else { return "Computer Use değer yazma onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let resolved = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let index = Int(action["index"] as? String ?? "") ?? -1
                            let value = action["value"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Değer yaz #\(index) (\(resolved.appName))") {
                                await self.computerUseSetValue(pid: resolved.pid, index: index, value: value)
                            }
                        case "computer_fill":
                            guard allowMutations else { return "Computer Use form doldurma onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let resolved = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let label = action["label"] as? String ?? ""
                            let value = action["value"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Doldur: \(label) (\(resolved.appName))") {
                                await self.computerUseFillField(pid: resolved.pid, label: label, value: value)
                            }
                        case "computer_submit":
                            guard allowMutations else { return "Computer Use gönderme onay gerektirir; önce kullanıcıya sormayı dene." }
                            guard let resolved = self.computerUseResolveTarget(action) else { return "Computer Use hedefi yok." }
                            let submitLabel = action["target"] as? String ?? "Kaydol"
                            return await runToolCard(kind: "computer", command: "Gönder: \(submitLabel) (\(resolved.appName))") {
                                await self.computerUseSubmit(pid: resolved.pid, submitLabel: submitLabel)
                            }
                        case "computer_wait":
                            guard let resolved = self.computerUseResolveTarget(action) else {
                                return "Computer Use hedefi yok. Ön planda bir uygulama açın."
                            }
                            let targetText = action["target"] as? String
                            let timeout = Double(action["timeout"] as? String ?? "5") ?? 5
                            return await runToolCard(kind: "computer", command: "Bekle: \(targetText ?? "...") (\(resolved.appName))") {
                                await self.computerUseWait(pid: resolved.pid, target: targetText, timeout: timeout)
                            }
                        case "browser_navigate":
                            return await runToolCard(kind: "computer", command: "Sayfa aç: \(((action["url"] as? String) ?? "").prefix(40))") {
                                await self.browserNavigate(url: (action["url"] as? String ?? ""))
                            }
                        case "browser_fill":
                            guard allowMutations else { return "Browser form doldurma onay gerektirir; önce kullanıcıya sormayı dene." }
                            let selector = action["selector"] as? String ?? ""
                            let value = action["value"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Doldur: \(selector)") {
                                await self.browserFill(selector: selector, value: value)
                            }
                        case "browser_click":
                            guard allowMutations else { return "Browser tıklama onay gerektirir; önce kullanıcıya sormayı dene." }
                            let selector = action["selector"] as? String ?? ""
                            return await runToolCard(kind: "computer", command: "Tıkla: \(selector)") {
                                await self.browserClick(selector: selector)
                            }
                        case "browser_audit":
                            return await runToolCard(kind: "computer", command: "Sayfa incele") {
                                await self.browserAudit()
                            }
                        case "file":
                            let operation = try parseFileActionJSON(action)
                            if allowMutations || operation.isReadOnly {
                                let commandLine = Self.fileOperationCommandLine(operation)
                                return await runToolCard(kind: "file", command: commandLine) {
                                    do {
                                        return try await self.executeFileSystemOperation(operation)
                                    } catch {
                                        return "Dosya hatası: \(error.localizedDescription)"
                                    }
                                }
                            }
                            return "Dosya mutasyonu onay gerektirir; önce kullanıcıya sormayı dene."
                        case "desktop":
                            if allowMutations {
                                return await runToolCard(kind: "applescript", command: "Masaüstü işlemi") {
                                    do {
                                        _ = try await self.zeroOperator.executeAppleScript(payload)
                                        return "Masaüstü işlemi tamamlandı."
                                    } catch {
                                        return "Masaüstü hatası: \(error.localizedDescription)"
                                    }
                                }
                            }
                            return "Masaüstü mutasyonu onay gerektirir."
                        case "applescript":
                            if allowMutations {
                                if let loop = action["loop"] as? [String: Any],
                                   let interval = loop["interval"] as? Double,
                                   let label = loop["label"] as? String {
                                    self.zeroOperator.startRecurringTask(script: payload, interval: interval, label: label)
                                    return "\(label) tekrarlayan görev başlatıldı."
                                } else {
                                    return await runToolCard(kind: "applescript", command: "AppleScript") {
                                        do {
                                            _ = try await self.zeroOperator.executeAppleScript(payload)
                                            return "AppleScript tamamlandı."
                                        } catch {
                                            return "AppleScript hatası: \(error.localizedDescription)"
                                        }
                                    }
                                }
                            }
                            return "AppleScript mutasyonu onay gerektirir."
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
                            let output = try await self.zeroOperator.executeShell(payload)
                            return output.isEmpty ? "Komut çalıştırıldı." : output
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

    /// `FileSystemOperation` öğesini sohbette gösterilecek kısa bir komut satırına çevirir.
    /// Örn. `.list(path: "/Desktop")` → "ls /Desktop".
    private static func fileOperationCommandLine(_ operation: FileSystemOperation) -> String {
        switch operation {
        case .pwd:
            return "pwd"
        case .list(let path):
            return "ls \(path)"
        case .read(let path):
            return "cat \(path)"
        case .makeDirectory(let path):
            return "mkdir \(path)"
        case .createFile(let path):
            return "touch \(path)"
        case .write(let path, _, _):
            return "write \(path)"
        case .move(let source, let destination):
            return "mv \(source) \(destination)"
        case .replace(let path, _, _):
            return "replace in \(path ?? "")"
        case .replaceDirectory(let path, _, _):
            return "replace dir \(path)"
        case .context:
            return "context"
        case .sudo(let command):
            return "sudo \(command)"
        }
    }

    /// Sistem durumu özetini döndürür. `[ACTION: {"type":"system_status"}]`
    /// ajan çağrısında kullanılır; CPU/RAM/uygulama/ses bilgisini kompakt verir.
    private func systemStatusSummary() async -> String {
        let service = SystemStatusService()
        return await service.getSystemContextSummary()
    }

    /// Bilgi/eylem araçlarını sohbette **streaming kart** olarak gösterir:
    /// önce "Çalışıyor + shimmer" kartı basılır, sonuç gelince aynı kart
    /// "Başarılı + çıktı"ya dönüştürülür, hata olursa "Hata" gösterilir.
    /// Böylece computer-use ve diğer tool işlemleri düz metin değil, görsel
    /// bir kart olarak akar. `kind` ikon/keyword, `command` görünen başlıktır.
    private func runToolCard(
        kind: String,
        command: String,
        _ action: @escaping () async -> String
    ) async -> String {
        let toolMessageID = UUID()
        messages.append(
            ChatMessage(
                id: toolMessageID,
                text: command,
                isUser: false,
                type: .text,
                toolRun: ChatMessage.ToolRun(
                    kind: kind,
                    command: command,
                    status: .running,
                    output: ""
                )
            )
        )
        let toolIndex = messages.count - 1

        let result = await action()
        // Çok hızlı biten işlemlerde bile "çalışıyor" animasyonu en az ~0.4s
        // görünsün ki kullanıcı streaming hissini algılasın.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let lower = result.lowercased()
        let looksLikeError = result.hasPrefix("hata") ||
            lower.contains("hatası") ||
            lower.contains("başarısız") ||
            lower.contains("engellendi") ||
            lower.contains("bulunamadı") ||
            lower.contains("gerekli")
        let status: ChatMessage.ToolRun.Status = looksLikeError ? .error(result) : .done

        var updated = messages[toolIndex]
        updated = ChatMessage(
            id: toolMessageID,
            text: command,
            isUser: false,
            type: .text,
            toolRun: ChatMessage.ToolRun(
                kind: kind,
                command: command,
                status: status,
                output: result
            )
        )
        messages[toolIndex] = updated
        return result
    }

    // MARK: - Computer Use Eylemleri

    /// Çalışan uygulamaları listeler; ajan hangi uygulamayı kontrol edeceğine karar verir.
    private func computerUseListApps() async -> String {
        let apps = ComputerUseService.listRunningApps()
        guard !apps.isEmpty else { return "Çalışan uygulama bulunamadı." }
        let lines = apps.prefix(40).enumerated().map { idx, app in
            "\(idx + 1). \(app.name) (pid \(app.pid))"
        }
        return "Çalışan uygulamalar:\n" + lines.joined(separator: "\n")
    }

    /// Eylem JSON'ından PID çözer. `pid` yoksa/0 ise ÖN PLANDAKİ uygulamayı
    /// hedefler (uygulama-bağımsız kullanım). Ajan her zaman pid vermek zorunda
    /// kalmaz — "şu an ekrandaki ne varsa onu yap" çalışır.
    private func computerUsePid(from action: [String: Any]) -> pid_t {
        let raw = (action["pid"] as? NSNumber)?.intValue
            ?? (Int(action["pid"] as? String ?? "") ?? 0)
        if raw > 0 { return pid_t(raw) }
        return ComputerUseService.frontmostApp()?.pid ?? 0
    }

    /// Hedef uygulama adı da olabilir (ör. "Safari", "Chrome"). Ad verilirse
    /// ona göre, yoksa pid/ön plan mantığıyla çözer.
    private func computerUseResolveTarget(_ action: [String: Any]) -> (pid: pid_t, appName: String)? {
        if let name = (action["app"] as? String), !name.isEmpty,
           let app = ComputerUseService.findApp(named: name) {
            return (app.pid, app.name)
        }
        let pid = computerUsePid(from: action)
        guard pid > 0 else { return nil }
        let name = ComputerUseService.listRunningApps().first(where: { $0.pid == pid })?.name ?? "?"
        return (pid, name)
    }

    /// Hedef uygulamanın etkileşimli öğelerini (AX ağacı) döndürür.
    private func computerUseSnapshot(pid: pid_t) async -> String {
        // AX ağacı çoğu uygulamada yeterlidir; OCR geri dönüşü için ekran
        // görüntüsü ScreenCaptureKit ile alınır (arka plan, ReplayKit yan etkisi yok).
        let screenImage = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
        let observation = await computerUseService.snapshot(pid: pid, screenImage: screenImage)
        return observation.summary
    }

    /// Bir öğeye veya koordinata tıklar (arka plan güvenli, odak çalmaz).
    private func computerUseClick(pid: pid_t, index: Int) async -> String {
        do {
            if index >= 0 {
                let result = try await computerUseService.clickElement(pid: pid, index: index)
                return result.changed
                    ? "\(result.message)\n\nDoğrulama (değişti):\n\(result.changedDescription)"
                    : "\(result.message)\n\nDoğrulama: Ağaçta görünür değişiklik oluşmadı. (Bir sonraki kademe veya farklı öğe deneyin)"
            }
            return "Geçerli bir öğe indeksi gerekli. Önce computer_snapshot ile alın."
        } catch {
            return "Tıklama hatası: \(error.localizedDescription)"
        }
    }

    /// Hedef uygulamaya metin yazar.
    private func computerUseType(pid: pid_t, text: String, pressKey: String? = nil) async -> String {
        do {
            return try await computerUseService.typeText(text, pid: pid, pressKey: pressKey)
        } catch {
            return "Yazma hatası: \(error.localizedDescription)"
        }
    }

    /// Hedef uygulamaya klavye kısayolu gönderir.
    private func computerUsePress(pid: pid_t, key: String) async -> String {
        do {
            return try await computerUseService.pressKey(key, pid: pid)
        } catch {
            return "Tuş hatası: \(error.localizedDescription)"
        }
    }

    /// Hedef uygulamada kaydırma yapar.
    private func computerUseScroll(pid: pid_t, x: CGFloat, y: CGFloat, amount: Int) async -> String {
        do {
            return try await computerUseService.scroll(pid: pid, x: x, y: y, amount: amount)
        } catch {
            return "Kaydırma hatası: \(error.localizedDescription)"
        }
    }

    /// Ekranda OCR ile bulunan bir metne tıklar (canvas/Electron fallback).
    private func computerUseClickOnText(pid: pid_t, text: String) async -> String {
        let screenImage = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
        do {
            return try await computerUseService.clickOnText(text, pid: pid, screenImage: screenImage)
        } catch {
            return "Metne tıklama hatası: \(error.localizedDescription)"
        }
    }

    /// Hedef uygulamanın görünür metinlerini OCR ile listeler.
    private func computerUseOCR(pid: pid_t) async -> String {
        let screenImage = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
        guard let screenImage else { return "Ekran görüntüsü alınamadı." }
        let lines = ComputerUseService.ocrTextLines(in: screenImage)
        guard !lines.isEmpty else { return "Ekranda görünür metin bulunamadı." }
        return "Görünür metin:\n" + lines.map(\.line).joined(separator: "\n")
    }

    /// Uygulama başlatır veya öne getirir; PID'ini döndürür.
    private func computerUseLaunch(name: String) async -> String {
        guard !name.isEmpty else { return "Uygulama adı gerekli." }
        guard let result = ComputerUseService.activateOrLaunch(named: name) else {
            return "Uygulama başlatılamadı: \(name)"
        }
        let action = result.launched ? "başlatıldı" : "öne getirildi"
        return "\(name) \(action) (pid \(result.pid)). Artık computer_snapshot ile bu pid üzerinden çalışabilirsin."
    }

    /// Zincirli etkileşim: tıkla → yaz → tuş bas (tek çağrıda).
    private func computerUseInteract(
        pid: pid_t,
        target: String?,
        index: Int,
        text: String?,
        pressKey: String?
    ) async -> String {
        do {
            let result = try await computerUseService.interact(
                pid: pid,
                targetText: target,
                index: index >= 0 ? index : nil,
                type: text,
                pressKey: pressKey
            )
            return result.changed
                ? "\(result.message)\n\nDoğrulama (değişti):\n\(result.changedDescription)"
                : "\(result.message)\n\nDoğrulama: Görünür değişiklik oluşmadı."
        } catch {
            return "Etkileşim hatası: \(error.localizedDescription)"
        }
    }

    /// AX etiketine göre tıkla (indeks ezberlemeden).
    private func computerUseClickLabel(pid: pid_t, target: String) async -> String {
        do {
            // Tarayıcı web içeriği için OCR koordinatı güvenilir; o yüzden ekran
            // görüntüsünü alıp hem AX hem OCR yoluna besliyoruz.
            let image = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
            let result = try await computerUseService.clickElementByText(pid: pid, text: target, screenImage: image)
            return result.changed
                ? "\(result.message)\n\nDoğrulama (değişti):\n\(result.changedDescription)"
                : "\(result.message)\n\nDoğrulama: Görünür değişiklik oluşmadı."
        } catch {
            return "Etikete tıklama hatası: \(error.localizedDescription)"
        }
    }

    /// Bir noktadan diğerine sürükle.
    private func computerUseDrag(pid: pid_t, fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) async -> String {
        do {
            return try await computerUseService.drag(pid: pid, fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        } catch {
            return "Sürükleme hatası: \(error.localizedDescription)"
        }
    }

    /// Bir metin alanına AXValue ile değer yazar (güvenli/sandbox alanlar için).
    private func computerUseSetValue(pid: pid_t, index: Int, value: String) async -> String {
        do {
            return try await computerUseService.setValue(value, pid: pid, index: index)
        } catch {
            return "Değer yazma hatası: \(error.localizedDescription)"
        }
    }

    /// Form alanını etiketiyle doldurur (tarayıcı/web formları için).
    private func computerUseFillField(pid: pid_t, label: String, value: String) async -> String {
        do {
            return try await computerUseService.fillField(label: label, value: value, pid: pid)
        } catch {
            return "Form doldurma hatası: \(error.localizedDescription)"
        }
    }

    /// Tarayıcı formunu gönderir (OCR tıkla → yoksa klavye Tab+Return).
    private func computerUseSubmit(pid: pid_t, submitLabel: String) async -> String {
        let image = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
        do {
            return try await computerUseService.submitBrowserForm(pid: pid, submitLabel: submitLabel, screenImage: image)
        } catch {
            return "Form gönderme hatası: \(error.localizedDescription)"
        }
    }

    /// UI'ın oturmasını bekler (poll tabanlı doğrulama).
    private func computerUseWait(pid: pid_t, target: String?, timeout: Double) async -> String {
        do {
            return try await computerUseService.waitFor(pid: pid, targetText: target, timeout: timeout)
        } catch {
            return "Bekleme hatası: \(error.localizedDescription)"
        }
    }

    // MARK: - Browser CDP (native hız DOM kontrolü)

    /// Sayfayı CDP ile açar (gerekirse Chrome'u başlatır).
    private func browserNavigate(url: String) async -> String {
        do {
            guard !url.isEmpty else { return "URL gerekli." }
            try await browserCDPService.launch(port: 9333, url: url)
            return "Sayfa açıldı: \(url)"
        } catch {
            return "Sayfa açma hatası: \(error.localizedDescription)"
        }
    }

    /// DOM seçicisiyle form alanını doldurur (native hız).
    private func browserFill(selector: String, value: String) async -> String {
        do {
            return try await browserCDPService.fillField(selector: selector, value: value)
        } catch {
            // CDP DOM yolu henüz deneysel; kanıtlanmış AX/OCR yoluna yönlendir.
            return "CDP form doldurma şu an deneyimsel (\(error.localizedDescription)). Güvenilir yol: computer_fill (etikete göre AXValue) veya computer_type."
        }
    }

    /// DOM seçicisiyle butona tıklar.
    private func browserClick(selector: String) async -> String {
        do {
            return try await browserCDPService.click(selector: selector)
        } catch {
            return "CDP tıklama şu an deneyimsel (\(error.localizedDescription)). Güvenilir yol: computer_clicklabel (OCR) veya computer_submit."
        }
    }

    /// Sayfanın form/buton DOM özetini döndürür.
    private func browserAudit() async -> String {
        do {
            return try await browserCDPService.auditPage()
        } catch {
            return "CDP sayfa inceleme şu an deneyimsel (\(error.localizedDescription)). Yerine computer_snapshot kullanın."
        }
    }

    /// Bir hedef metni hangi kaynaktan, ne güvenle bulunduğunu raporlar.
    /// Ajan, tıklamadan önce belirsizlik varsa bunu kullanıcıya söyleyebilir.
    private func computerUseInspect(pid: pid_t, target: String) async -> String {
        let image = await visionService.captureScreen(under: NSApp.windows.first ?? NSWindow())
        let report = computerUseService.resolveNamedTarget(target, pid: pid, screenImage: image)
        return report.summary
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

    /// Builds a `FileSystemOperation` from a model-emitted `[ACTION]` JSON object.
    /// The model can request `type: "file"` with an `operation` key that maps to
    /// one of the known file-system verbs already supported by the sandbox.
    private func parseFileActionJSON(_ action: [String: Any]) throws -> FileSystemOperation {
        let operation = (action["operation"] as? String ?? "").lowercased()
        let path = action["path"] as? String ?? ""
        let target = action["target"] as? String ?? ""
        let source = action["source"] as? String ?? ""
        let content = action["content"] as? String ?? ""
        let find = action["find"] as? String ?? ""
        let replace = action["replace"] as? String ?? ""
        let append = (action["append"] as? Bool) ?? false

        switch operation {
        case "pwd":
            return .pwd
        case "list", "ls":
            return .list(path: path)
        case "read", "cat":
            return .read(path: path)
        case "mkdir", "mkdirs":
            return .makeDirectory(path: path)
        case "touch", "create":
            return .createFile(path: path)
        case "write", "append":
            return .write(path: path, content: content, append: append)
        case "move", "mv":
            return .move(source: source.isEmpty ? path : source, destination: target)
        case "replace":
            return .replace(path: path.isEmpty ? nil : path, find: find, replace: replace)
        case "context":
            return .context
        default:
            throw SlashCommandError.unsupported("Bilinmeyen dosya eylemi: \(operation)")
        }
    }
}
