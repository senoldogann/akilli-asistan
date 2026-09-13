import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testZeroLoseSourcesImportExamPilotCoreOnlyInMacOSMutationAdapter() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZeroLose", isDirectory: true)

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )

        var inspectedSourceCount = 0
        var allowedImportFound = false
        let allowedRelativePath = "V2/Computer/MacOSComputerMutationAdapter.swift"

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = String(fileURL.path.dropFirst(sourceRoot.path.count + 1))
            inspectedSourceCount += 1

            if relativePath == allowedRelativePath {
                allowedImportFound = contents.contains("import ExamPilotCore")
                continue
            }

            XCTAssertFalse(
                contents.contains("import ExamPilotCore"),
                "ExamPilotCore must remain isolated to \(allowedRelativePath): \(relativePath)"
            )
        }

        XCTAssertGreaterThan(inspectedSourceCount, 0, "Expected to inspect ZeroLose production Swift sources")
        XCTAssertTrue(allowedImportFound, "Expected \(allowedRelativePath) to own the ExamPilotCore import")
    }
    func testProductionContainerContainsNoFailClosedAgentVerifierPlaceholder() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let containerURL = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift")
        let source = try String(contentsOf: containerURL, encoding: .utf8)

        XCTAssertFalse(source.contains("FailClosedAgentTaskVerifier"))
        XCTAssertFalse(source.contains("FailClosedAgentGoalVerifier"))
        XCTAssertFalse(source.contains("shouldStop: { false }"))
    }

}
