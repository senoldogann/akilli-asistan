import AppKit
import Combine
import Foundation
import Observation
import PDFKit

enum V2RuntimeCommandError: Error, Equatable {
    case unsupportedCommand(String)
}

/// Main application runtime used by the SwiftUI shell after the V2 cutover.
///
/// This controller intentionally owns no physical-input, shell, AppleScript, or
/// browser mutation primitive. Model generation is informational by default;
/// mutation-capable work must enter through ToolFabric and its policy boundary.
@MainActor
final class V2ShellRuntimeController: RuntimeCommandControlling, ShellFeatureControlling, @unchecked Sendable {
    private let intelligenceService: IntelligenceService
    private let visionService: VisionService
    private let clipboardService: ClipboardService
    private let screenshotWatcher: ScreenshotWatcherService
    private let audioService: AudioService
    private let documentProcessor: DocumentProcessor
    private let embeddingService: OllamaEmbeddingService
    private let vectorStore: VectorStore
    private let chatHistoryService: ChatHistoryService
    private let nativeToolRuntime: V2NativeToolRuntime
    private let responseCacheService: ResponseCacheService
    private let requestCoordinator: RequestCoordinator
    private let attachmentContextProvider: any MutableAttachmentContextProviding
    private let modelIDProvider: () -> String

    private weak var shellViewModel: ShellViewModel?
    private var activeTask: Task<Void, Never>?
    private var messages: [ChatMessage] = []
    private var isBusy = false
    private var statusMessage = "Ready"
    private var isClipboardActive = false
    private var isListeningActive = false
    private var liveVoicePreview = ""
    private var attachedFileData: Data?
    private var attachedFileName: String?
    private var attachedExtractedText: String?
    private var isIndexing = false
    private var authorityMode: AuthorityMode
    private var askConversationID = UUID().uuidString
    private var activeAskSessionID: ModelSessionID?
    var onAuthorityModeChanged: ((AuthorityMode) -> Void)?

    init(
        intelligenceService: IntelligenceService,
        visionService: VisionService,
        clipboardService: ClipboardService,
        screenshotWatcher: ScreenshotWatcherService,
        audioService: AudioService,
        documentProcessor: DocumentProcessor,
        embeddingService: OllamaEmbeddingService,
        vectorStore: VectorStore,
        chatHistoryService: ChatHistoryService,
        nativeToolRuntime: V2NativeToolRuntime,
        requestCoordinator: RequestCoordinator,
        attachmentContextProvider: any MutableAttachmentContextProviding,
        modelIDProvider: @escaping () -> String,
        initialAuthorityMode: AuthorityMode
    ) {
        self.intelligenceService = intelligenceService
        self.visionService = visionService
        self.clipboardService = clipboardService
        self.screenshotWatcher = screenshotWatcher
        self.audioService = audioService
        self.documentProcessor = documentProcessor
        self.embeddingService = embeddingService
        self.vectorStore = vectorStore
        self.chatHistoryService = chatHistoryService
        self.nativeToolRuntime = nativeToolRuntime
        self.responseCacheService = .shared
        self.requestCoordinator = requestCoordinator
        self.attachmentContextProvider = attachmentContextProvider
        self.modelIDProvider = modelIDProvider
        self.authorityMode = initialAuthorityMode
        installObservations()
    }

    func bind(to viewModel: ShellViewModel) {
        shellViewModel = viewModel
        publishSnapshot()
    }

    // MARK: - RuntimeCommandControlling

    func submitUserGoal(_ text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        throw V2RuntimeCommandError.unsupportedCommand("autonomous-goal-runtime-not-configured")
    }

    func sendChatMessage(_ text: String) async throws {
        try await processAsk(text, source: "V2 Chat")
    }

    func pauseGoal(_ goalID: GoalID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("pause:\(goalID.rawValue)")
    }

    func resumeGoal(_ goalID: GoalID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("resume:\(goalID.rawValue)")
    }

    func cancelGoal(_ goalID: GoalID) async throws {
        stopResponse()
    }

    func approveInvocation(_ invocationID: InvocationID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("approve:\(invocationID.rawValue)")
    }

    func denyInvocation(_ invocationID: InvocationID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("deny:\(invocationID.rawValue)")
    }

