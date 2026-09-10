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

    func testShellRuntimeInjectsV2NativeToolsIntoModelBoundary() throws {
        let source = try productionSource("V2/Application/V2ShellRuntimeController.swift")
        XCTAssertTrue(source.contains("nativeToolRuntime.configuration()"))
        XCTAssertTrue(source.contains("nativeTools: toolConfiguration.tools"))
        XCTAssertTrue(source.contains("nativeToolExecutor: toolConfiguration.executor"))
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

    func testModelProviderDoesNotSelectToolsFromLegacyCapabilityRegistry() throws {
        let source = try productionSource("Services/OllamaService.swift")
        XCTAssertFalse(
            source.contains("AgentCapability" + "Registry"),
            "Model provider still owns legacy tool selection"
        )
    }

    func testIntelligenceServiceDoesNotInjectLegacyAutomationPrompt() throws {
        let source = try productionSource("Services/IntelligenceService.swift")
        XCTAssertFalse(
            source.contains("Automation" + "Library"),
            "IntelligenceService still injects legacy automation prompt state"
        )
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
