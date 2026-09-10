import Foundation
import Observation

@MainActor
final class ZeroLoseRuntimeContainer {
    static let shared = ZeroLoseRuntimeContainer(legacy: DependencyContainer.shared)

    let facade: ApplicationFacade
    let chatViewModel: ChatViewModel
    let shellViewModel: ShellViewModel
    let settingsViewModel: SettingsViewModel
    let taskRuntimeViewModel: TaskRuntimeViewModel
    let approvalViewModel: ApprovalViewModel
    let toolManagementViewModel: ToolManagementViewModel
    let memoryInspectorViewModel: MemoryInspectorViewModel

    private let shellAdapter: LegacyShellFeatureAdapter
    private let runtimeController: LegacyRuntimeCommandController
    private let settingsController: LegacySettingsDataController

    init(legacy: DependencyContainer) {
        let initialAuthority = SettingsMigrationCoordinator.mapLegacyApprovalMode(
            UserDefaults.standard.string(forKey: "commandApprovalMode")
        )
        let runtimeController = LegacyRuntimeCommandController(
            legacyViewModel: legacy.ghostViewModel,
            initialAuthority: initialAuthority
        )
        let toolController = FailClosedToolManagementController()
        let memoryController = FailClosedMemoryCommandController()
        let facade = ApplicationFacade(
            runtime: runtimeController,
            tools: toolController,
            memory: memoryController
        )
        let settingsController = LegacySettingsDataController(legacy: legacy)
        let shellAdapter = LegacyShellFeatureAdapter(legacyViewModel: legacy.ghostViewModel)
        let shellViewModel = ShellViewModel(controller: shellAdapter)

        self.runtimeController = runtimeController
        self.settingsController = settingsController
        self.shellAdapter = shellAdapter
        self.facade = facade
        self.chatViewModel = ChatViewModel(commandSender: facade)
        self.shellViewModel = shellViewModel
        let settingsViewModel = SettingsViewModel(
            commandSender: facade,
            dataController: settingsController
        )
        self.settingsViewModel = settingsViewModel
        self.taskRuntimeViewModel = TaskRuntimeViewModel(commandSender: facade)
        self.approvalViewModel = ApprovalViewModel(commandSender: facade)
        self.toolManagementViewModel = ToolManagementViewModel(commandSender: facade)
        self.memoryInspectorViewModel = MemoryInspectorViewModel(commandSender: facade)

        settingsViewModel.apply(SettingsProjectionSnapshot(authorityMode: initialAuthority))
        runtimeController.onAuthorityModeChanged = { [weak settingsViewModel] mode in
            settingsViewModel?.apply(SettingsProjectionSnapshot(authorityMode: mode))
        }
        shellAdapter.bind(to: shellViewModel)
    }
}

enum ZeroLoseRuntimeContainerError: Error, Equatable {
    case commandUnavailableDuringCutover(String)
}

@MainActor
private final class LegacyRuntimeCommandController: RuntimeCommandControlling, @unchecked Sendable {
    private let legacyViewModel: GhostViewModel
    private(set) var authorityMode: AuthorityMode
    var onAuthorityModeChanged: ((AuthorityMode) -> Void)?

    init(legacyViewModel: GhostViewModel, initialAuthority: AuthorityMode) {
        self.legacyViewModel = legacyViewModel
        self.authorityMode = initialAuthority
    }

    func submitUserGoal(_ text: String) async throws {
        legacyViewModel.processQuestion(
            text,
            source: "V2 Goal Cutover",
            allowAgentActions: false
        )
    }

    func sendChatMessage(_ text: String) async throws {
        legacyViewModel.processQuestion(
            text,
            source: "V2 Chat Cutover",
            allowAgentActions: false
        )
    }

