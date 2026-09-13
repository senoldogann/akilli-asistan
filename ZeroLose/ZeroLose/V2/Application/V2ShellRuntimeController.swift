import AppKit
import Combine
import Foundation
import Observation
import PDFKit

enum V2RuntimeCommandError: Error, Equatable {
    case unsupportedCommand(String)
}

protocol AgentOrchestrating: Sendable {
    func start(goal: GoalSnapshot) async throws -> AgentSessionSnapshot
    func pause() async
    func resume() async throws
    func cancel() async
    func emergencyStop() async
    func snapshot() async -> AgentSessionSnapshot?
    func isPaused() async -> Bool
}

extension AgentOrchestrator: AgentOrchestrating {}

nonisolated protocol AgentOrchestratorBuilding: Sendable {
    func make(selection: ProviderSelectionSnapshot) async throws -> any AgentOrchestrating
}

nonisolated struct ClosureAgentOrchestratorBuilder: AgentOrchestratorBuilding {
    private let build: @Sendable (ProviderSelectionSnapshot) async throws -> any AgentOrchestrating

    init(
        build: @escaping @Sendable (ProviderSelectionSnapshot) async throws -> any AgentOrchestrating
    ) {
        self.build = build
    }

    func make(selection: ProviderSelectionSnapshot) async throws -> any AgentOrchestrating {
        try await build(selection)
    }
}

nonisolated final class AgentEmergencyStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        stopped = false
        lock.unlock()
    }
}

nonisolated final class AgentMutationExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCount > 0
    }

    func begin() {
        lock.lock()
        activeCount += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        lock.unlock()
    }
}

actor AgentCommandRuntime {
    private let orchestratorBuilder: any AgentOrchestratorBuilding
    private let selectionProvider: @Sendable () async -> ProviderSelectionSnapshot
    private let emergencyStopState: AgentEmergencyStopState
    private let mutationExecutionActive: @Sendable () async -> Bool
    private var orchestrator: (any AgentOrchestrating)?
    private var activeRun: Task<AgentSessionSnapshot, Error>?
    private var isStartingRun = false

    init(
        orchestratorBuilder: any AgentOrchestratorBuilding,
        selectionProvider: @escaping @Sendable () async -> ProviderSelectionSnapshot,
        emergencyStopState: AgentEmergencyStopState,
        mutationExecutionActive: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.orchestratorBuilder = orchestratorBuilder
        self.selectionProvider = selectionProvider
        self.emergencyStopState = emergencyStopState
        self.mutationExecutionActive = mutationExecutionActive
    }

    func submitUserGoal(_ text: String) async throws -> AgentSessionSnapshot {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-empty-goal")
        }
        guard !isStartingRun else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-session-already-active")
        }
        isStartingRun = true

        if let orchestrator,
           let existing = await orchestrator.snapshot(),
           !Self.isTerminal(existing.lifecycle) {
            isStartingRun = false
            throw V2RuntimeCommandError.unsupportedCommand("agent-session-already-active")
        }

        let selection = await selectionProvider()
        let orchestrator: any AgentOrchestrating
        do {
            orchestrator = try await orchestratorBuilder.make(selection: selection)
        } catch {
            isStartingRun = false
            throw error
        }
        self.orchestrator = orchestrator
        isStartingRun = false
        emergencyStopState.reset()

        let goal = GoalSnapshot(
            id: GoalID(rawValue: UUID().uuidString),
            objective: normalized
        )
        let run = Task {
            try await orchestrator.start(goal: goal)
        }
        activeRun = run

        for _ in 0..<100 {
            if let session = await orchestrator.snapshot() {
                return session
            }
            await Task.yield()
        }

        do {
            let final = try await run.value
            activeRun = nil
            return final
        } catch {
            activeRun = nil
            throw error
        }
    }

    func pause(sessionID: AgentSessionID) async throws {
        let orchestrator = try await requireActiveSession(sessionID).orchestrator
        await orchestrator.pause()
    }

    func resume(sessionID: AgentSessionID) async throws {
        let orchestrator = try await requireActiveSession(sessionID).orchestrator
        try await orchestrator.resume()
    }

    func cancel(sessionID: AgentSessionID) async throws {
        let orchestrator = try await requireActiveSession(sessionID).orchestrator
        await orchestrator.cancel()
    }

    func emergencyStop() async throws {
        guard let orchestrator,
              let session = await orchestrator.snapshot(),
              !Self.isTerminal(session.lifecycle) else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-session-not-active")
        }
        emergencyStopState.stop()
        await orchestrator.emergencyStop()
    }

    func snapshot() async -> (
        session: AgentSessionSnapshot?,
        isPaused: Bool,
        mutationExecutionActive: Bool
    ) {
        guard let orchestrator else {
            return (nil, false, await mutationExecutionActive())
        }
        return (
            await orchestrator.snapshot(),
            await orchestrator.isPaused(),
            await mutationExecutionActive()
        )
    }

    func waitForCurrentRun() async -> AgentSessionSnapshot? {
        guard let activeRun else {
            return await orchestrator?.snapshot()
        }

        defer { self.activeRun = nil }
        do {
            return try await activeRun.value
        } catch {
            return await orchestrator?.snapshot()
        }
    }

    private func requireActiveSession(
        _ sessionID: AgentSessionID
    ) async throws -> (orchestrator: any AgentOrchestrating, session: AgentSessionSnapshot) {
        guard let orchestrator,
              let session = await orchestrator.snapshot(),
              session.id == sessionID,
              !Self.isTerminal(session.lifecycle) else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-session-not-active")
        }
        return (orchestrator, session)
    }

    private static func isTerminal(_ lifecycle: AgentLifecycle) -> Bool {
        switch lifecycle {
        case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
            return true
        case .created, .planning, .ready, .executing, .observing, .verifying:
            return false
        }
    }
}


