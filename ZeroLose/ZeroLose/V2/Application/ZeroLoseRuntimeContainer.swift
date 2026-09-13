import ApplicationServices
import ComputerAgentMacOS
import CoreGraphics
import CryptoKit
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

        let providerIDKey = "v2.modelProviderID"
        let defaultModelIDKey = "v2.modelDefaultID"
        let defaults = UserDefaults.standard
        let storedProviderID = defaults
            .string(forKey: providerIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProviderRawValue: String
        if let storedProviderID, !storedProviderID.isEmpty {
            selectedProviderRawValue = storedProviderID
        } else {
            selectedProviderRawValue = "codex"
            defaults.set(selectedProviderRawValue, forKey: providerIDKey)
        }
        let selectedProviderID = ModelProviderID(rawValue: selectedProviderRawValue)

        let storedDefaultModelID = defaults
            .string(forKey: defaultModelIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if storedDefaultModelID?.isEmpty != false {
            defaults.set("default", forKey: defaultModelIDKey)
        }

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
            selectedProviderID: selectedProviderID
        )
        let providerControlPlane = ProviderControlPlane(
            fabric: modelProviderFabric,
            persistence: UserDefaultsProviderSelectionStore(defaults: defaults)
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

private enum LiveMacOSComputerObservationSourceError: Error {
    case unavailable
}

private struct LiveMacOSComputerObservationSourceProvider: MacOSComputerObservationSourceProviding {
    private struct WindowCandidate {
        let processID: Int32
        let windowID: UInt32
        let frame: CGRect
    }

    private struct ObservationSnapshot {
        let screen: WindowCandidate
        let accessibility: WindowCandidate
    }

    static func makeIfReady() -> LiveMacOSComputerObservationSourceProvider? {
        guard CGPreflightScreenCaptureAccess(),
              AXIsProcessTrusted(),
              let snapshot = try? currentSnapshot(),
              snapshot.screen.processID == snapshot.accessibility.processID,
              snapshot.screen.windowID == snapshot.accessibility.windowID else {
            return nil
        }
        return LiveMacOSComputerObservationSourceProvider()
    }

    func currentObservationSources() async throws -> MacOSComputerObservationSources {
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
            throw LiveMacOSComputerObservationSourceError.unavailable
        }

        let snapshot = try Self.currentSnapshot()
        return MacOSComputerObservationSources(
            screen: ComputerObservationSource(
                processID: snapshot.screen.processID,
                windowID: snapshot.screen.windowID,
                provenance: "macos:screen-window",
                tainted: false,
                confidence: 1.0
            ),
            accessibility: ComputerObservationSource(
                processID: snapshot.accessibility.processID,
                windowID: snapshot.accessibility.windowID,
                provenance: "macos:accessibility-focus",
                tainted: false,
                confidence: 1.0
            )
        )
    }

    private static func currentSnapshot() throws -> ObservationSnapshot {
        let candidates = windowCandidates()
        guard let screen = candidates.first,
              let accessibilityContext = focusedAccessibilityContext(),
              let accessibility = candidates.first(where: {
                  $0.processID == accessibilityContext.processID
                      && framesMatch($0.frame, accessibilityContext.frame)
              }) else {
            throw LiveMacOSComputerObservationSourceError.unavailable
        }

        return ObservationSnapshot(
            screen: screen,
            accessibility: accessibility
        )
    }

    private static func windowCandidates() -> [WindowCandidate] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber,
                  let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber,
                  width.doubleValue > 1,
                  height.doubleValue > 1 else {
                return nil
            }

            let frame = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )

            return WindowCandidate(
                processID: ownerPID.int32Value,
                windowID: windowNumber.uint32Value,
                frame: frame
            )
        }
    }

    private static func focusedAccessibilityContext() -> (processID: Int32, frame: CGRect)? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let application = attribute(
            systemWide,
            kAXFocusedApplicationAttribute as CFString
        ) as! AXUIElement? else {
            return nil
        }

        var processID: pid_t = 0
        guard AXUIElementGetPid(application, &processID) == .success,
              let focusedWindow = attribute(
                  application,
                  kAXFocusedWindowAttribute as CFString
              ) as! AXUIElement?,
              let frame = frame(of: focusedWindow) else {
            return nil
        }

        return (Int32(processID), frame)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(
            element,
            kAXPositionAttribute as CFString
        ) as! AXValue?,
        let sizeValue = attribute(
            element,
            kAXSizeAttribute as CFString
        ) as! AXValue?,
        AXValueGetType(positionValue) == .cgPoint,
        AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return error == .success ? value : nil
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
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
