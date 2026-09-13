import Foundation
import Observation

nonisolated enum IntegrationCredential: String, CaseIterable, Sendable {
    case groq = "groq"
    case tavily = "tavily"
}

nonisolated struct IntegrationSettingsSnapshot: Sendable, Equatable {
    let configured: [IntegrationCredential: Bool]

    static let empty = IntegrationSettingsSnapshot(configured: [:])
}

@MainActor
protocol SettingsDataControlling: AnyObject {
    func integrationSnapshot() async -> IntegrationSettingsSnapshot
    func updateIntegrationCredential(
        _ value: String,
        for credential: IntegrationCredential
    ) async
    func memoryCount() async throws -> Int
    func clearMemory() async throws -> Int
}

nonisolated struct SettingsProjectionSnapshot: Sendable, Equatable {
    let authorityMode: AuthorityMode
}

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var authorityMode: AuthorityMode = .manual
    private(set) var integrationSnapshot: IntegrationSettingsSnapshot = .empty
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

    func reloadIntegrations() async -> IntegrationSettingsSnapshot {
        guard let dataController else { return integrationSnapshot }
        let snapshot = await dataController.integrationSnapshot()
        integrationSnapshot = snapshot
        return snapshot
    }

    func saveIntegrationCredential(
        _ value: String,
        for credential: IntegrationCredential
    ) async {
        guard let dataController else { return }
        await dataController.updateIntegrationCredential(value, for: credential)
        _ = await reloadIntegrations()
    }

    func removeIntegrationCredential(_ credential: IntegrationCredential) async {
        guard let dataController else { return }
        await dataController.updateIntegrationCredential("", for: credential)
        _ = await reloadIntegrations()
    }

    func isIntegrationConfigured(_ credential: IntegrationCredential) -> Bool {
        integrationSnapshot.configured[credential] ?? false
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
        memoryStatus = "Clearing memory..."
        do {
            memoryChunkCount = try await dataController.clearMemory()
            memoryStatus = "Memory cleared successfully."
        } catch {
            memoryStatus = "Failed to clear memory: \(error.localizedDescription)"
        }
    }
}
