import Foundation
import Observation

enum CredentialProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case openCodeZen = "opencode_zen"
    case openCodeGo = "opencode_go"
    case ollama = "ollama"
    case groq = "groq"
    case tavily = "tavily"
}

struct CredentialSettingsSnapshot: Sendable, Equatable {
    let values: [CredentialProvider: String]
    let validity: [CredentialProvider: Bool]
    let models: [CredentialProvider: [String]]

    static let empty = CredentialSettingsSnapshot(values: [:], validity: [:], models: [:])
}

@MainActor
protocol SettingsDataControlling: AnyObject {
    func credentialSnapshot() async -> CredentialSettingsSnapshot
    func updateCredential(_ value: String, for provider: CredentialProvider) async
    func resetCredentials() async
    func refreshModels(for provider: CredentialProvider) async -> [String]
    func memoryCount() async throws -> Int
    func clearMemory() async throws -> Int
}

struct SettingsProjectionSnapshot: Sendable, Equatable {
    let authorityMode: AuthorityMode
}

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var authorityMode: AuthorityMode = .manual
    private(set) var credentialSnapshot: CredentialSettingsSnapshot = .empty
    private(set) var memoryChunkCount = 0
    private(set) var memoryStatus = ""

    private let commandSender: any ApplicationCommandSending
    private let dataController: (any SettingsDataControlling)?

    init(
        commandSender: any ApplicationCommandSending,
        dataController: (any SettingsDataControlling)? = nil
    ) {
        self.commandSender = commandSender
        self.dataController = dataController
    }

    func apply(_ snapshot: SettingsProjectionSnapshot) {
        authorityMode = snapshot.authorityMode
    }

    func setAuthorityMode(_ mode: AuthorityMode) async throws {
        guard mode != .fullAccess else { return }
        try await commandSender.send(.changeAuthorityMode(mode))
    }

    func reloadCredentials() async -> CredentialSettingsSnapshot {
        guard let dataController else { return credentialSnapshot }
        let snapshot = await dataController.credentialSnapshot()
        credentialSnapshot = snapshot
        return snapshot
    }

    func updateCredential(_ value: String, for provider: CredentialProvider) async {
        guard let dataController else { return }
        await dataController.updateCredential(value, for: provider)
        _ = await reloadCredentials()
    }

    func resetCredentials() async -> CredentialSettingsSnapshot {
        guard let dataController else { return credentialSnapshot }
        await dataController.resetCredentials()
        return await reloadCredentials()
    }

    @discardableResult
    func refreshModels(for provider: CredentialProvider) async -> [String] {
        guard let dataController else {
            return credentialSnapshot.models[provider] ?? []
        }
        let models = await dataController.refreshModels(for: provider)
        var updatedModels = credentialSnapshot.models
        updatedModels[provider] = models
        credentialSnapshot = CredentialSettingsSnapshot(
            values: credentialSnapshot.values,
            validity: credentialSnapshot.validity,
            models: updatedModels
        )
        return models
    }

    func models(for provider: CredentialProvider) -> [String] {
        credentialSnapshot.models[provider] ?? []
    }

    func isCredentialValid(for provider: CredentialProvider) -> Bool {
        credentialSnapshot.validity[provider] ?? false
    }

    func refreshMemoryState() async {
        guard let dataController else { return }
        do {
            let count = try await dataController.memoryCount()
            memoryChunkCount = count
            memoryStatus = count > 0 ? "Memory ready." : "No indexed memory yet."
        } catch {
            memoryChunkCount = 0
            memoryStatus = "Memory status unavailable: \(error.localizedDescription)"
        }
    }

    func clearMemory() async {
        guard let dataController else { return }
        memoryStatus = "Clearing vector database and session context..."
        do {
            memoryChunkCount = try await dataController.clearMemory()
            memoryStatus = "Memory cleared successfully."
        } catch {
            memoryStatus = "Failed to clear memory: \(error.localizedDescription)"
        }
    }
}
