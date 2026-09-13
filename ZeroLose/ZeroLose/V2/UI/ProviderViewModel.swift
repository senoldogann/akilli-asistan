import Foundation
import Observation

@MainActor
@Observable
final class ProviderViewModel {
    private(set) var snapshot: ProviderControlSnapshot
    private(set) var errorMessage: String?
    private(set) var canUseChat = false
    private(set) var canUseAgent = false
    private(set) var openAIKeyConfigured = false
    var openAIAPIKeyInput = ""

    private let controlPlane: ProviderControlPlane
    private let settingsController: any ProviderSettingsControlling

    init(
        controlPlane: ProviderControlPlane,
        settingsController: any ProviderSettingsControlling
    ) {
        self.controlPlane = controlPlane
        self.settingsController = settingsController
        snapshot = ProviderControlSnapshot(
            providers: [],
            selection: ProviderSelectionSnapshot(
                providerID: ModelProviderID(rawValue: "unavailable"),
                modelID: "default",
                revision: 0
            )
        )
    }

    var selectedProvider: ProviderPresentation? {
        snapshot.providers.first { $0.id == snapshot.selection.providerID }
    }

    var selectedModelID: String {
        snapshot.selection.modelID
    }

    var selectedReasoningEffort: String? {
        snapshot.selection.reasoningEffort
    }

    /// Reasoning levels published for the currently selected model. Empty until a
    /// model is chosen explicitly, because the levels belong to the model.
    var reasoningEffortOptions: [String] {
        guard snapshot.selection.modelID != "default",
              let provider = selectedProvider,
              let model = provider.models.first(where: {
                  $0.id == snapshot.selection.modelID
              }) else {
            return []
        }
        return model.reasoningEfforts
    }

    func refresh() async {
        errorMessage = nil
        let refreshed = await controlPlane.refresh()
        await publish(refreshed)
    }

    func selectProvider(_ id: ModelProviderID) async {
        do {
            errorMessage = nil
            let updated = try await controlPlane.selectProvider(id)
            await publish(updated)
        } catch {
            errorMessage = "Unable to select this provider."
        }
    }

    func selectModel(_ id: String) async {
        do {
            errorMessage = nil
            let updated = try await controlPlane.selectModel(id)
            await publish(updated)
        } catch {
            errorMessage = "Unable to select this model."
        }
    }

    func selectReasoningEffort(_ effort: String?) async {
        do {
            errorMessage = nil
            let updated = try await controlPlane.selectReasoningEffort(effort)
            await publish(updated)
        } catch {
            errorMessage = "Unable to select this reasoning level."
        }
    }

    func saveOpenAIAPIKey(_ value: String) async {
        openAIAPIKeyInput = ""
        do {
            errorMessage = nil
            try await settingsController.saveOpenAIAPIKey(value)
            await refresh()
        } catch {
            openAIKeyConfigured = await settingsController.isOpenAIKeyConfigured()
            errorMessage = "Unable to save the OpenAI API key." + Self.diagnosticSuffix(for: error)
        }
    }

    func removeOpenAIAPIKey() async {
        openAIAPIKeyInput = ""
        do {
            errorMessage = nil
            try await settingsController.removeOpenAIAPIKey()
            await refresh()
        } catch {
            openAIKeyConfigured = await settingsController.isOpenAIKeyConfigured()
            errorMessage = "Unable to remove the OpenAI API key." + Self.diagnosticSuffix(for: error)
        }
    }

    /// Non-secret diagnostic for a Keychain/key-store failure (for example an
    /// `OSStatus` code) so real failures stay debuggable without ever echoing the
    /// submitted key material.
    private static func diagnosticSuffix(for error: Error) -> String {
        guard let keyStoreError = error as? OpenAIKeyStoreError else { return "" }
        switch keyStoreError {
        case .keychainFailure(let status):
            return " (Keychain status \(status))"
        case .invalidKey:
            return " (key rejected)"
        case .missingKey:
            return " (no key stored)"
        }
    }

    private func publish(_ updated: ProviderControlSnapshot) async {
        snapshot = updated
        canUseChat = await controlPlane.canUseChat()
        canUseAgent = await controlPlane.canUseAgent()
        openAIKeyConfigured = await settingsController.isOpenAIKeyConfigured()
    }
}
