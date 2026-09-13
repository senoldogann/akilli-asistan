import ComputerAgentMacOS
import CryptoKit
import Foundation

@MainActor
final class ZeroLoseRuntimeContainer {
    static let shared = ZeroLoseRuntimeContainer(dependencies: DependencyContainer.shared)

    let facade: ApplicationFacade
    let chatViewModel: ChatViewModel
    let shellViewModel: ShellViewModel
    let providerViewModel: ProviderViewModel
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
    private let modelProviderFabric: ModelProviderFabric
    private let providerControlPlane: ProviderControlPlane
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
        let runtimeDatabaseURL = runtimeDirectory.appendingPathComponent("runtime.sqlite3")

        var eventStore: SQLiteEventStore?
        var checkpointStore: SQLiteCheckpointStore?
        var eventRecorder: RuntimeEventRecorder?
        var runtimeProjectionCoordinator: RuntimeProjectionCoordinator?
        var runtimeProjectionInitializationError: String?

        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            let store = try SQLiteEventStore(databaseURL: runtimeDatabaseURL)
            let checkpoints = try SQLiteCheckpointStore(databaseURL: runtimeDatabaseURL)
            let recorder = RuntimeEventRecorder(
                eventStore: store,
                streamID: "runtime:main"
            )
            eventStore = store
            checkpointStore = checkpoints
            eventRecorder = recorder
            runtimeProjectionCoordinator = RuntimeProjectionCoordinator(
                eventStore: store,
                streamID: "runtime:main",
                timeline: timelineProjection
            )
        } catch {
            runtimeProjectionInitializationError = "Runtime activity unavailable"
        }

        let conversationStore: any ConversationStoring
        do {
            conversationStore = try SQLiteConversationStore(
                databaseURL: runtimeDirectory.appendingPathComponent("conversation.sqlite3")
            )
        } catch {
            conversationStore = TransientConversationStore()
        }

        let memoryStore: any MemoryStoring
        do {
            memoryStore = try SQLiteMemoryStore(
                databaseURL: runtimeDirectory.appendingPathComponent("memory.sqlite3")
            )
        } catch {
            memoryStore = TransientMemoryStore()
        }

        let registry = ToolRegistry()
        let credentialBroker = KeychainCredentialBrokerAdapter()

        let defaults = UserDefaults.standard

        let cliLocator = CLIExecutableLocator()
        let cliRunner = CLIProcessRunner()
        let codexProvider = CodexCLIProvider(locator: cliLocator, runner: cliRunner)
        let claudeProvider = ClaudeCLIProvider(locator: cliLocator, runner: cliRunner)
        let openCodeProvider = OpenCodeCLIProvider(locator: cliLocator, runner: cliRunner)
        let antigravityProvider = AntigravityCLIProvider(locator: cliLocator, runner: cliRunner)
        let openAIProvider = OpenAIAPIProvider(
            credentials: credentialBroker,
            transport: OpenAITransport()
        )
        let modelProviderFabric = ModelProviderFabric(
            providers: [codexProvider, claudeProvider, openCodeProvider, antigravityProvider, openAIProvider],
            selectedProviderID: ModelProviderID(rawValue: "codex")
        )
        let providerControlPlane = ProviderControlPlane(
            fabric: modelProviderFabric,
            persistence: UserDefaultsProviderSelectionStore(defaults: defaults)
        )
        let providerSettingsController = ProviderSettingsController(
            openAIKeyStore: credentialBroker
        )
        let providerViewModel = ProviderViewModel(
            controlPlane: providerControlPlane,
            settingsController: providerSettingsController
        )

        let attachmentContextBuffer = AttachmentContextBuffer()
        let attachmentContextProvider: any AttachmentContextProviding = attachmentContextBuffer
        let contextOrchestrator = ContextOrchestrator(
            sources: [
                ConversationContextSource(store: conversationStore),
                MemoryContextSource(store: memoryStore),
                AttachmentContextSource(provider: attachmentContextProvider)
            ],
            policy: ContextPolicy(maxCharacters: 16_000, minimumRelevance: 0.10)
        )
        let requestCoordinator = RequestCoordinator(
            contextOrchestrator: contextOrchestrator,
            providerFabric: modelProviderFabric,
            conversationStore: conversationStore
        )

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
        let emergencyStopState = AgentEmergencyStopState()
        let mutationExecutionState = AgentMutationExecutionState()
        let toolComposition = AgentComputerToolComposition.make(
            baseProviders: [builtinProvider],
            baseDescriptors: V2BuiltinToolCatalog.descriptors,
            observationSourceProvider: LiveMacOSComputerObservationSourceProvider.makeIfReady(),
            shouldStop: { emergencyStopState.isStopped }
        )
        let toolFabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: credentialBroker,
            providers: toolComposition.providers,
            authorityMode: initialAuthority
        )
        let nativeToolRuntime = V2NativeToolRuntime(
            registry: registry,
            toolFabric: toolFabric,
            eventRecorder: eventRecorder,
            initialDescriptors: toolComposition.descriptors
        )

        let agentRuntime: AgentCommandRuntime?
        if let eventStore, let checkpointStore {
            let agentBudget = RuntimeBudget(
                limits: RuntimeBudgetLimits(
                    maxWallClockSeconds: 300,
                    maxModelCalls: 20,
                    maxToolCalls: 50,
                    maxRecoveryAttempts: 3,
                    maxExternalSpend: 100,
                    maxParallelTasks: 2,
                    deadline: nil
                )
            )
            let descriptorMap = Dictionary(
                uniqueKeysWithValues: toolComposition.descriptors.map { ($0.id, $0) }
            )
            let planningRegistry = ToolRegistrySnapshot(
                revision: UInt64(toolComposition.descriptors.count),
                descriptors: descriptorMap
            )
            let taskExecutor = AgentToolInvocationExecutor(
                registry: registry,
                toolFabric: toolFabric,
                mutationExecutionState: mutationExecutionState,
                computerStateProvider: toolComposition.observationProvider,
                computerCapturer: toolComposition.observationProvider == nil
                    ? nil
                    : ScreenCaptureKitComputerVerificationCapturer(),
                shouldStop: { emergencyStopState.isStopped }
            )
            let taskRuntime = TaskRuntime(
                executor: taskExecutor,
                verifier: ProductionAgentTaskVerifier(),
                budget: agentBudget
            )
            let scheduler = Scheduler(maxParallelReads: 2)
            let goalVerifier = ProductionAgentGoalVerifier()
            let planningContext = PlanningContext(
                retrievedContext: ContextBundle(items: [], excluded: [], usedCharacters: 0),
                registry: planningRegistry
            )
            let orchestratorBuilder = ClosureAgentOrchestratorBuilder { selection in
                let status = await modelProviderFabric.status(for: selection.providerID)
                guard status.availability == .ready || status.availability == .detected,
                      await modelProviderFabric.modelSupports(
                        .jsonOutput,
                        modelID: selection.modelID,
                        using: selection.providerID
                      ) else {
                    throw V2RuntimeCommandError.unsupportedCommand(
                        "agent-structured-planning-unavailable"
                    )
                }

                return AgentOrchestrator(
                    planner: ModelPlanningAdapter(
                        providerFabric: modelProviderFabric,
                        selection: selection
                    ),
                    scheduler: scheduler,
                    taskRuntime: taskRuntime,
                    checkpointStore: checkpointStore,
                    eventStore: eventStore,
                    goalVerifier: goalVerifier,
                    budget: agentBudget,
                    planningContext: planningContext
                )
            }
            agentRuntime = AgentCommandRuntime(
                orchestratorBuilder: orchestratorBuilder,
                selectionProvider: {
                    await providerControlPlane.currentSelection()
                },
                emergencyStopState: emergencyStopState,
                mutationExecutionActive: { mutationExecutionState.isActive }
            )
        } else {
            agentRuntime = nil
        }

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
            requestCoordinator: requestCoordinator,
            attachmentContextProvider: attachmentContextBuffer,
            selectionProvider: {
                await providerControlPlane.currentSelection()
            },
            agentRuntime: agentRuntime,
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
        self.modelProviderFabric = modelProviderFabric
        self.providerControlPlane = providerControlPlane
        self.settingsController = settingsController
        self.eventStore = eventStore
        self.eventRecorder = eventRecorder
        self.timelineProjection = timelineProjection
        self.runtimeProjectionCoordinator = runtimeProjectionCoordinator
        self.runtimeProjectionInitializationError = runtimeProjectionInitializationError
        self.facade = facade
        self.chatViewModel = ChatViewModel(commandSender: facade)
        self.shellViewModel = shellViewModel
        self.providerViewModel = providerViewModel
        self.settingsViewModel = settingsViewModel
        let taskRuntimeViewModel = TaskRuntimeViewModel(commandSender: facade)
        self.taskRuntimeViewModel = taskRuntimeViewModel
        self.approvalViewModel = ApprovalViewModel(commandSender: facade)
        self.toolManagementViewModel = ToolManagementViewModel(commandSender: facade)
        self.memoryInspectorViewModel = MemoryInspectorViewModel(commandSender: facade)

        settingsViewModel.apply(SettingsProjectionSnapshot(authorityMode: initialAuthority))
        runtimeController.onAuthorityModeChanged = { [weak settingsViewModel] mode in
            settingsViewModel?.apply(SettingsProjectionSnapshot(authorityMode: mode))
        }
        runtimeController.onAgentStateChanged = { [weak taskRuntimeViewModel] snapshot in
            taskRuntimeViewModel?.apply(snapshot)
        }
        runtimeController.bind(to: shellViewModel)
        Task {
            await providerViewModel.refresh()
        }
    }
}