    func changeAuthorityMode(_ mode: AuthorityMode) async throws {
        guard mode != .fullAccess else {
            throw V2RuntimeCommandError.unsupportedCommand("full-access")
        }
        await nativeToolRuntime.setAuthorityMode(mode)
        authorityMode = mode
        onAuthorityModeChanged?(mode)
    }

    // MARK: - ShellFeatureControlling

    func clearHistory() {
        activeTask?.cancel()
        activeTask = nil
        let previousConversationID = askConversationID
        askConversationID = UUID().uuidString
        activeAskSessionID = nil
        messages.removeAll()
        intelligenceService.clearHistory()
        Task {
            await attachmentContextProvider.clearAttachments(conversationID: previousConversationID)
        }
        attachedExtractedText = nil
        attachedFileData = nil
        attachedFileName = nil
        statusMessage = "History Cleared."
        publishSnapshot()
    }

    func toggleClipboard() {
        isClipboardActive.toggle()
        statusMessage = isClipboardActive ? "Clipboard: ON" : "Clipboard: OFF"
        publishSnapshot()
    }

    func toggleListening() {
        if audioService.isListening {
            audioService.stopListening()
            isListeningActive = false
            statusMessage = "Listening Stopped"
        } else {
            audioService.startListening()
            isListeningActive = true
            statusMessage = "Listening (Gatekeeper Active)..."
        }
        publishSnapshot()
    }

    func stopResponse() {
        guard isBusy else { return }
        activeTask?.cancel()
        activeTask = nil
        if let sessionID = activeAskSessionID {
            Task {
                await requestCoordinator.cancel(sessionID: sessionID)
            }
        }
        activeAskSessionID = nil
        isBusy = false
        statusMessage = "Interrupted"

        if let index = messages.indices.last,
           !messages[index].isUser,
           messages[index].type == .thinking {
            let previous = messages[index]
            messages[index] = ChatMessage(
                id: previous.id,
                text: previous.text == "Thinking..." ? "[Stopped by user]" : previous.text + " [Stopped by user]",
                isUser: false,
                type: .text,
                assistantOrigin: previous.assistantOrigin,
                relatedQuery: previous.relatedQuery,
                thinking: previous.thinking
            )
        }
        publishSnapshot()
    }

    func submitQuery(_ text: String, webSearchMode: WebSearchMode) {
        if attachedExtractedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            startTask { [weak self] in
                guard let self else { return }
                do {
                    try await self.processAsk(text, source: "V2 Shell")
                } catch is CancellationError {
                    self.finishCancelledTask()
                } catch {
                    self.appendRuntimeError(error)
                }
            }
            return
        }

        let attachment = attachedFileData
        if let attachment {
            let source = attachedFileName ?? "Attachment"
            attachedFileData = nil
            attachedFileName = nil
            publishSnapshot()
            startTask { [weak self] in
                guard let self else { return }
                await self.processImage(attachment, source: source, query: text)
            }
            return
        }

