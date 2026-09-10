import Foundation

struct SettingsMigrationSnapshot: Sendable, Equatable {
    let state: MigrationStepState
    let migratedPresentationKeys: [String]
    let mappedAuthorityMode: AuthorityMode
}

enum SettingsMigrationError: Error, Equatable {
    case readbackMismatch(String)
}

actor SettingsMigrationCoordinator {
    private static let presentationKeys = [
        "fontSize",
        "fontDesign",
        "windowWidth",
        "windowHeight",
        "windowOpacity",
        "autoAnalyze",
        "useExternalAudio",
        "stealthModeEnabled",
        "audioLanguage",
        "streamingMode",
        "streamingSpeed",
        "userPersonaContext",
        "activeJobDescription",
        "teleprompterText",
        "selectedThemeName",
        "llm_provider"
    ]

    private let defaults: UserDefaults
    private let stateStore: MigrationStateStore
    private var lastMappedAuthorityMode: AuthorityMode = .manual
    private var migratedPresentationKeys: [String] = []

    init(
        defaults: UserDefaults = .standard,
        stateStore: MigrationStateStore
    ) {
        self.defaults = defaults
        self.stateStore = stateStore
    }

    static func mapLegacyApprovalMode(_ rawValue: String?) -> AuthorityMode {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            return .auto
        case "full":
            return .auto
        case "autonomous":
            return .autonomous
        case "ask", "manual", .none:
            return .manual
        default:
            return .manual
        }
    }

    func run() async throws {
        let currentState = await stateStore.state()
        lastMappedAuthorityMode = Self.mapLegacyApprovalMode(
            defaults.string(forKey: "commandApprovalMode")
        )

        if currentState == .completed {
            migratedPresentationKeys = Self.presentationKeys.filter {
                defaults.object(forKey: Self.destinationKey(for: $0)) != nil
            }
            return
        }

        await stateStore.set(.running)
        do {
            var copied: [String] = []
            for key in Self.presentationKeys {
                guard let legacyValue = defaults.object(forKey: key) else {
                    continue
                }

                let destinationKey = Self.destinationKey(for: key)
                if defaults.object(forKey: destinationKey) == nil {
                    defaults.set(legacyValue, forKey: destinationKey)
                }

                guard let restoredValue = defaults.object(forKey: destinationKey),
                      Self.valuesEqual(restoredValue, legacyValue) else {
                    throw SettingsMigrationError.readbackMismatch(key)
                }
                copied.append(key)
            }

            migratedPresentationKeys = copied.sorted()
            await stateStore.set(.completed)
        } catch {
            await stateStore.set(.failed)
            throw error
        }
    }

    func snapshot() async -> SettingsMigrationSnapshot {
        SettingsMigrationSnapshot(
            state: await stateStore.state(),
            migratedPresentationKeys: migratedPresentationKeys,
            mappedAuthorityMode: lastMappedAuthorityMode
        )
    }

    private static func destinationKey(for legacyKey: String) -> String {
        "v2.presentation.\(legacyKey)"
    }

    private static func valuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhsObject = lhs as? NSObject,
              let rhsObject = rhs as? NSObject else {
            return false
        }
        return lhsObject.isEqual(rhsObject)
    }
}