    func pauseGoal(_ goalID: GoalID) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("pause:\(goalID.rawValue)")
    }

    func resumeGoal(_ goalID: GoalID) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("resume:\(goalID.rawValue)")
    }

    func cancelGoal(_ goalID: GoalID) async throws {
        legacyViewModel.stopResponse()
    }

    func approveInvocation(_ invocationID: InvocationID) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("approve:\(invocationID.rawValue)")
    }

    func denyInvocation(_ invocationID: InvocationID) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("deny:\(invocationID.rawValue)")
    }

    func changeAuthorityMode(_ mode: AuthorityMode) async throws {
        guard mode != .fullAccess else {
            throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("full-access")
        }
        authorityMode = mode
        onAuthorityModeChanged?(mode)
    }
}

private actor FailClosedToolManagementController: ToolManagementControlling {
    func setToolEnabled(_ toolID: ToolID, enabled: Bool) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover(
            "tool:\(toolID.rawValue):\(enabled)"
        )
    }

    func setMCPServerEnabled(_ serverID: String, enabled: Bool) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover(
            "mcp:\(serverID):\(enabled)"
        )
    }
}

private actor FailClosedMemoryCommandController: MemoryCommandControlling {
    func pinMemoryEntry(_ id: String) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("pin-memory:\(id)")
    }

    func forgetMemoryEntry(_ id: String) async throws {
        throw ZeroLoseRuntimeContainerError.commandUnavailableDuringCutover("forget-memory:\(id)")
    }
}

@MainActor
private final class LegacyShellFeatureAdapter: ShellFeatureControlling {
    private let legacyViewModel: GhostViewModel
    private weak var target: ShellViewModel?
    private var observationGeneration: UInt64 = 0

    init(legacyViewModel: GhostViewModel) {
        self.legacyViewModel = legacyViewModel
    }

    func bind(to target: ShellViewModel) {
        self.target = target
        observationGeneration &+= 1
        observe(generation: observationGeneration)
    }

    private func observe(generation: UInt64) {
        guard generation == observationGeneration else { return }

        withObservationTracking {
            let snapshot = ShellProjectionSnapshot(
                messages: legacyViewModel.messages,
                isBusy: legacyViewModel.isBusy,
                statusMessage: legacyViewModel.statusMessage,
                currentModelDisplay: legacyViewModel.currentModelDisplay,
                contextUsage: legacyViewModel.contextUsage,
                isClipboardActive: legacyViewModel.isClipboardActive,
                isListeningActive: legacyViewModel.isListeningActive,
                liveVoicePreview: legacyViewModel.liveVoicePreview,
                attachedFileData: legacyViewModel.attachedFileData,
                attachedFileName: legacyViewModel.attachedFileName,
                isIndexing: legacyViewModel.isIndexing,
                activeAction: legacyViewModel.zeroOperator.activeAction
            )
            target?.apply(snapshot)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe(generation: generation)
            }
        }
    }

    func clearHistory() { legacyViewModel.clearHistory() }
    func toggleClipboard() { legacyViewModel.toggleClipboard() }
    func toggleListening() { legacyViewModel.toggleListening() }
    func stopResponse() { legacyViewModel.stopResponse() }
    func submitQuery(_ text: String, webSearchMode: WebSearchMode) {
        if legacyViewModel.attachedFileData != nil {
            // Vision analysis already disables mutation execution internally.
            legacyViewModel.askQuestion(text, webSearchMode: webSearchMode)
            return
        }
        legacyViewModel.processQuestion(
            text,
            source: "V2 Shell Compatibility",
            webSearchMode: webSearchMode,
            allowAgentActions: false
        )
    }
    func refineAnswer(messageID: UUID) {
        guard let message = legacyViewModel.messages.first(where: { $0.id == messageID }),
              message.allowsAIRefinement,
              let query = message.relatedQuery else {
            return
        }
        legacyViewModel.processQuestion(
            query,
            source: "V2 AI Refine",
            allowAgentActions: false,
            processingMode: .forceAIReasoning,
            showUserMessage: false,
            targetAssistantMessageID: messageID
        )
    }
    func clearAttachment() { legacyViewModel.clearAttachment() }
    func attachFile(from url: URL) { legacyViewModel.attachFile(from: url) }
    func analyzeScreen() { legacyViewModel.analyzeScreen() }
    func testComputerUseSnapshot() { legacyViewModel.testComputerUseSnapshot() }
    func verifyComputerUseEndToEnd() { legacyViewModel.verifyComputerUseEndToEnd() }
    @discardableResult func warmUpInterviewContext() -> String { legacyViewModel.warmUpInterviewContext() }
}

