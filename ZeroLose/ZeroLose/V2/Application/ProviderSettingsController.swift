import Foundation

nonisolated protocol ProviderSettingsControlling: Sendable {
    func isOpenAIKeyConfigured() async -> Bool
    func saveOpenAIAPIKey(_ value: String) async throws
    func removeOpenAIAPIKey() async throws
}

actor ProviderSettingsController: ProviderSettingsControlling {
    private let openAIKeyStore: any OpenAIKeyStoring

    init(openAIKeyStore: any OpenAIKeyStoring) {
        self.openAIKeyStore = openAIKeyStore
    }

    func isOpenAIKeyConfigured() async -> Bool {
        await openAIKeyStore.hasKey()
    }

    func saveOpenAIAPIKey(_ value: String) async throws {
        try await openAIKeyStore.store(value)
    }

    func removeOpenAIAPIKey() async throws {
        try await openAIKeyStore.remove()
    }
}
