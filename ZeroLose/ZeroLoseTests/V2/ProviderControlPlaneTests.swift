import Foundation
import XCTest
@testable import ZeroLose

final class ProviderControlPlaneTests: XCTestCase {
    func testValidPersistedProviderAndModelRestoreUnchanged() async throws {
        let openAI = ConfigurableControlPlaneProvider(
            id: "openai-api",
            capabilities: [.textStreaming, .jsonOutput],
            models: ["gpt-5.6"]
        )
        let codex = ConfigurableControlPlaneProvider(id: "codex")
        let fabric = ModelProviderFabric(
            providers: [codex, openAI],
            selectedProviderID: codex.id
        )
        let store = MemoryProviderSelectionStore(
            providerID: "openai-api",
            modelID: "gpt-5.6"
        )
        let controlPlane = ProviderControlPlane(fabric: fabric, persistence: store)

        let snapshot = await controlPlane.snapshot()

        XCTAssertEqual(snapshot.selection.providerID, openAI.id)
        XCTAssertEqual(snapshot.selection.modelID, "gpt-5.6")
        XCTAssertEqual(snapshot.selection.revision, 0)
        let selectedStatus = await fabric.selectedStatus()
        XCTAssertEqual(selectedStatus.providerID, openAI.id)
    }

    func testUnknownPersistedProviderFallsBackToCodexWhenRegistered() async {
        let claude = ConfigurableControlPlaneProvider(id: "claude")
        let codex = ConfigurableControlPlaneProvider(id: "codex")
        let fabric = ModelProviderFabric(
            providers: [claude, codex],
            selectedProviderID: claude.id
        )
        let store = MemoryProviderSelectionStore(providerID: "removed", modelID: "old-model")
        let controlPlane = ProviderControlPlane(fabric: fabric, persistence: store)

        let snapshot = await controlPlane.snapshot()
        let persisted = await store.values()

        XCTAssertEqual(snapshot.selection.providerID, codex.id)
        XCTAssertEqual(snapshot.selection.modelID, "default")
        XCTAssertEqual(persisted.providerID, "codex")
        XCTAssertEqual(persisted.modelID, "default")
    }

    func testUnknownPersistedProviderFallsBackToFirstSortedWhenCodexMissing() async {
        let zeta = ConfigurableControlPlaneProvider(id: "zeta")
        let alpha = ConfigurableControlPlaneProvider(id: "alpha")
        let fabric = ModelProviderFabric(
            providers: [zeta, alpha],
            selectedProviderID: zeta.id
        )
        let store = MemoryProviderSelectionStore(providerID: "removed", modelID: nil)
        let controlPlane = ProviderControlPlane(fabric: fabric, persistence: store)

        let snapshot = await controlPlane.snapshot()

        XCTAssertEqual(snapshot.selection.providerID, alpha.id)
        XCTAssertEqual(snapshot.selection.modelID, "default")
    }

    func testSelectedProviderPresentationUsesAdapterStatusAndCapabilities() async throws {
        let provider = ConfigurableControlPlaneProvider(
            id: "claude",
            displayName: "Claude CLI",
            availability: .loginRequired,
            capabilities: [.textStreaming, .reasoningControl],
            models: []
        )
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: provider.id
        )
        let controlPlane = ProviderControlPlane(
            fabric: fabric,
            persistence: MemoryProviderSelectionStore(providerID: "claude", modelID: "default")
        )

        let snapshot = await controlPlane.refresh()
        let presentation = try XCTUnwrap(snapshot.providers.first)

