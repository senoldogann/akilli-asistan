import Foundation
import XCTest
@testable import ZeroLose

final class SettingsSurfaceTests: XCTestCase {
    func testSettingsUsesSharedProviderViewModelAndApprovedRuntimeDomains() throws {
        let source = try productionSource("Views/SettingsView.swift")

        XCTAssertTrue(source.contains("ProviderViewModel"))
        XCTAssertTrue(source.contains("providerViewModel.snapshot.providers"))
        XCTAssertTrue(source.contains("providerViewModel.saveOpenAIAPIKey"))
        XCTAssertTrue(source.contains("providerViewModel.removeOpenAIAPIKey"))
        for section in ["Providers", "Tools", "Runtime", "Memory", "Voice", "Appearance", "Privacy & Diagnostics"] {
            XCTAssertTrue(source.contains("\"\(section)\""), "Missing settings domain: \(section)")
        }
    }

    func testSettingsContainsNoLegacyModelProviderOrInterviewSurface() throws {
        let source = try productionSource("Views/SettingsView.swift")
        for forbidden in [
            "llm_provider",
            "LLMProvider",
            "DeepSeek",
            "OpenCode Zen",
            "OpenCode Go",
            "Ollama",
            "Active Interview Role",
            "Persona & Context (CV)",
            "teleprompterText",
            "Mock Interview",
            "Interview Notes"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Settings still contains legacy surface: \(forbidden)")
        }
    }

    func testToolsOwnTavilyAndVoiceOwnsGroq() throws {
        let source = try productionSource("Views/SettingsView.swift")
        let tools = try XCTUnwrap(functionBody(named: "toolsSection", in: source))
        let voice = try XCTUnwrap(functionBody(named: "voiceSection", in: source))

        XCTAssertTrue(tools.contains(".tavily"))
        XCTAssertFalse(tools.contains(".groq"))
        XCTAssertTrue(voice.contains(".groq"))
        XCTAssertFalse(voice.contains(".tavily"))
    }

    func testSettingsViewModelOwnsIntegrationsButNoModelProviderCatalog() throws {
        let source = try productionSource("V2/UI/SettingsViewModel.swift")

        XCTAssertTrue(source.contains("IntegrationCredential"))
        XCTAssertTrue(source.contains("case groq"))
        XCTAssertTrue(source.contains("case tavily"))
        for forbidden in [
            "CredentialProvider",
            "case openAI",
            "case deepSeek",
            "case openCodeZen",
            "case openCodeGo",
            "case ollama",
            "refreshModels",
            "models(for:"
        ] {
            XCTAssertFalse(source.contains(forbidden), "SettingsViewModel still owns model-provider state: \(forbidden)")
        }
    }

    func testAuthorityPickerNeverOffersFullAccess() throws {
        let source = try productionSource("Views/SettingsView.swift")
        let runtime = try XCTUnwrap(functionBody(named: "runtimeSection", in: source))

        XCTAssertTrue(runtime.contains(".manual"))
        XCTAssertTrue(runtime.contains(".auto"))
        XCTAssertTrue(runtime.contains(".autonomous"))
        XCTAssertFalse(runtime.contains(".fullAccess"))
    }

    func testWindowManagerInjectsSharedProviderStateIntoSettings() throws {
        let source = try productionSource("Services/WindowManager.swift")
        XCTAssertTrue(source.contains("providerViewModel: ZeroLoseRuntimeContainer.shared.providerViewModel"))
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let marker = source.range(of: "private var \(name): some View") else { return nil }
        guard let opening = source[marker.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = opening
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[opening...index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: productionRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZeroLose")
    }
}
