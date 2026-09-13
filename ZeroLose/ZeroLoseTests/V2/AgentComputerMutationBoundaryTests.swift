import Foundation
import XCTest
@testable import ZeroLose

final class AgentComputerMutationBoundaryTests: XCTestCase {
    func testPhysicalInputDependenciesAreIsolatedToMacOSMutationAdapter() throws {
        let zeroLoseSourceRoot = try sourceRoot()
        let allowedRelativePath = "V2/Computer/MacOSComputerMutationAdapter.swift"
        let forbiddenTokens = ["InputDriving", "NativeInputDriver", "import ExamPilotCore"]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: zeroLoseSourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var allowedFileFound = false
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else {
                continue
            }
            let relativePath = String(
                fileURL.path.dropFirst(zeroLoseSourceRoot.path.count + 1)
            )
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            if relativePath == allowedRelativePath {
                allowedFileFound = true
                continue
            }

            for token in forbiddenTokens {
                XCTAssertFalse(
                    source.contains(token),
                    "\(token) must be isolated to \(allowedRelativePath), found in \(relativePath)"
                )
            }
        }

        XCTAssertTrue(allowedFileFound, "The isolated physical mutation adapter must exist")
    }

    func testOrchestratorProvidersAndSwiftUIContainNoPhysicalInputAuthority() throws {
        let zeroLoseSourceRoot = try sourceRoot()
        let guardedPaths = [
            "V2/Autonomy/AgentOrchestrator.swift",
            "V2/Tools/Providers/ComputerToolProvider.swift",
        ]
        let forbiddenTokens = ["InputDriving", "NativeInputDriver", "import ExamPilotCore"]

        for relativePath in guardedPaths {
            let source = try String(
                contentsOf: zeroLoseSourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(relativePath) must not contain \(token)")
            }
        }

        let uiRoot = zeroLoseSourceRoot.appendingPathComponent("V2/UI", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(
            at: uiRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for token in forbiddenTokens {
                    XCTAssertFalse(source.contains(token), "SwiftUI must not contain \(token)")
                }
            }
        }
    }

    private func sourceRoot() throws -> URL {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = zeroLoseDirectory.appendingPathComponent("ZeroLose", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        return sourceRoot
    }
}
