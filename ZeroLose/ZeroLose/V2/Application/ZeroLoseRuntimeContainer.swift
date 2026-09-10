import Foundation

@MainActor
final class ZeroLoseRuntimeContainer {
    static let shared = ZeroLoseRuntimeContainer(dependencies: DependencyContainer.shared)

    let facade: ApplicationFacade
    let chatViewModel: ChatViewModel
    let shellViewModel: ShellViewModel
    let settingsViewModel: SettingsViewModel
    let taskRuntimeViewModel: TaskRuntimeViewModel
    let approvalViewModel: ApprovalViewModel
    let toolManagementViewModel: ToolManagementViewModel
    let memoryInspectorViewModel: MemoryInspectorViewModel
    let timelineProjection: TimelineProjection
    let runtimeProjectionCoordinator: RuntimeProjectionCoordinator?
    let runtimeProjectionInitializationError: String?

    private let runtimeController: V2ShellRuntimeController
    private let nativeToolRuntime: V2NativeToolRuntime
    private let settingsController: RuntimeSettingsDataController
    private let eventStore: SQLiteEventStore?
    private let eventRecorder: RuntimeEventRecorder?

    init(dependencies: DependencyContainer) {
        let initialAuthority = SettingsMigrationCoordinator.mapLegacyApprovalMode(
            UserDefaults.standard.string(forKey: "commandApprovalMode")
        )
        let timelineProjection = TimelineProjection()
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let runtimeDirectory = applicationSupport
            .appendingPathComponent("ZeroLose/V2", isDirectory: true)

        var eventStore: SQLiteEventStore?
        var eventRecorder: RuntimeEventRecorder?
        var runtimeProjectionCoordinator: RuntimeProjectionCoordinator?
        var runtimeProjectionInitializationError: String?

        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            let store = try SQLiteEventStore(
                databaseURL: runtimeDirectory.appendingPathComponent("runtime.sqlite3")
            )
            let recorder = RuntimeEventRecorder(
                eventStore: store,
                streamID: "runtime:main"
            )
            eventStore = store
            eventRecorder = recorder
            runtimeProjectionCoordinator = RuntimeProjectionCoordinator(
                eventStore: store,
                streamID: "runtime:main",
                timeline: timelineProjection
            )
        } catch {
            runtimeProjectionInitializationError = "Runtime activity unavailable"
        }

        let registry = ToolRegistry()
        let credentialBroker = KeychainCredentialBrokerAdapter()
        let tavilyService = dependencies.tavilyService
        let systemStatusService = dependencies.systemStatusService
        let builtinExecutor = V2BuiltinToolExecutor(
            webSearch: { query in
                try await tavilyService.search(query: query, detailLevel: .brief)
            },
            systemStatus: {
                await systemStatusService.getSystemContextSummary()
            }
        )
        let builtinProvider = BuiltinToolProvider(executor: builtinExecutor)
        let toolFabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: credentialBroker,
            providers: [builtinProvider],
            authorityMode: initialAuthority
        )
        let nativeToolRuntime = V2NativeToolRuntime(
            registry: registry,
            toolFabric: toolFabric,
            eventRecorder: eventRecorder,
            initialDescriptors: V2BuiltinToolCatalog.descriptors
        )
        let runtimeController = V2ShellRuntimeController(
            intelligenceService: dependencies.intelligenceService,
            visionService: dependencies.visionService,
            clipboardService: dependencies.clipboardService,
            screenshotWatcher: dependencies.screenshotWatcher,
            audioService: dependencies.audioService,
            documentProcessor: dependencies.documentProcessor,
            embeddingService: dependencies.embeddingService,
            vectorStore: dependencies.vectorStore,
            chatHistoryService: dependencies.chatHistoryService,
            nativeToolRuntime: nativeToolRuntime,
            initialAuthorityMode: initialAuthority
        )
        let memoryController = UnavailableMemoryCommandController()
        let facade = ApplicationFacade(
            runtime: runtimeController,
            tools: nativeToolRuntime,
            memory: memoryController
        )
        let settingsController = RuntimeSettingsDataController(dependencies: dependencies)
        let shellViewModel = ShellViewModel(controller: runtimeController)
        let settingsViewModel = SettingsViewModel(
            commandSender: facade,
            dataController: settingsController
        )

        self.runtimeController = runtimeController
        self.nativeToolRuntime = nativeToolRuntime
        self.settingsController = settingsController
        self.eventStore = eventStore
        self.eventRecorder = eventRecorder
        self.timelineProjection = timelineProjection
        self.runtimeProjectionCoordinator = runtimeProjectionCoordinator
        self.runtimeProjectionInitializationError = runtimeProjectionInitializationError
        self.facade = facade
        self.chatViewModel = ChatViewModel(commandSender: facade)
        self.shellViewModel = shellViewModel
        self.settingsViewModel = settingsViewModel
        self.taskRuntimeViewModel = TaskRuntimeViewModel(commandSender: facade)
        self.approvalViewModel = ApprovalViewModel(commandSender: facade)
        self.toolManagementViewModel = ToolManagementViewModel(commandSender: facade)
        self.memoryInspectorViewModel = MemoryInspectorViewModel(commandSender: facade)

        settingsViewModel.apply(SettingsProjectionSnapshot(authorityMode: initialAuthority))
        runtimeController.onAuthorityModeChanged = { [weak settingsViewModel] mode in
            settingsViewModel?.apply(SettingsProjectionSnapshot(authorityMode: mode))
        }
        runtimeController.bind(to: shellViewModel)
    }
}

private actor UnavailableMemoryCommandController: MemoryCommandControlling {
    func pinMemoryEntry(_ id: String) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("pin-memory:\(id)")
    }

    func forgetMemoryEntry(_ id: String) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("forget-memory:\(id)")
    }
}

@MainActor
private final class RuntimeSettingsDataController: SettingsDataControlling {
    private let dependencies: DependencyContainer

    init(dependencies: DependencyContainer) {
        self.dependencies = dependencies
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
        return await dependencies.ollamaService.fetchAvailableModels(
            provider: provider.rawValue,
            apiKey: key
        )
    }

    func memoryCount() async throws -> Int {
        try await dependencies.vectorStore.countEmbeddings()
    }

    func clearMemory() async throws -> Int {
        try await dependencies.vectorStore.deleteAll()
        await dependencies.chatHistoryService.startNewSession()
        dependencies.intelligenceService.clearHistory()
        return try await dependencies.vectorStore.countEmbeddings()
    }
}
