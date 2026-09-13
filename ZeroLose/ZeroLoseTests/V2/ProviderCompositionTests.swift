import Foundation
import XCTest
@testable import ZeroLose

final class ProviderCompositionTests: XCTestCase {
    func testRuntimeContainerComposesExactlyRedesignedProviderSet() throws {
        let source = try providerCompositionProductionSource(
            "V2/Application/ZeroLoseRuntimeContainer.swift"
        )

        for required in [
            "CLIExecutableLocator(",
            "CLIProcessRunner(",
            "CodexCLIProvider(",
            "ClaudeCLIProvider(",
            "OpenCodeCLIProvider(",
            "AntigravityCLIProvider(",
            "OpenAIAPIProvider(",
            "OpenAITransport(",
            "ModelProviderFabric("
        ] {
            XCTAssertTrue(source.contains(required), "Missing provider composition token: \(required)")
        }

        let expectedProviderIDs = ["codex", "claude", "opencode", "antigravity", "openai-api"]
        let providerSources = try providerCompositionProviderSources()
        let declaredProviderIDs = Set(
            expectedProviderIDs.filter { id in
                providerSources.contains("ModelProviderID(rawValue: \"\(id)\")")
            }
        )
        XCTAssertEqual(declaredProviderIDs, Set(expectedProviderIDs))
        XCTAssertTrue(source.contains("providers: [codexProvider, claudeProvider, openCodeProvider, antigravityProvider, openAIProvider]"))
    }

    func testProviderSelectionPersistenceIsOwnedByControlPlane() throws {
        let container = try providerCompositionProductionSource(
            "V2/Application/ZeroLoseRuntimeContainer.swift"
        )
        let controlPlane = try providerCompositionProductionSource(
            "V2/Providers/ProviderControlPlane.swift"
        )

        XCTAssertTrue(controlPlane.contains("v2.modelProviderID"))
        XCTAssertTrue(controlPlane.contains("v2.modelDefaultID"))
        XCTAssertTrue(container.contains("UserDefaultsProviderSelectionStore(defaults: defaults)"))
        XCTAssertFalse(container.contains("v2.modelProviderID"))
        XCTAssertFalse(container.contains("v2.modelDefaultID"))
        XCTAssertFalse(container.contains("v2.modelProviderAPIKey"))
        XCTAssertFalse(container.contains("v2.modelCredential"))
    }

    func testProviderModuleContainsNoLegacyRouterOrCredentialFilePaths() throws {
        let providerSources = try providerCompositionProviderSources()
        let forbidden = [
            "OllamaService",
            "fallbackProvider",
            "importOpenCodeKeysIfNeeded",
            "opencode.ai/",
            "/zen/go/",
            ".codex/auth",
            ".claude/",
            "auth.json",
            "/bin/sh",
            "/bin/bash",
            "/bin/zsh",
            "/usr/bin/env"
        ]

        for token in forbidden {
            XCTAssertFalse(
                providerSources.contains(token),
                "V2 provider module contains forbidden token: \(token)"
            )
        }
    }

    func testRepositoryVerificationIncludesProviderFabricGuard() throws {
        let verifyScript = try String(
            contentsOf: providerCompositionRepositoryRoot()
                .appendingPathComponent("scripts/verify_all.py"),
            encoding: .utf8
        )

        XCTAssertTrue(verifyScript.contains("ZEROLOSE_PROVIDER_SOURCE"))
        XCTAssertTrue(verifyScript.contains("def verify_zerolose_provider_fabric()"))
        XCTAssertTrue(verifyScript.contains("if not verify_zerolose_provider_fabric():"))
        for requiredGuard in [
            "fallbackProvider",
            "importOpenCodeKeysIfNeeded",
            "opencode.ai/",
            "auth.json",
            "/bin/sh",
            "/usr/bin/env"
        ] {
            XCTAssertTrue(
                verifyScript.contains(requiredGuard),
                "Repository verification is missing provider guard token: \(requiredGuard)"
            )
        }
    }

    func testRuntimeContainerExposesOneSharedProviderViewModel() throws {
        let source = try providerCompositionProductionSource(
            "V2/Application/ZeroLoseRuntimeContainer.swift"
        )

        XCTAssertTrue(source.contains("let providerViewModel: ProviderViewModel"))
        XCTAssertEqual(source.components(separatedBy: "ProviderViewModel(").count - 1, 1)
        XCTAssertTrue(source.contains("ProviderSettingsController("))
        XCTAssertTrue(source.contains("await providerViewModel.refresh()"))
    }

    func testAgentCompositionCapturesProviderSelectionPerRun() throws {
        let source = try providerCompositionProductionSource(
            "V2/Application/ZeroLoseRuntimeContainer.swift"
        )

        XCTAssertTrue(source.contains("ClosureAgentOrchestratorBuilder"))
        XCTAssertTrue(source.contains("selection: selection"))
        XCTAssertTrue(source.contains("modelID: selection.modelID"))
        XCTAssertTrue(source.contains("using: selection.providerID"))
        XCTAssertTrue(source.contains("providerControlPlane.currentSelection()"))
        XCTAssertFalse(source.contains("configuredAgentModelID"))
        XCTAssertFalse(source.contains("structuredPlanningAvailable:"))
    }
}

private func providerCompositionProductionSource(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let sourceRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZeroLose", isDirectory: true)
    return try String(
        contentsOf: sourceRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func providerCompositionProviderSources() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let providerRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZeroLose/V2/Providers", isDirectory: true)

    guard let enumerator = FileManager.default.enumerator(
        at: providerRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw CocoaError(.fileReadNoSuchFile)
    }

    var sources: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        sources.append(try String(contentsOf: url, encoding: .utf8))
    }
    return sources.joined(separator: "\n")
}

private func providerCompositionRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