/// Main application runtime used by the SwiftUI shell after the V2 cutover.
///
/// This controller intentionally owns no physical-input, shell, AppleScript, or
/// browser mutation primitive. Model generation is informational by default;
/// mutation-capable work must enter through ToolFabric and its policy boundary.
@MainActor
final class V2ShellRuntimeController: RuntimeCommandControlling, ShellFeatureControlling, @unchecked Sendable {
    private let visionService: VisionService
    private let clipboardService: ClipboardService
    private let screenshotWatcher: ScreenshotWatcherService
    private let audioService: AudioService
    private let documentProcessor: DocumentProcessor
    private let embeddingService: OllamaEmbeddingService
    private let vectorStore: VectorStore
    private let chatHistoryService: ChatHistoryService
    private let nativeToolRuntime: V2NativeToolRuntime
    private let requestCoordinator: RequestCoordinator
    private let attachmentContextProvider: any MutableAttachmentContextProviding
    private let selectionProvider: @Sendable () async -> ProviderSelectionSnapshot
    private let agentRuntime: AgentCommandRuntime?

    private weak var shellViewModel: ShellViewModel?
    private var activeTask: Task<Void, Never>?
    private var agentStateTask: Task<Void, Never>?
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
    private var activeAskSelection: ProviderSelectionSnapshot?
    var onAuthorityModeChanged: ((AuthorityMode) -> Void)?
    var onAgentStateChanged: ((TaskRuntimeProjectionSnapshot) -> Void)?

    init(
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
        selectionProvider: @escaping @Sendable () async -> ProviderSelectionSnapshot,
        agentRuntime: AgentCommandRuntime? = nil,
        initialAuthorityMode: AuthorityMode
    ) {
        self.visionService = visionService
        self.clipboardService = clipboardService
        self.screenshotWatcher = screenshotWatcher
        self.audioService = audioService
        self.documentProcessor = documentProcessor
        self.embeddingService = embeddingService
        self.vectorStore = vectorStore
        self.chatHistoryService = chatHistoryService
        self.nativeToolRuntime = nativeToolRuntime
        self.requestCoordinator = requestCoordinator
        self.attachmentContextProvider = attachmentContextProvider
        self.selectionProvider = selectionProvider
        self.agentRuntime = agentRuntime
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
        guard let agentRuntime else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-runtime-unavailable")
        }

        _ = await nativeToolRuntime.configuration()
        let session = try await agentRuntime.submitUserGoal(normalized)
        let initialState = await agentRuntime.snapshot()
        publishAgentState(
            session: session,
            isPaused: initialState.isPaused,
            mutationExecutionActive: initialState.mutationExecutionActive
        )
        if session.lifecycle == .failed {
            throw V2RuntimeCommandError.unsupportedCommand("agent-structured-planning-blocked")
        }

