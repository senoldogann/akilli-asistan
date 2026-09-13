import XCTest
@testable import ZeroLose

@MainActor
final class ProviderViewModelTests: XCTestCase {
    func testRefreshPublishesBackendProviderAndModelState() async {
        let provider = ProviderViewModelTestProvider(
            id: "openai-api",
            displayName: "OpenAI API",
            availability: .ready,
            capabilities: [.textStreaming, .jsonOutput],
            models: ["gpt-5.6"]
        )
        let controlPlane = makeControlPlane(
            providers: [provider],
            providerID: "openai-api",
            modelID: "gpt-5.6"
        )
        let credentials = ProviderSettingsTestController(configured: true)
        let viewModel = ProviderViewModel(
            controlPlane: controlPlane,
            settingsController: credentials
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedProvider?.id, provider.id)
        XCTAssertEqual(viewModel.selectedProvider?.displayName, "OpenAI API")
        XCTAssertEqual(viewModel.selectedProvider?.models.map(\.id), ["gpt-5.6"])
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.6")
        XCTAssertTrue(viewModel.canUseChat)
        XCTAssertTrue(viewModel.canUseAgent)
        XCTAssertTrue(viewModel.openAIKeyConfigured)
    }

    func testProviderAndModelCommandsUpdateOneSharedSnapshot() async {
        let first = ProviderViewModelTestProvider(id: "first", models: ["first-model"])
        let second = ProviderViewModelTestProvider(
            id: "second",
            capabilities: [.textStreaming, .jsonOutput],
            models: ["second-model"]
        )
        let controlPlane = makeControlPlane(
            providers: [first, second],
            providerID: "first",
            modelID: "first-model"
        )
        let viewModel = ProviderViewModel(
            controlPlane: controlPlane,
            settingsController: ProviderSettingsTestController()
        )
        await viewModel.refresh()

        await viewModel.selectProvider(second.id)
        XCTAssertEqual(viewModel.snapshot.selection.providerID, second.id)
        XCTAssertEqual(viewModel.selectedModelID, "default")

        await viewModel.selectModel("second-model")
        XCTAssertEqual(viewModel.snapshot.selection.providerID, second.id)
        XCTAssertEqual(viewModel.selectedModelID, "second-model")
        XCTAssertTrue(viewModel.canUseAgent)
    }

    func testAvailabilityUsesRealProviderStatusAndCapabilities() async {
        let unavailable = ProviderViewModelTestProvider(
            id: "unavailable",
            availability: .loginRequired,
            capabilities: [.textStreaming, .jsonOutput],
            models: ["json-model"]
        )
        let textOnly = ProviderViewModelTestProvider(
            id: "text-only",
            availability: .ready,
            capabilities: [.textStreaming],
            models: ["text-model"]
        )
        let controlPlane = makeControlPlane(
            providers: [unavailable, textOnly],
            providerID: "unavailable",
            modelID: "json-model"
        )
        let viewModel = ProviderViewModel(
            controlPlane: controlPlane,
            settingsController: ProviderSettingsTestController()
        )

        await viewModel.refresh()
        XCTAssertFalse(viewModel.canUseChat)
        XCTAssertFalse(viewModel.canUseAgent)

        await viewModel.selectProvider(textOnly.id)
        await viewModel.selectModel("text-model")
        XCTAssertTrue(viewModel.canUseChat)
        XCTAssertFalse(viewModel.canUseAgent)
    }

    func testCredentialErrorsNeverEchoSubmittedKey() async {
        let secret = "sk-super-secret-never-render"
        let provider = ProviderViewModelTestProvider(id: "openai-api", models: ["default"])
        let credentials = ProviderSettingsTestController(
            configured: false,
            saveError: OpenAIKeyStoreError.keychainFailure(status: -50)
        )
        let viewModel = ProviderViewModel(
            controlPlane: makeControlPlane(
                providers: [provider],
                providerID: "openai-api",
                modelID: "default"
            ),
            settingsController: credentials
        )
        viewModel.openAIAPIKeyInput = secret

        await viewModel.saveOpenAIAPIKey(secret)

        XCTAssertEqual(viewModel.openAIAPIKeyInput, "")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.errorMessage?.contains(secret) == true)
        XCTAssertFalse(String(reflecting: viewModel.snapshot).contains(secret))
    }

    func testSavingAndRemovingKeyExposeOnlyConfiguredState() async {
        let provider = ProviderViewModelTestProvider(id: "openai-api", models: ["default"])
        let credentials = ProviderSettingsTestController(configured: false)
        let viewModel = ProviderViewModel(
            controlPlane: makeControlPlane(
                providers: [provider],
                providerID: "openai-api",
                modelID: "default"
            ),
            settingsController: credentials
        )
        viewModel.openAIAPIKeyInput = "sk-ephemeral"

        await viewModel.saveOpenAIAPIKey(viewModel.openAIAPIKeyInput)
        XCTAssertEqual(viewModel.openAIAPIKeyInput, "")
        XCTAssertTrue(viewModel.openAIKeyConfigured)

        await viewModel.removeOpenAIAPIKey()
        XCTAssertFalse(viewModel.openAIKeyConfigured)
    }

    private func makeControlPlane(
        providers: [any ModelProvider],
        providerID: String,
        modelID: String
    ) -> ProviderControlPlane {
        let fabric = ModelProviderFabric(
            providers: providers,
            selectedProviderID: ModelProviderID(rawValue: providerID)
        )
        return ProviderControlPlane(
            fabric: fabric,
            persistence: ProviderViewModelSelectionStore(
                providerID: providerID,
                modelID: modelID
            )
        )
    }
}

private actor ProviderViewModelSelectionStore: ProviderSelectionPersisting {
    private var providerID: String?
    private var modelID: String?

    init(providerID: String?, modelID: String?) {
        self.providerID = providerID
        self.modelID = modelID
    }

    func loadProviderID() async -> String? { providerID }
    func loadModelID() async -> String? { modelID }

    func save(providerID: String, modelID: String) async {
        self.providerID = providerID
        self.modelID = modelID
    }
}

private actor ProviderSettingsTestController: ProviderSettingsControlling {
    private var configured: Bool
    private let saveError: Error?

    init(configured: Bool = false, saveError: Error? = nil) {
        self.configured = configured
        self.saveError = saveError
    }

    func isOpenAIKeyConfigured() async -> Bool { configured }

    func saveOpenAIAPIKey(_ value: String) async throws {
        if let saveError { throw saveError }
        configured = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func removeOpenAIAPIKey() async throws {
        configured = false
    }
}

private final class ProviderViewModelTestProvider: ModelProvider, Sendable {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities
    private let availability: ProviderAvailability
    private let modelIDs: [String]

    init(
        id: String,
        displayName: String? = nil,
        availability: ProviderAvailability = .ready,
        capabilities: ModelCapabilities = [.textStreaming],
        models: [String]
    ) {
        self.id = ModelProviderID(rawValue: id)
        self.displayName = displayName ?? id
        self.availability = availability
        self.capabilities = capabilities
        self.modelIDs = models
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: availability
        )
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        modelIDs.map {
            ModelDescriptor(
                id: $0,
                displayName: $0,
                providerID: id,
                capabilities: capabilities
            )
        }
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed)
            continuation.finish()
        }
    }

    func cancel(sessionID: ModelSessionID) async {}
}