        startTask { [weak self] in
            guard let self else { return }
            do {
                try await self.processAsk(text, source: "V2 Shell")
            } catch is CancellationError {
                self.finishCancelledTask()
            } catch {
                self.appendRuntimeError(error)
            }
        }
    }

    func refineAnswer(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
              message.allowsAIRefinement,
              let query = message.relatedQuery else {
            return
        }

        startTask { [weak self] in
            guard let self else { return }
            do {
                try await self.processText(
                    query,
                    source: "V2 AI Refine",
                    processingMode: .forceAIReasoning,
                    showUserMessage: false,
                    targetAssistantMessageID: messageID
                )
            } catch is CancellationError {
                self.finishCancelledTask()
            } catch {
                self.appendRuntimeError(error)
            }
        }
    }

    func clearAttachment() {
        attachedFileData = nil
        attachedFileName = nil
        attachedExtractedText = nil
        let conversationID = askConversationID
        Task {
            await attachmentContextProvider.clearAttachments(conversationID: conversationID)
        }
        publishSnapshot()
    }

    func attachFile(from url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf":
            attachPDF(from: url)
        default:
            do {
                let data = try Data(contentsOf: url)
                attachedFileData = data
                attachedFileName = url.lastPathComponent
                if let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    attachedExtractedText = text
                } else {
                    attachedExtractedText = nil
                }
                statusMessage = "Attachment ready"
            } catch {
                statusMessage = "Attachment failed: \(error.localizedDescription)"
            }
            publishSnapshot()
        }
    }

    func analyzeScreen() {
        guard !isBusy else { return }
        startTask { [weak self] in
            guard let self else { return }
            self.isBusy = true
            self.statusMessage = "Capturing..."
            self.publishSnapshot()

            guard let image = await self.visionService.captureScreen(under: NSApp.windows.first ?? NSWindow()),
                  let data = Self.jpegData(from: image) else {
                self.isBusy = false
                self.statusMessage = "Capture Failed"
                self.publishSnapshot()
                return
            }
            await self.processImage(data, source: "Screen Capture", query: nil)
        }
    }

    @discardableResult
    func warmUpInterviewContext() -> String {
        let activeRoleContext = ActiveRoleProfileService.warmUpContext(
            for: ActiveRoleProfileService.currentProfile()
        )
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

        guard !allItems.isEmpty || !noteCacheEntries.isEmpty else {
            intelligenceService.setTransientPersonaContext(baseContext)
            statusMessage = "⚠️ Vault ve Interview Notes boş. Sadece temel interview context yüklendi."
            publishSnapshot()
            return statusMessage
        }

        responseCacheService.clearCache()
        let vaultEntries = allItems.map { entry in
            ResponseCacheService.InterviewCacheEntry(
                question: entry.item.question,
                answer: entry.item.answerFinnish,
                category: entry.category,
                translation: entry.item.translationTr,
                keyPoints: entry.item.keyPoints
            )
        }
        _ = responseCacheService.primeInterviewVault(entries: vaultEntries)
        _ = responseCacheService.primeInterviewVault(entries: noteCacheEntries)

        let coverageEntries = allItems.map {
            (question: $0.item.question, answer: $0.item.answerFinnish, category: $0.category)
        } + noteCacheEntries
        let coverage = responseCacheService.interviewVaultCoverage(entries: coverageEntries)
        let categoryTitles = categories.map(\.title).joined(separator: ", ")
        let notesSummary = noteCacheEntries.isEmpty
            ? "No interview notes cached"
            : "Interview Notes cached: \(noteCacheEntries.count)"
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
        statusMessage = coverage.missing == 0
            ? "🔥 Warm-up tamam: cache doğrulandı \(coverage.cached)/\(coverage.total)."
            : "⚠️ Warm-up kısmi: cache \(coverage.cached)/\(coverage.total), eksik \(coverage.missing)."
        publishSnapshot()
        return statusMessage
    }

    nonisolated static func userDefaultsBool(_ key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    // MARK: - Processing

    private func processAsk(_ text: String, source _: String) async throws {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard !isBusy else {
            throw V2RuntimeCommandError.unsupportedCommand("concurrent-chat")
        }

        isBusy = true
        statusMessage = "Thinking..."
        messages.append(ChatMessage(text: query, isUser: true, type: .text))
        let assistantID = UUID()
        messages.append(
            ChatMessage(
                id: assistantID,
                text: "Thinking...",
                isUser: false,
                type: .thinking,
                relatedQuery: query
            )
        )
        let assistantIndex = messages.count - 1
        publishSnapshot()

        let conversationID = askConversationID
        let sessionID = ModelSessionID(rawValue: UUID().uuidString)
        activeAskSessionID = sessionID
        let hadAttachmentContext = await stageAttachmentContextIfNeeded(conversationID: conversationID)
        if hadAttachmentContext {
            attachedFileData = nil
            attachedFileName = nil
            attachedExtractedText = nil
            publishSnapshot()
        }

        do {
            let request = AskRequest(
                sessionID: sessionID,
                conversationID: conversationID,
                text: query,
                modelID: modelIDProvider(),
                activeGoalID: nil
            )
            let stream = await requestCoordinator.stream(request)
            var responseText = ""
            var completed = false

            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .started:
                    statusMessage = "Thinking..."
                    publishSnapshot()
                case .textDelta(let delta):
                    responseText += delta
                    updateAssistantMessage(
                        at: assistantIndex,
                        id: assistantID,
                        text: responseText,
                        type: .thinking,
                        origin: .aiGenerated,
                        relatedQuery: query,
                        thinking: nil
                    )
                case .toolCall:
                    break
                case .completed:
                    completed = true
                }
            }

            try Task.checkCancellation()
            if completed {
                updateAssistantMessage(
                    at: assistantIndex,
                    id: assistantID,
                    text: responseText.isEmpty ? "[No response]" : responseText,
                    type: .text,
                    origin: .aiGenerated,
                    relatedQuery: query,
                    thinking: nil
                )
            }
            await attachmentContextProvider.clearAttachments(conversationID: conversationID)
            if activeAskSessionID == sessionID {
                activeAskSessionID = nil
            }
            isBusy = false
            statusMessage = "Ready"
            activeTask = nil
            publishSnapshot()
        } catch {
            await attachmentContextProvider.clearAttachments(conversationID: conversationID)
            if activeAskSessionID == sessionID {
                activeAskSessionID = nil
            }
            isBusy = false
            activeTask = nil
            let cancelled = error is CancellationError || Task.isCancelled || Self.isProviderCancellation(error)
            statusMessage = cancelled ? "Stopped" : "Error"
            if messages.indices.contains(assistantIndex) {
                let existing = messages[assistantIndex]
                messages[assistantIndex] = ChatMessage(
                    id: existing.id,
                    text: cancelled ? "[Stopped by user]" : "Error: \(error.localizedDescription)",
                    isUser: false,
                    type: cancelled ? .text : .error,
                    assistantOrigin: cancelled ? existing.assistantOrigin : nil,
                    relatedQuery: query
                )
            }
            publishSnapshot()
            throw error
        }
    }

    private func stageAttachmentContextIfNeeded(conversationID: String) async -> Bool {
        guard let extractedText = attachedExtractedText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !extractedText.isEmpty else {
            await attachmentContextProvider.clearAttachments(conversationID: conversationID)
            return false
        }

        await attachmentContextProvider.replaceAttachments(
            [
                AttachmentContextSnapshot(
                    id: UUID().uuidString,
                    displayName: attachedFileName ?? "Attachment",
                    extractedText: extractedText,
                    recordedAt: Date()
                )
            ],
            conversationID: conversationID
        )
        return true
    }

    private func processText(
        _ text: String,
        source: String,
        webSearchMode: WebSearchMode = .automatic,
        processingMode: IntelligenceService.ProcessingMode = .automatic,
        showUserMessage: Bool = true,
        targetAssistantMessageID: UUID? = nil
    ) async throws {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard !isBusy || targetAssistantMessageID != nil else {
            throw V2RuntimeCommandError.unsupportedCommand("concurrent-chat")
        }

        isBusy = true
        statusMessage = "Thinking..."
        if showUserMessage {
            messages.append(ChatMessage(text: query, isUser: true, type: .text))
            try? await chatHistoryService.addMessage(text: query, isUser: true)
        }

        let assistantID = targetAssistantMessageID ?? UUID()
        let assistantIndex: Int
        if let targetAssistantMessageID,
           let existingIndex = messages.firstIndex(where: { $0.id == targetAssistantMessageID }) {
            assistantIndex = existingIndex
            let existing = messages[existingIndex]
            messages[existingIndex] = ChatMessage(
                id: existing.id,
                text: "Thinking...",
                isUser: false,
                type: .thinking,
                assistantOrigin: existing.assistantOrigin,
                relatedQuery: query
            )
        } else {
            messages.append(
                ChatMessage(
                    id: assistantID,
                    text: "Thinking...",
                    isUser: false,
                    type: .thinking,
                    relatedQuery: query
                )
            )
            assistantIndex = messages.count - 1
        }
        publishSnapshot()

        do {
            let toolConfiguration = await nativeToolRuntime.configuration()
            let response = try await intelligenceService.process(
                query: query,
                webSearchMode: webSearchMode,
                processingMode: processingMode,
                nativeTools: toolConfiguration.tools,
                nativeToolExecutor: toolConfiguration.executor,
                onStatusUpdate: { [weak self] status in
                    Task { @MainActor in
                        self?.statusMessage = status
                        self?.publishSnapshot()
                    }
                },
                onPartialResponse: { [weak self] partial in
                    Task { @MainActor in
                        self?.updateAssistantMessage(
                            at: assistantIndex,
                            id: assistantID,
                            text: partial,
                            type: .thinking,
                            origin: nil,
                            relatedQuery: query,
                            thinking: nil
                        )
                    }
                }
            )

            updateAssistantMessage(
                at: assistantIndex,
                id: assistantID,
                text: response.text,
                type: .text,
                origin: Self.assistantOrigin(for: response.origin),
                relatedQuery: query,
                thinking: response.thinking
            )
            try? await chatHistoryService.addMessage(text: response.text, isUser: false)
            isBusy = false
            statusMessage = "Ready"
            activeTask = nil
            publishSnapshot()
        } catch {
            isBusy = false
            activeTask = nil
            statusMessage = error is CancellationError ? "Stopped" : "Error"
            if messages.indices.contains(assistantIndex) {
                let existing = messages[assistantIndex]
                messages[assistantIndex] = ChatMessage(
                    id: existing.id,
                    text: error is CancellationError ? "[Stopped by user]" : "Error: \(error.localizedDescription)",
                    isUser: false,
                    type: error is CancellationError ? .text : .error,
                    relatedQuery: query
                )
            }
            publishSnapshot()
            throw error
        }
    }

    private func processImage(_ data: Data, source: String, query: String?) async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Analyzing \(source)..."
        let userText = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuery = (userText?.isEmpty == false ? userText! : "Analyze this image. Identify technical content and provide solutions.")
        messages.append(
            ChatMessage(
                text: userText?.isEmpty == false ? userText! : "[Analyzing Image: \(source)]",
                isUser: true,
                type: .image,
                imageData: data
            )
        )
        messages.append(ChatMessage(text: "Scanning...", isUser: false, type: .thinking, relatedQuery: resolvedQuery))
        let assistantIndex = messages.count - 1
        let assistantID = messages[assistantIndex].id
        publishSnapshot()

        do {
            let toolConfiguration = await nativeToolRuntime.configuration()
            let response = try await intelligenceService.process(
                query: resolvedQuery,
                imageData: data,
                nativeTools: toolConfiguration.tools,
                nativeToolExecutor: toolConfiguration.executor,
                onStatusUpdate: { [weak self] status in
                    Task { @MainActor in
                        self?.statusMessage = status
                        self?.publishSnapshot()
                    }
                },
                onPartialResponse: { [weak self] partial in
                    Task { @MainActor in
                        self?.updateAssistantMessage(
                            at: assistantIndex,
                            id: assistantID,
                            text: partial,
                            type: .thinking,
                            origin: nil,
                            relatedQuery: resolvedQuery,
                            thinking: nil
                        )
                    }
                }
            )
            updateAssistantMessage(
                at: assistantIndex,
                id: assistantID,
                text: response.text,
                type: .text,
                origin: Self.assistantOrigin(for: response.origin),
                relatedQuery: resolvedQuery,
                thinking: response.thinking
            )
            try? await chatHistoryService.addMessage(text: response.text, isUser: false)
            statusMessage = "Ready"
        } catch is CancellationError {
            statusMessage = "Stopped"
        } catch {
            updateAssistantMessage(
                at: assistantIndex,
                id: assistantID,
                text: "Error: \(error.localizedDescription)",
                type: .error,
                origin: nil,
                relatedQuery: resolvedQuery,
                thinking: nil
            )
            statusMessage = "Error"
        }
        isBusy = false
        activeTask = nil
        publishSnapshot()
    }

    private func updateAssistantMessage(
        at index: Int,
        id: UUID,
        text: String,
        type: ChatMessage.MessageType,
        origin: ChatMessage.AssistantOrigin?,
        relatedQuery: String?,
        thinking: String?
    ) {
        guard messages.indices.contains(index), messages[index].id == id else { return }
        messages[index] = ChatMessage(
            id: id,
            text: text,
            isUser: false,
            type: type,
            assistantOrigin: origin,
            relatedQuery: relatedQuery,
            thinking: thinking
        )
        publishSnapshot()
    }

    private func appendRuntimeError(_ error: Error) {
        isBusy = false
        statusMessage = "Error"
        messages.append(
            ChatMessage(
                text: "Error: \(error.localizedDescription)",
                isUser: false,
                type: .error
            )
        )
        publishSnapshot()
    }

    private func finishCancelledTask() {
        isBusy = false
        statusMessage = "Stopped"
        activeTask = nil
        publishSnapshot()
    }

    private func startTask(_ operation: @escaping @MainActor () async -> Void) {
        guard activeTask == nil || activeTask?.isCancelled == true else { return }
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.activeTask = nil
        }
        activeTask = task
    }

    // MARK: - Attachments and observations

    private func attachPDF(from url: URL) {
        guard let pdfDocument = PDFDocument(url: url) else {
            statusMessage = "Failed to load PDF"
            publishSnapshot()
            return
        }

        attachedExtractedText = (0..<pdfDocument.pageCount)
            .compactMap { pdfDocument.page(at: $0)?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let page = pdfDocument.page(at: 0) {
            let rect = page.bounds(for: .mediaBox)
            let thumbnail = page.thumbnail(
                of: CGSize(width: rect.width * 2, height: rect.height * 2),
                for: .mediaBox
            )
            attachedFileData = Self.jpegData(from: thumbnail)
            attachedFileName = url.lastPathComponent + " (Page 1 Visual)"
        }
        publishSnapshot()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isIndexing = true
            self.statusMessage = "📄 Indexing PDF to memory..."
            self.publishSnapshot()
            do {
                let chunks = try await self.documentProcessor.processPDF(url: url)
                for chunk in chunks {
                    let embedding = try await self.embeddingService.embedSingle(text: chunk.text)
                    try await self.vectorStore.insert(chunk: chunk, embedding: embedding)
                }
                self.statusMessage = "✅ PDF indexed: \(chunks.count) chunks"
            } catch {
                self.statusMessage = "⚠️ PDF indexing failed: \(error.localizedDescription)"
            }
            self.isIndexing = false
            self.publishSnapshot()
        }
    }

    private func installObservations() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await transcript in self.audioService.$lastVoiceTranscript.values {
                guard !Task.isCancelled, !transcript.isEmpty else { continue }
                self.liveVoicePreview = transcript
                self.publishSnapshot()
                guard self.isListeningActive else { continue }
                self.submitQuery(transcript, webSearchMode: .automatic)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for await copiedText in self.clipboardService.$copiedText.values {
                guard !Task.isCancelled, self.isClipboardActive, !copiedText.isEmpty else { continue }
                self.submitQuery(copiedText, webSearchMode: .automatic)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            var lastHash: Int?
            for await data in self.screenshotWatcher.$lastScreenshotData.values {
                guard !Task.isCancelled, let data else { continue }
                let currentHash = data.hashValue
                guard currentHash != lastHash else { continue }
                lastHash = currentHash
                guard Self.userDefaultsBool("autoAnalyze", defaultValue: true) else { continue }
                await self.processImage(data, source: "Auto Screenshot", query: nil)
            }
        }
    }

    private func publishSnapshot() {
        let provider = AIModelNames.currentProvider()
        let model = AIModelNames.reasoning(forProvider: provider)
        shellViewModel?.apply(
            ShellProjectionSnapshot(
                messages: messages,
                isBusy: isBusy,
                statusMessage: statusMessage,
                currentModelDisplay: "\(provider.displayName) · \(model)",
                contextUsage: ContextUsage(
                    usedTokens: intelligenceService.contextTokenEstimate,
                    windowTokens: AIModelNames.contextWindow(forProvider: provider, model: AIModelNames.reasoning)
                ),
                isClipboardActive: isClipboardActive,
                isListeningActive: isListeningActive,
                liveVoicePreview: liveVoicePreview,
                attachedFileData: attachedFileData,
                attachedFileName: attachedFileName,
                isIndexing: isIndexing
            )
        )
    }

    private nonisolated static func assistantOrigin(
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

    private nonisolated static func isProviderCancellation(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else { return false }
        if case .cancelled = providerError {
            return true
        }
        return false
    }

    private nonisolated static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }
}