        guard !Self.isTerminalAgentLifecycle(session.lifecycle) else { return }
        agentStateTask?.cancel()
        agentStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let state = await agentRuntime.snapshot()
                guard let current = state.session else { break }
                self.publishAgentState(
                    session: current,
                    isPaused: state.isPaused,
                    mutationExecutionActive: state.mutationExecutionActive
                )
                if Self.isTerminalAgentLifecycle(current.lifecycle) {
                    _ = await agentRuntime.waitForCurrentRun()
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 25_000_000)
                } catch {
                    break
                }
            }
            self.agentStateTask = nil
        }
    }

    func sendChatMessage(_ text: String) async throws {
        try await processAsk(text, source: "V2 Chat")
    }

    func pauseGoal(_ goalID: GoalID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-session-id-required:pause:\(goalID.rawValue)")
    }

    func resumeGoal(_ goalID: GoalID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-session-id-required:resume:\(goalID.rawValue)")
    }

    func cancelGoal(_ goalID: GoalID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-session-id-required:cancel:\(goalID.rawValue)")
    }

    func pauseAgentSession(_ sessionID: AgentSessionID) async throws {
        guard let agentRuntime else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-runtime-unavailable")
        }
        try await agentRuntime.pause(sessionID: sessionID)
        await publishCurrentAgentState()
    }

    func resumeAgentSession(_ sessionID: AgentSessionID) async throws {
        guard let agentRuntime else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-runtime-unavailable")
        }
        try await agentRuntime.resume(sessionID: sessionID)
        await publishCurrentAgentState()
    }

    func cancelAgentSession(_ sessionID: AgentSessionID) async throws {
        guard let agentRuntime else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-runtime-unavailable")
        }
        try await agentRuntime.cancel(sessionID: sessionID)
        await publishCurrentAgentState()
    }

    func emergencyStop() async throws {
        guard let agentRuntime else {
            throw V2RuntimeCommandError.unsupportedCommand("agent-runtime-unavailable")
        }
        try await agentRuntime.emergencyStop()
        await publishCurrentAgentState()
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
        activeAskSelection = nil
        messages.removeAll()
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
        if let sessionID = activeAskSessionID,
           let selection = activeAskSelection {
            Task {
                await requestCoordinator.cancel(
                    sessionID: sessionID,
                    providerID: selection.providerID
                )
            }
        }
        activeAskSessionID = nil
        activeAskSelection = nil
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
            await self.reviseAnswer(query, assistantMessageID: messageID)
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

        let selection = await selectionProvider()
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
        activeAskSelection = selection
        let hadAttachmentContext = await stageAttachmentContextIfNeeded(conversationID: conversationID)
        if hadAttachmentContext {
            attachedFileData = nil
            attachedFileName = nil
            attachedExtractedText = nil
            publishSnapshot()
        }

        do {
            try await streamAsk(
                AskRequest(
                    sessionID: sessionID,
                    conversationID: conversationID,
                    text: query,
                    selection: selection,
                    activeGoalID: nil
                ),
                query: query,
                assistantIndex: assistantIndex,
                assistantID: assistantID
            )
            await attachmentContextProvider.clearAttachments(conversationID: conversationID)
            if activeAskSessionID == sessionID {
                activeAskSessionID = nil
                activeAskSelection = nil
            }
            isBusy = false
            statusMessage = "Ready"
            activeTask = nil
            publishSnapshot()
        } catch {
            await attachmentContextProvider.clearAttachments(conversationID: conversationID)
            if activeAskSessionID == sessionID {
                activeAskSessionID = nil
                activeAskSelection = nil
            }
            isBusy = false
            activeTask = nil
            let cancelled = Self.isCancellation(error)
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

    /// Re-runs an existing answer through the bound provider without appending a
    /// new user turn. Reached from the AI-refine affordance on cache/fast-path
    /// answers; the V2 coordinator owns persistence.
    private func reviseAnswer(_ query: String, assistantMessageID: UUID) async {
        guard !isBusy,
              let assistantIndex = messages.firstIndex(where: { $0.id == assistantMessageID })
        else { return }

        isBusy = true
        let selection = await selectionProvider()
        let conversationID = askConversationID
        let sessionID = ModelSessionID(rawValue: UUID().uuidString)
        activeAskSessionID = sessionID
        activeAskSelection = selection

        let existing = messages[assistantIndex]
        messages[assistantIndex] = ChatMessage(
            id: existing.id,
            text: "Thinking...",
            isUser: false,
            type: .thinking,
            assistantOrigin: existing.assistantOrigin,
            relatedQuery: query
        )
        statusMessage = "Thinking..."
        publishSnapshot()

        do {
            let responseText = try await streamAsk(
                AskRequest(
                    sessionID: sessionID,
                    conversationID: conversationID,
                    text: query,
                    selection: selection,
                    activeGoalID: nil
                ),
                query: query,
                assistantIndex: assistantIndex,
                assistantID: assistantMessageID
            )
            try? await chatHistoryService.addMessage(text: responseText, isUser: false)
            statusMessage = "Ready"
        } catch {
            let cancelled = Self.isCancellation(error)
            updateAssistantMessage(
                at: assistantIndex,
                id: assistantMessageID,
                text: cancelled ? "[Stopped by user]" : "Error: \(error.localizedDescription)",
                type: cancelled ? .text : .error,
                origin: nil,
                relatedQuery: query,
                thinking: nil
            )
            statusMessage = cancelled ? "Stopped" : "Error"
        }
        if activeAskSessionID == sessionID {
            activeAskSessionID = nil
            activeAskSelection = nil
        }
        isBusy = false
        activeTask = nil
        publishSnapshot()
    }

    /// Streams one Ask turn into an already-staged assistant message.
    ///
    /// Chat, image analysis and answer revision all funnel through here so every
    /// model turn uses the same coordinator, cancellation and stop bookkeeping.
    /// Returns the accumulated assistant text.
    @discardableResult
    private func streamAsk(
        _ request: AskRequest,
        query: String,
        assistantIndex: Int,
        assistantID: UUID
    ) async throws -> String {
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
        return responseText
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled || isProviderCancellation(error)
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

        let selection = await selectionProvider()
        let conversationID = askConversationID
        let sessionID = ModelSessionID(rawValue: UUID().uuidString)
        activeAskSessionID = sessionID
        activeAskSelection = selection

        do {
            let responseText = try await streamAsk(
                AskRequest(
                    sessionID: sessionID,
                    conversationID: conversationID,
                    text: resolvedQuery,
                    selection: selection,
                    activeGoalID: nil,
                    imageData: data
                ),
                query: resolvedQuery,
                assistantIndex: assistantIndex,
                assistantID: assistantID
            )
            try? await chatHistoryService.addMessage(text: responseText, isUser: false)
            statusMessage = "Ready"
        } catch {
            let cancelled = Self.isCancellation(error)
            updateAssistantMessage(
                at: assistantIndex,
                id: assistantID,
                text: cancelled ? "[Stopped by user]" : "Error: \(error.localizedDescription)",
                type: cancelled ? .text : .error,
                origin: nil,
                relatedQuery: resolvedQuery,
                thinking: nil
            )
            statusMessage = cancelled ? "Stopped" : "Error"
        }
        if activeAskSessionID == sessionID {
            activeAskSessionID = nil
            activeAskSelection = nil
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

    private static func isTerminalAgentLifecycle(_ lifecycle: AgentLifecycle) -> Bool {
        switch lifecycle {
        case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
            return true
        case .created, .planning, .ready, .executing, .observing, .verifying:
            return false
        }
    }

    private func publishCurrentAgentState() async {
        guard let agentRuntime else { return }
        let state = await agentRuntime.snapshot()
        guard let session = state.session else { return }
        publishAgentState(
            session: session,
            isPaused: state.isPaused,
            mutationExecutionActive: state.mutationExecutionActive
        )
    }

    private func publishAgentState(
        session: AgentSessionSnapshot,
        isPaused: Bool,
        mutationExecutionActive: Bool
    ) {
        onAgentStateChanged?(
            TaskRuntimeProjectionSnapshot(
                goalID: session.goalID,
                statusText: session.lifecycle.rawValue,
                sessionID: session.id,
                lifecycle: session.lifecycle,
                isPaused: isPaused,
                mutationCapableExecutionActive: mutationExecutionActive && !isPaused
            )
        )
    }

    private func publishSnapshot() {
        shellViewModel?.apply(
            ShellProjectionSnapshot(
                messages: messages,
                isBusy: isBusy,
                statusMessage: statusMessage,
                isClipboardActive: isClipboardActive,
                isListeningActive: isListeningActive,
                liveVoicePreview: liveVoicePreview,
                attachedFileData: attachedFileData,
                attachedFileName: attachedFileName,
                isIndexing: isIndexing
            )
        )
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
