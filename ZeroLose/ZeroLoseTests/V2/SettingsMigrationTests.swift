import Foundation
import XCTest
@testable import ZeroLose

final class SettingsMigrationTests: XCTestCase {
    func testLegacyFullDoesNotMigrateToV2FullAccess() {
        XCTAssertEqual(
            SettingsMigrationCoordinator.mapLegacyApprovalMode("full"),
            .auto
        )
        XCTAssertEqual(
            SettingsMigrationCoordinator.mapLegacyApprovalMode("ask"),
            .manual
        )
        XCTAssertEqual(
            SettingsMigrationCoordinator.mapLegacyApprovalMode("unknown"),
            .manual
        )
    }

    func testSettingsMigrationIsIdempotentAndReadbackVerified() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(16.0, forKey: "fontSize")
        defaults.set("Blue", forKey: "selectedThemeName")
        defaults.set("full", forKey: "commandApprovalMode")

        let stateStore = MigrationStateStore(defaults: defaults, namespace: "settings-test")
        let coordinator = SettingsMigrationCoordinator(defaults: defaults, stateStore: stateStore)

        try await coordinator.run()
        let first = await coordinator.snapshot()
        defaults.set(22.0, forKey: "fontSize")
        try await coordinator.run()
        let second = await coordinator.snapshot()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.state, .completed)
        XCTAssertEqual(first.mappedAuthorityMode, .auto)
        XCTAssertEqual(defaults.double(forKey: "v2.presentation.fontSize"), 16.0)
        XCTAssertEqual(defaults.string(forKey: "v2.presentation.selectedThemeName"), "Blue")
    }

    func testMigrationDoesNotPersistAuthorityOrCredentialMaterial() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("full", forKey: "commandApprovalMode")
        defaults.set("legacy-secret-value", forKey: "OPENAI_API_KEY")

        let stateStore = MigrationStateStore(defaults: defaults, namespace: "settings-security-test")
        let coordinator = SettingsMigrationCoordinator(defaults: defaults, stateStore: stateStore)
        try await coordinator.run()

        XCTAssertNil(defaults.object(forKey: "v2.authorityMode"))
        XCTAssertNil(defaults.object(forKey: "v2.presentation.OPENAI_API_KEY"))
        XCTAssertNil(defaults.object(forKey: "v2.presentation.openai_api_key"))
        XCTAssertEqual(defaults.string(forKey: "OPENAI_API_KEY"), "legacy-secret-value")
    }

    func testRunningStateIsRestartSafeAndCanResume() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: "autoAnalyze")

        let stateStore = MigrationStateStore(defaults: defaults, namespace: "settings-restart-test")
        await stateStore.set(.running)

        let coordinator = SettingsMigrationCoordinator(defaults: defaults, stateStore: stateStore)
        try await coordinator.run()

        let finalState = await stateStore.state()
        XCTAssertEqual(finalState, .completed)
        XCTAssertTrue(defaults.bool(forKey: "v2.presentation.autoAnalyze"))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ZeroLose.SettingsMigrationTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func clear(_ defaults: UserDefaults) {
        if let suite = defaults.volatileDomainNames.first(where: { $0.hasPrefix("ZeroLose.SettingsMigrationTests") }) {
            defaults.removePersistentDomain(forName: suite)
        }
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
