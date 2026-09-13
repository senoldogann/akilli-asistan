import Foundation
import XCTest
@testable import ZeroLose

/// Permanent guard for Task 8 of the V2 UI control plane cutover.
///
/// The V2 provider control plane is the single authority for Chat/Agent routing.
/// The legacy `LLMProvider` / `AIModelNames` / `OllamaService` stack is fully
/// retired, so the compatibility closure is now empty: any production file that
/// mentions those identifiers is a regression. The single historical
/// `llm_provider` default survives only in the one migration-only reader, which
/// never routes a request.
final class ProviderLegacyDemolitionTests: XCTestCase {
    /// Files allowed to reference legacy provider authority. Empty means the
    /// legacy router is gone; adding an entry is a regression.
    private static let legacyAuthorityClosure: [String] = []

    /// Files allowed to read the legacy `llm_provider` default.
    private static let legacyDefaultReaders = [
        "V2/Migration/SettingsMigrationCoordinator.swift",
    ]

    private static let primaryPathDirectories = [
        "Views",
        "V2/UI",
        "V2/Application",
        "V2/Providers",
    ]

    private static let forbiddenInPrimaryPaths = [
        "LLMProvider",
        "AIModelNames",
        "llm_provider",
        "OllamaService",
        "@AppStorage(\"llm_provider\")",
        "customOpenAIReasoningModel",
        "customDeepSeekReasoningModel",
        "customOpenCodeZenReasoningModel",
        "customOpenCodeGoReasoningModel",
        "customOllamaReasoningModel",
        "customOpenAIVisionModel",
        "customDeepSeekVisionModel",
        "customOpenCodeZenVisionModel",
        "customOpenCodeGoVisionModel",
        "customOllamaVisionModel",
        "importOpenCodeKeysIfNeeded",
        "auth.json",
        ".local/share/opencode",
        "opencode.ai/",
        "/zen/go/",
        "fallbackProvider",
        "providerFallback",
    ]

    func testPrimaryProductPathsContainNoLegacyProviderAuthority() throws {
        let root = productionRoot()
        var inspected = 0

        for directory in Self.primaryPathDirectories {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root.appendingPathComponent(directory),
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ),
                "Missing primary path directory: \(directory)"
            )
            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                inspected += 1
                let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for token in Self.forbiddenInPrimaryPaths where source.contains(token) {
                    XCTFail("\(relativePath) uses legacy provider authority token: \(token)")
                }
            }
        }

        XCTAssertGreaterThan(inspected, 0, "Expected to inspect primary product paths")
    }

    func testLegacyProviderAuthorityIsConfinedToDocumentedClosure() throws {
        let closure = try productionFiles(containing: ["LLMProvider", "AIModelNames", "OllamaService"])
        XCTAssertEqual(
            closure.sorted(),
            Self.legacyAuthorityClosure.sorted(),
            "Legacy provider authority must stay retired; the allowed closure is empty"
        )

        let legacyDefaultReaders = try productionFiles(containing: ["llm_provider"])
        XCTAssertEqual(
            legacyDefaultReaders.sorted(),
            Self.legacyDefaultReaders.sorted(),
            "Only the migration coordinator and the legacy model catalog may read the llm_provider default"
        )
    }

    func testAutomaticLegacyCredentialImportIsRemoved() throws {
        let root = productionRoot()
        let launchSource = try String(
            contentsOf: root.appendingPathComponent("ZeroLoseApp.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(launchSource.contains("importOpenCodeKeysIfNeeded"))

        for relativePath in [
            "Resources/Secrets.swift",
            "V2/Application/ZeroLoseRuntimeContainer.swift",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for forbidden in ["auth.json", ".local/share/opencode", "importOpenCodeKeysIfNeeded"] {
                XCTAssertFalse(
                    source.contains(forbidden),
                    "\(relativePath) must not scrape provider credential files (\(forbidden))"
                )
            }
        }
    }

    func testRepositoryGateEnforcesProviderAuthorityAndInterviewGuards() throws {
        let verifyScript = try String(
            contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_all.py"),
            encoding: .utf8
        )

        for required in [
            "def verify_zerolose_provider_authority()",
            "def verify_zerolose_interview_demolition()",
            "if not verify_zerolose_provider_authority():",
            "if not verify_zerolose_interview_demolition():",
            "ZEROLOSE_PRIMARY_PATHS",
            "OBSOLETE_ZEROLOSE_INTERVIEW_SOURCES",
            "OBSOLETE_ZEROLOSE_LEGACY_PROVIDER_SOURCES",
            "FORBIDDEN_ZEROLOSE_TREE_TOKENS",
            "ALLOWED_ZEROLOSE_LEGACY_DEFAULT_READERS",
        ] {
            XCTAssertTrue(
                verifyScript.contains(required),
                "Repository verification is missing provider/interview guard: \(required)"
            )
        }
    }

    // MARK: - Helpers

    private func productionFiles(containing tokens: [String]) throws -> [String] {
        let root = productionRoot()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var matches: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if tokens.contains(where: { source.contains($0) }) {
                matches.append(String(fileURL.path.dropFirst(root.path.count + 1)))
            }
        }
        return matches
    }

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZeroLose")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
