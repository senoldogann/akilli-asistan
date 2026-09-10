import Observation

struct SettingsProjectionSnapshot: Sendable, Equatable {
    let authorityMode: AuthorityMode
}

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var authorityMode: AuthorityMode = .manual
    private let commandSender: any ApplicationCommandSending

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: SettingsProjectionSnapshot) {
        authorityMode = snapshot.authorityMode
    }

    func setAuthorityMode(_ mode: AuthorityMode) async throws {
        try await commandSender.send(.changeAuthorityMode(mode))
    }
}
