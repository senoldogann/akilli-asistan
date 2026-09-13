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

    func testEmergencyStopIsGatedIndependentlyOfWorkspaceMode() throws {
        let source = try productionSource("Views/ContentView.swift")
        let strip = try XCTUnwrap(functionBody(named: "runtimeStrip", in: source, declaration: "private var"))

        guard let cancelRange = strip.range(of: "cancel()"),
              let emergencyRange = strip.range(of: "emergencyStop()"),
              cancelRange.upperBound < emergencyRange.lowerBound else {
            XCTFail("Expected cancel() before emergencyStop() inside runtimeStrip")
            return
        }

        let betweenCancelAndEmergencyStop = strip[cancelRange.upperBound..<emergencyRange.lowerBound]
        XCTAssertTrue(
            betweenCancelAndEmergencyStop.contains("if "),
            "Emergency Stop must be gated by its own condition, separate from the Pause/Resume/Cancel workspaceMode-only block, so it can remain reachable independent of the selected mode"
        )
        XCTAssertTrue(
            betweenCancelAndEmergencyStop.contains("canEmergencyStop"),
            "Emergency Stop's own gating condition must reference live emergency-stop availability, not rely solely on workspaceMode"
        )
    }

    func testChatStopRemainsReachableRegardlessOfWorkspaceMode() throws {
        let source = try productionSource("Views/ContentView.swift")
        let composer = try XCTUnwrap(functionBody(named: "trailingActions", in: source, declaration: "private var"))

        XCTAssertFalse(
            composer.contains("workspaceMode == .chat && viewModel.isBusy"),
            "Chat Stop control must not additionally require workspaceMode == .chat; a live chat request must stay stoppable regardless of the selected mode"
        )
        XCTAssertTrue(composer.contains("viewModel.isBusy"), "Chat Stop control must still gate on isBusy")
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