        XCTAssertEqual(presentation.id, provider.id)
        XCTAssertEqual(presentation.displayName, "Claude CLI")
        XCTAssertEqual(presentation.availability, .loginRequired)
        XCTAssertEqual(presentation.capabilities, [.textStreaming, .reasoningControl])
        XCTAssertEqual(presentation.modelDiscoveryState, .loaded)
        XCTAssertTrue(presentation.models.isEmpty)
        let canUseChat = await controlPlane.canUseChat()
        XCTAssertFalse(canUseChat)
    }

    func testProviderSwitchPersistsAndResetsModelToDefault() async throws {
        let first = ConfigurableControlPlaneProvider(id: "first", models: ["first-model"])
        let second = ConfigurableControlPlaneProvider(id: "second", models: ["second-model"])
        let fabric = ModelProviderFabric(
            providers: [first, second],
            selectedProviderID: first.id
        )
        let store = MemoryProviderSelectionStore(providerID: "first", modelID: "first-model")
        let controlPlane = ProviderControlPlane(fabric: fabric, persistence: store)
        _ = await controlPlane.snapshot()

        let changed = try await controlPlane.selectProvider(second.id)
        let persisted = await store.values()

        XCTAssertEqual(changed.selection.providerID, second.id)
        XCTAssertEqual(changed.selection.modelID, "default")
        XCTAssertEqual(changed.selection.revision, 1)
        XCTAssertEqual(persisted.providerID, "second")
        XCTAssertEqual(persisted.modelID, "default")
        let selectedStatus = await fabric.selectedStatus()
        XCTAssertEqual(selectedStatus.providerID, second.id)
    }

    func testOnlyActiveProviderDiscoveredModelCanBeSelected() async throws {
        let alpha = ConfigurableControlPlaneProvider(id: "alpha", models: ["alpha-model"])
        let beta = ConfigurableControlPlaneProvider(id: "beta", models: ["beta-model"])
        let fabric = ModelProviderFabric(
            providers: [alpha, beta],
            selectedProviderID: alpha.id
        )
        let controlPlane = ProviderControlPlane(
            fabric: fabric,
            persistence: MemoryProviderSelectionStore(providerID: "alpha", modelID: "default")
        )
        _ = await controlPlane.refresh()

        let selected = try await controlPlane.selectModel("alpha-model")
        XCTAssertEqual(selected.selection.modelID, "alpha-model")

        do {
            _ = try await controlPlane.selectModel("beta-model")
            XCTFail("expected model selection to fail closed")
        } catch let error as ProviderControlPlaneError {
            XCTAssertEqual(error, .invalidModel(providerID: alpha.id, modelID: "beta-model"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDiscoveryFailureDoesNotFabricateModels() async {
        let provider = ConfigurableControlPlaneProvider(
            id: "broken",
            discoveryError: .failed
        )
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: provider.id
        )
        let controlPlane = ProviderControlPlane(
            fabric: fabric,
            persistence: MemoryProviderSelectionStore(providerID: "broken", modelID: "default")
        )

        let snapshot = await controlPlane.refresh()
        let presentation = snapshot.providers[0]

        XCTAssertEqual(presentation.modelDiscoveryState, .failed)
        XCTAssertTrue(presentation.models.isEmpty)
        XCTAssertEqual(snapshot.selection.modelID, "default")
    }

    func testDefaultSelectionIsExplicitAndDoesNotRequireFabricatedCatalog() async throws {
        let provider = ConfigurableControlPlaneProvider(id: "codex", models: [])
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: provider.id
        )
        let controlPlane = ProviderControlPlane(
            fabric: fabric,
            persistence: MemoryProviderSelectionStore(providerID: "codex", modelID: "default")
        )

        let snapshot = try await controlPlane.selectModel("default")

        XCTAssertEqual(snapshot.selection.modelID, "default")
        XCTAssertTrue(snapshot.providers[0].models.isEmpty)
    }

    func testSelectionRevisionChangesOnlyForMaterialSelectionChanges() async throws {
        let provider = ConfigurableControlPlaneProvider(id: "codex", models: ["m1"])
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: provider.id
        )
        let controlPlane = ProviderControlPlane(
            fabric: fabric,
            persistence: MemoryProviderSelectionStore(providerID: "codex", modelID: "default")
        )

        let initial = await controlPlane.snapshot()
        let sameProvider = try await controlPlane.selectProvider(provider.id)
        let model = try await controlPlane.selectModel("m1")
        let sameModel = try await controlPlane.selectModel("m1")
        _ = await controlPlane.refresh()
        let afterRefresh = await controlPlane.currentSelection()

        XCTAssertEqual(initial.selection.revision, 0)
        XCTAssertEqual(sameProvider.selection.revision, 0)
        XCTAssertEqual(model.selection.revision, 1)
        XCTAssertEqual(sameModel.selection.revision, 1)
        XCTAssertEqual(afterRefresh.revision, 1)
    }

    func testAgentAvailabilityRequiresJSONOutputOnSelectedModel() async {
        let textOnly = ConfigurableControlPlaneProvider(
            id: "codex",
            availability: .detected,
            capabilities: [.textStreaming],
            models: []
        )
        let json = ConfigurableControlPlaneProvider(
            id: "openai-api",
            availability: .ready,
            capabilities: [.textStreaming, .jsonOutput],
            models: ["gpt-5.6"],
            modelCapabilities: [.textStreaming, .jsonOutput]
        )
        let fabric = ModelProviderFabric(
            providers: [textOnly, json],
            selectedProviderID: textOnly.id
        )
        let store = MemoryProviderSelectionStore(providerID: "codex", modelID: "default")
        let controlPlane = ProviderControlPlane(fabric: fabric, persistence: store)

        _ = await controlPlane.refresh()
        let initialChatAvailable = await controlPlane.canUseChat()
        let initialAgentAvailable = await controlPlane.canUseAgent()
        XCTAssertTrue(initialChatAvailable)
        XCTAssertFalse(initialAgentAvailable)

        _ = try? await controlPlane.selectProvider(json.id)
        _ = try? await controlPlane.selectModel("gpt-5.6")
        let selectedAgentAvailable = await controlPlane.canUseAgent()
        XCTAssertTrue(selectedAgentAvailable)
    }

    func testControlSnapshotContainsOnlyNonSecretProviderMetadata() async {
        let provider = ConfigurableControlPlaneProvider(id: "openai-api", models: ["gpt-5.6"])
        let fabric = ModelProviderFabric(providers: [provider], selectedProviderID: provider.id)
        let controlPlane = ProviderControlPlane(
            fabric: fabric,
            persistence: MemoryProviderSelectionStore(providerID: "openai-api", modelID: "gpt-5.6")
        )

        let snapshot = await controlPlane.snapshot()
        let reflected = String(reflecting: snapshot)

        XCTAssertFalse(reflected.contains("sk-secret"))
        XCTAssertFalse(reflected.lowercased().contains("apikey"))
        XCTAssertFalse(reflected.lowercased().contains("credentialvalue"))
    }
}

