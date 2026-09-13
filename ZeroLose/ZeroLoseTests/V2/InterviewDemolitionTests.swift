import Foundation
import XCTest
@testable import ZeroLose

/// Permanent guard for Task 7 of the V2 UI control plane cutover:
/// interview-era product surfaces must stay unreachable/removed, and the app's
/// user-facing copy must not describe ZeroLose as an interview assistant.
final class InterviewDemolitionTests: XCTestCase {
    private static let removedInterviewSurfaceTokens = [
        "InterviewVaultView",
        "MockInterviewView",
        "MockInterviewService",
        "MockInterviewEvaluation",
        "TeleprompterView",
        "TeleprompterWindow",
        "toggleTeleprompterWindow",
        "showTeleprompterWindow",
        "closeTeleprompterWindow",
        "warmUpInterviewContext",
        "CheatSheetView",
        "CheatSheetViewModel",
        "KeyboardDisguiseView",
    ]

    private static let removedInterviewSourcePaths = [
        "Views/InterviewVaultView.swift",
        "Views/MockInterviewView.swift",
        "Views/TeleprompterView.swift",
        "Views/CheatSheetView.swift",
        "Views/KeyboardDisguiseView.swift",
        "Services/MockInterviewService.swift",
        "ViewModels/CheatSheetViewModel.swift",
    ]

    func testRemovedInterviewSurfacesAreDeletedFromDisk() throws {
        for relativePath in Self.removedInterviewSourcePaths {
            let url = productionRoot().appendingPathComponent(relativePath)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(relativePath) must stay removed from the product surface"
            )
        }
    }

    func testNoProductionSourceReferencesRemovedInterviewSurfaces() throws {
        let root = productionRoot()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var inspected = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            inspected += 1
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in Self.removedInterviewSurfaceTokens where source.contains(token) {
                XCTFail("\(relativePath) still references removed interview surface: \(token)")
            }
        }

        XCTAssertGreaterThan(inspected, 0, "Expected to inspect ZeroLose production sources")
    }

    func testShellFeatureContractNoLongerExposesInterviewWarmUp() throws {
        let source = try productionSource("V2/UI/ShellViewModel.swift")
        XCTAssertFalse(source.contains("warmUpInterviewContext"))
        XCTAssertTrue(source.contains("protocol ShellFeatureControlling"))
        for retained in [
            "func clearHistory()",
            "func toggleClipboard()",
            "func toggleListening()",
            "func stopResponse()",
            "func submitQuery(",
            "func refineAnswer(",
            "func clearAttachment()",
            "func attachFile(",
            "func analyzeScreen()",
        ] {
            XCTAssertTrue(
                source.contains(retained),
                "ShellFeatureControlling must keep general capability: \(retained)"
            )
        }
    }

    func testInfoPlistPrivacyCopyDescribesGeneralAssistant() throws {
        let plist = try productionSourceURL("Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        for key in [
            "NSMicrophoneUsageDescription",
            "NSScreenCaptureUsageDescription",
            "NSAppleEventsUsageDescription",
        ] {
            let value = try XCTUnwrap(parsed[key] as? String, "Missing \(key)")
            XCTAssertFalse(value.isEmpty, "\(key) must not be empty")
            let lowered = value.lowercased()
            for forbidden in ["interview", "meeting", "mülakat"] {
                XCTAssertFalse(
                    lowered.contains(forbidden),
                    "\(key) still describes the product with '\(forbidden)': \(value)"
                )
            }
        }
    }

    func testReadmeDoesNotDefineProductAsInterviewAssistant() throws {
        let readme = try productionSourceURL("../README.md")
        let content = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertFalse(content.isEmpty)
        let lowered = content.lowercased()
        for forbidden in ["interview", "mülakat", "teleprompter", "mock interview"] {
            XCTAssertFalse(
                lowered.contains(forbidden),
                "ZeroLose/README.md still positions the product with '\(forbidden)'"
            )
        }
    }

    // MARK: - Helpers

    private func productionSource(_ relativePath: String) throws -> String {
        try String(contentsOf: productionSourceURL(relativePath), encoding: .utf8)
    }

    private func productionSourceURL(_ relativePath: String) throws -> URL {
        productionRoot().appendingPathComponent(relativePath)
    }

    private func productionRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZeroLose")
    }
}
