import Foundation
import XCTest
@testable import ZeroLose

final class MainWorkspaceBoundaryTests: XCTestCase {
    func testPrimaryWorkspaceConsumesSharedV2ProviderStateAndModeControls() throws {
        let source = try productionSource("Views/ContentView.swift")

        XCTAssertTrue(source.contains("ProviderViewModel"))
        XCTAssertTrue(source.contains("ProviderSelectorView"))
        XCTAssertTrue(source.contains("WorkspaceMode"))
        XCTAssertTrue(source.contains("workspaceMode"))
        XCTAssertTrue(source.contains("taskRuntimeViewModel.submitGoal"))
        XCTAssertTrue(source.contains("chatViewModel.submit"))
        XCTAssertTrue(source.contains("providerViewModel.canUseAgent"))
    }

    func testPrimaryWorkspaceContainsNoLegacyProviderRoutingOrInterviewActions() throws {
        let source = try productionSource("Views/ContentView.swift")
        for forbidden in [
            "@AppStorage(\"llm_provider\")",
            "customOpenAIReasoningModel",
            "customDeepSeekReasoningModel",
            "customOpenCodeZenReasoningModel",
            "customOpenCodeGoReasoningModel",
            "customOllamaReasoningModel",
            "LLMProvider.allCases",
            "AIModelNames",
            "InterviewVaultView",
            "MockInterviewView",
            "warmUpInterviewContext",
            "toggleTeleprompterWindow",
            "KeyboardDisguiseView"
        ] {
            XCTAssertFalse(source.contains(forbidden), "ContentView still contains legacy token: \(forbidden)")
        }
    }

    func testProviderSelectorLivesInHeaderNotComposer() throws {
        let source = try productionSource("Views/ContentView.swift")
        let header = try XCTUnwrap(functionBody(named: "headerBar", in: source, declaration: "private var"))
        let composer = try XCTUnwrap(functionBody(named: "inputControlStrip", in: source, declaration: "private var"))

        XCTAssertTrue(header.contains("ProviderSelectorView"))
        XCTAssertFalse(composer.contains("ProviderSelectorView"))
        XCTAssertFalse(composer.contains("selectProvider"))
        XCTAssertFalse(composer.contains("selectModel"))
    }

    func testAgentRuntimeStripUsesTypedControlAvailability() throws {
        let source = try productionSource("Views/ContentView.swift")
        let strip = try XCTUnwrap(functionBody(named: "runtimeStrip", in: source, declaration: "private var"))

        for required in ["canPause", "canResume", "canCancel", "canEmergencyStop", "pause()", "resume()", "cancel()", "emergencyStop()"] {
            XCTAssertTrue(strip.contains(required), "Missing Agent control: \(required)")
        }
    }

    func testWindowManagerInjectsSharedProviderViewModelIntoMainView() throws {
        let source = try productionSource("Services/WindowManager.swift")
        XCTAssertTrue(source.contains("providerViewModel: runtimeContainer.providerViewModel"))
    }

    private func functionBody(
        named name: String,
        in source: String,
        declaration: String
    ) -> String? {
        guard let nameRange = source.range(of: "\(declaration) \(name)") else { return nil }
        guard let openingBrace = source[nameRange.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[openingBrace...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("ZeroLose/\(relativePath)"),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