struct AgentComputerToolComposition {
    let providers: [any ToolProviding]
    let descriptors: [ToolDescriptor]
    let observationProvider: MacOSComputerObservationProvider?

    static func make(
        baseProviders: [any ToolProviding],
        baseDescriptors: [ToolDescriptor],
        observationSourceProvider: (any MacOSComputerObservationSourceProviding)?,
        shouldStop: @escaping () -> Bool
    ) -> AgentComputerToolComposition {
        guard let observationSourceProvider else {
            return AgentComputerToolComposition(
                providers: baseProviders,
                descriptors: baseDescriptors,
                observationProvider: nil
            )
        }

        let observationProvider = MacOSComputerObservationProvider(
            sourceProvider: observationSourceProvider
        )
        let mutationAdapter = MacOSComputerMutationAdapter(
            stateProvider: observationProvider,
            shouldStop: shouldStop
        )
        let computerProvider = ComputerToolProvider(gateway: mutationAdapter)

        return AgentComputerToolComposition(
            providers: baseProviders + [computerProvider],
            descriptors: baseDescriptors + V2ComputerToolCatalog.descriptors,
            observationProvider: observationProvider
        )
    }
}

enum V2ComputerToolCatalog {
    static let descriptors: [ToolDescriptor] = [
        makeDescriptor(
            id: "computer.pointer.click",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{"stateVersion":{"type":"integer","minimum":0},"observationID":{"type":"string","minLength":1},"x":{"type":"number"},"y":{"type":"number"}},"required":["stateVersion","observationID","x","y"],"additionalProperties":false}"#.utf8
            )
        ),
        makeDescriptor(
            id: "computer.keyboard.type",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{"stateVersion":{"type":"integer","minimum":0},"observationID":{"type":"string","minLength":1},"text":{"type":"string"}},"required":["stateVersion","observationID","text"],"additionalProperties":false}"#.utf8
            )
        ),
        makeDescriptor(
            id: "computer.keyboard.press",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{"stateVersion":{"type":"integer","minimum":0},"observationID":{"type":"string","minLength":1},"key":{"type":"string","minLength":1}},"required":["stateVersion","observationID","key"],"additionalProperties":false}"#.utf8
            )
        ),
        makeDescriptor(
            id: "computer.scroll",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{"stateVersion":{"type":"integer","minimum":0},"observationID":{"type":"string","minLength":1},"amount":{"type":"integer","minimum":-1400,"maximum":1400}},"required":["stateVersion","observationID","amount"],"additionalProperties":false}"#.utf8
            )
        ),
        makeDescriptor(
            id: "computer.wait",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{"stateVersion":{"type":"integer","minimum":0},"observationID":{"type":"string","minLength":1},"milliseconds":{"type":"integer","minimum":0,"maximum":5000}},"required":["stateVersion","observationID","milliseconds"],"additionalProperties":false}"#.utf8
            )
        ),
    ]

    private static func makeDescriptor(
        id: String,
        inputSchemaJSON: Data
    ) -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: id),
            providerID: "computer",
            provenance: "zerolose:v2:computer:macos",
            descriptorRevision: 1,
            schemaDigest: digest(inputSchemaJSON),
            inputSchemaJSON: inputSchemaJSON,
            outputSchemaJSON: nil,
            effectClass: .reversibleLocalMutation,
            declaredRisk: .reversibleLocalMutation,
            requiredCredentialScopes: [],
            idempotency: .logicalOperationKeyRequired,
            concurrencyClass: .mutation,
            verificationContract: VerificationContract(kind: "fresh-computer-observation"),
            enabled: true
        )
    }

    private static func digest(_ input: Data) -> String {
        let hash = SHA256.hash(data: input)
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }
}