@MainActor
private final class LegacySettingsDataController: SettingsDataControlling {
    private let legacy: DependencyContainer

    init(legacy: DependencyContainer) {
        self.legacy = legacy
    }

    func credentialSnapshot() async -> CredentialSettingsSnapshot {
        CredentialSettingsSnapshot(
            values: [
                .openAI: Secrets.openAIApiKey,
                .deepSeek: Secrets.deepSeekApiKey,
                .openCodeZen: Secrets.openCodeZenApiKey,
                .openCodeGo: Secrets.openCodeGoApiKey,
                .ollama: Secrets.ollamaApiKey,
                .groq: Secrets.groqApiKey,
                .tavily: Secrets.tavilyApiKey
            ],
            validity: [
                .openAI: Secrets.isOpenAIKeyValid,
                .deepSeek: Secrets.isDeepSeekKeyValid,
                .openCodeZen: Secrets.isOpenCodeZenKeyValid,
                .openCodeGo: Secrets.isOpenCodeGoKeyValid,
                .ollama: Secrets.isOllamaKeyValid,
                .groq: Secrets.isGroqKeyValid,
                .tavily: Secrets.isTavilyKeyValid
            ],
            models: [
                .openAI: OllamaService.cachedModels(for: CredentialProvider.openAI.rawValue),
                .deepSeek: OllamaService.cachedModels(for: CredentialProvider.deepSeek.rawValue),
                .openCodeZen: OllamaService.cachedModels(for: CredentialProvider.openCodeZen.rawValue),
                .openCodeGo: OllamaService.cachedModels(for: CredentialProvider.openCodeGo.rawValue),
                .ollama: OllamaService.cachedModels(for: CredentialProvider.ollama.rawValue)
            ]
        )
    }

    func updateCredential(_ value: String, for provider: CredentialProvider) async {
        switch provider {
        case .openAI: Secrets.openAIApiKey = value
        case .deepSeek: Secrets.deepSeekApiKey = value
        case .openCodeZen: Secrets.openCodeZenApiKey = value
        case .openCodeGo: Secrets.openCodeGoApiKey = value
        case .ollama: Secrets.ollamaApiKey = value
        case .groq: Secrets.groqApiKey = value
        case .tavily: Secrets.tavilyApiKey = value
        }
    }

    func resetCredentials() async {
        Secrets.resetToDefaults()
    }

    func refreshModels(for provider: CredentialProvider) async -> [String] {
        let key: String
        switch provider {
        case .openAI: key = Secrets.openAIApiKey
        case .deepSeek: key = Secrets.deepSeekApiKey
        case .openCodeZen: key = Secrets.openCodeZenApiKey
        case .openCodeGo: key = Secrets.openCodeGoApiKey
        case .ollama: key = Secrets.ollamaApiKey
        case .groq, .tavily: return []
        }
        guard !key.isEmpty else { return [] }
        return await legacy.ollamaService.fetchAvailableModels(
            provider: provider.rawValue,
            apiKey: key
        )
    }

    func memoryCount() async throws -> Int {
        try await legacy.vectorStore.countEmbeddings()
    }

    func clearMemory() async throws -> Int {
        try await legacy.vectorStore.deleteAll()
        await legacy.chatHistoryService.startNewSession()
        legacy.intelligenceService.clearHistory()
        return try await legacy.vectorStore.countEmbeddings()
    }
}