private actor MemoryProviderSelectionStore: ProviderSelectionPersisting {
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

    func values() -> (providerID: String?, modelID: String?) {
        (providerID, modelID)
    }
}

private enum ConfigurableControlPlaneProviderError: Error {
    case failed
}

private final class ConfigurableControlPlaneProvider: ModelProvider, Sendable {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities
    private let availability: ProviderAvailability
    private let modelIDs: [String]
    private let modelCapabilities: ModelCapabilities
    private let discoveryError: ConfigurableControlPlaneProviderError?

    init(
        id: String,
        displayName: String? = nil,
        availability: ProviderAvailability = .ready,
        capabilities: ModelCapabilities = [.textStreaming],
        models: [String] = ["default"],
        modelCapabilities: ModelCapabilities? = nil,
        discoveryError: ConfigurableControlPlaneProviderError? = nil
    ) {
        self.id = ModelProviderID(rawValue: id)
        self.displayName = displayName ?? id.capitalized
        self.availability = availability
        self.capabilities = capabilities
        modelIDs = models
        self.modelCapabilities = modelCapabilities ?? capabilities
        self.discoveryError = discoveryError
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: availability
        )
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        if let discoveryError { throw discoveryError }
        return modelIDs.map {
            ModelDescriptor(
                id: $0,
                displayName: $0,
                providerID: id,
                capabilities: modelCapabilities
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