private actor TransientConversationStore: ConversationStoring {
    private var values: [String: ConversationMessage] = [:]

    func save(_ message: ConversationMessage) async throws {
        values[message.id] = message
    }

    func message(id: String) async throws -> ConversationMessage? {
        values[id]
    }

    func messages(conversationID: String) async throws -> [ConversationMessage] {
        values.values
            .filter { $0.conversationID == conversationID }
            .sorted { lhs, rhs in
                if lhs.recordedAt == rhs.recordedAt {
                    return lhs.id < rhs.id
                }
                return lhs.recordedAt < rhs.recordedAt
            }
    }

    func count() async throws -> Int {
        values.count
    }
}

private actor TransientMemoryStore: MemoryStoring {
    private var values: [String: MemoryRecord] = [:]

    func save(_ record: MemoryRecord) async throws {
        values[record.id] = record
    }

    func record(id: String) async throws -> MemoryRecord? {
        values[id]
    }

    func semantic(id: String) async throws -> SemanticMemoryRecord? {
        guard let record = values[id], case .semantic(let semantic) = record else {
            return nil
        }
        return semantic
    }

    func records(scope: MemoryScope) async throws -> [MemoryRecord] {
        values.values
            .filter { $0.scope == scope }
            .sorted { $0.id < $1.id }
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

    func integrationSnapshot() async -> IntegrationSettingsSnapshot {
        IntegrationSettingsSnapshot(
            configured: [
                .groq: Secrets.isGroqKeyValid,
                .tavily: Secrets.isTavilyKeyValid
            ]
        )
    }

    func updateIntegrationCredential(
        _ value: String,
        for credential: IntegrationCredential
    ) async {
        switch credential {
        case .groq:
            Secrets.groqApiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .tavily:
            Secrets.tavilyApiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
