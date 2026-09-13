import Foundation
import XCTest
@testable import ZeroLose

final class LegacyDemolitionTests: XCTestCase {
    func testProductionTreeContainsNoLegacyActionExecutionTokens() throws {
        let forbidden = [
            "[" + "ACTION:",
            "action" + "Regex",
            "handle" + "Actions("
        ]

        for source in try productionSwiftSources() {
            for token in forbidden {
                XCTAssertFalse(
                    source.contents.contains(token),
                    "\(source.path) still contains legacy execution token \(token)"
                )
            }
        }
    }

    func testRuntimeContainerDoesNotBridgeCommandsBackIntoGhostRuntime() throws {
        let source = try productionSource("V2/Application/ZeroLoseRuntimeContainer.swift")
        for forbidden in [
            "LegacyRuntime" + "CommandController",
            "LegacyShell" + "FeatureAdapter",
            "Ghost" + "ViewModel",
            ".ghost" + "ViewModel",
            ".zero" + "Operator"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Runtime container still references \(forbidden)")
        }
    }

    func testRuntimeContainerComposesAuthoritativeV2ToolFabric() throws {
        let source = try productionSource("V2/Application/ZeroLoseRuntimeContainer.swift")
        XCTAssertTrue(
            source.contains("ToolFabric("),
            "Production composition root must instantiate the V2 ToolFabric"
        )
        XCTAssertTrue(
            source.contains("V2NativeToolRuntime("),
            "Production composition root must bind model-native calls to the V2 tool runtime"
        )
        XCTAssertTrue(
            source.contains("V2BuiltinToolCatalog.descriptors"),
            "Production composition root must bootstrap the verified V2 builtin catalog"
        )
        XCTAssertFalse(
            source.contains("UnavailableToolManagementController"),
            "Production composition root must not expose a placeholder tool controller after cutover"
        )
    }

    func testUserGoalCannotBypassAutonomousRuntimeThroughChatPath() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        XCTAssertFalse(
            source.contains("processText(text, source: \"V2 Goal\")"),
            "submitUserGoal must not downgrade autonomous work into the chat execution path"
        )
    }

    /// The shell chat turn must delegate to the V2 request coordinator and must
    /// not own a legacy model bridge or a legacy tool registry. Tool exposure is
    /// owned by the V2 tool runtime (agent planning + facade), not the shell.
    func testShellRuntimeDelegatesModelTurnsToV2CoordinatorWithoutLegacyBridge() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        XCTAssertTrue(source.contains("requestCoordinator.stream("))
        XCTAssertTrue(source.contains("private let requestCoordinator: RequestCoordinator"))
        XCTAssertTrue(source.contains("nativeToolRuntime.setAuthorityMode("))
        for forbidden in [
            "intelligence" + "Service",
            "Ollama" + "Service",
            "AgentCapability" + "Registry",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Shell runtime still references \(forbidden)")
        }
    }

    func testShellViewModelExposesNoPhysicalExecutionCommands() throws {
        let source = try productionSource("V2/UI/ShellViewModel.swift")
        for forbidden in [
            "testComputer" + "UseSnapshot",
            "verifyComputer" + "UseEndToEnd",
            "active" + "Action"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Shell UI still exposes \(forbidden)")
        }
    }

    func testDependencyContainerNoLongerOwnsLegacyMutationExecutors() throws {
        let source = try productionSource("Services/DependencyContainer.swift")
        for forbidden in [
            "Zero" + "Operator",
            "Computer" + "UseService()",
            "Browser" + "CDPService()"
        ] {
            XCTAssertFalse(source.contains(forbidden), "DependencyContainer still owns \(forbidden)")
        }
    }

    /// The legacy model bridge is fully retired: no provider service may own tool
    /// selection, and the interview-era prompt builder is gone from disk.
    func testLegacyModelBridgeAndAutomationPromptAreRemovedFromDisk() {
        let productionRoot = repositoryRoot().appendingPathComponent("ZeroLose")
        for relativePath in [
            "Services/Ollama" + "Service.swift",
            "Services/Intelligence" + "Service.swift",
        ] {
            let url = productionRoot.appendingPathComponent(relativePath)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Retired legacy model bridge still exists: \(relativePath)"
            )
        }
    }

    func testObsoleteLegacyExecutionSourcesAreRemoved() {
        let obsoleteSources = [
            "ViewModels/Ghost" + "ViewModel.swift",
            "Services/Zero" + "Operator.swift",
            "Services/Computer" + "UseService.swift",
            "Services/Browser" + "CDPService.swift",
            "Services/Automation" + "Library.swift",
            "V2/Legacy/AgentCapability" + "RegistryAdapter.swift"
        ]

        for relativePath in obsoleteSources {
            let url = repositoryRoot().appendingPathComponent("ZeroLose/\(relativePath)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Obsolete legacy execution source still exists: \(relativePath)"
            )
        }
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let root = repositoryRoot()
        return try String(
            contentsOf: root.appendingPathComponent("ZeroLose/\(relativePath)"),
            encoding: .utf8
        )
    }

    private func productionSwiftSources() throws -> [(path: String, contents: String)] {
        let productionRoot = repositoryRoot().appendingPathComponent("ZeroLose")
        guard let enumerator = FileManager.default.enumerator(
            at: productionRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Unable to enumerate production source tree")
            return []
        }

        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            result.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
