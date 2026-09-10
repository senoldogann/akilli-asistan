import Foundation

enum MigrationStepState: String, Codable, Sendable, Equatable {
    case notStarted
    case running
    case completed
    case failed
}

actor MigrationStateStore {
    private let defaults: UserDefaults
    private let stateKey: String

    init(defaults: UserDefaults = .standard, namespace: String) {
        self.defaults = defaults
        self.stateKey = "v2.migration.\(namespace).state"
    }

    func state() -> MigrationStepState {
        guard let rawValue = defaults.string(forKey: stateKey),
              let state = MigrationStepState(rawValue: rawValue) else {
            return .notStarted
        }
        return state
    }

    func set(_ state: MigrationStepState) {
        defaults.set(state.rawValue, forKey: stateKey)
    }
}
