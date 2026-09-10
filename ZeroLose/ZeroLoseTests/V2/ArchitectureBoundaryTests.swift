import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testZeroLoseSourcesDoNotImportExamPilotCore() throws {
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
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            inspectedSourceCount += 1
            XCTAssertFalse(
                contents.contains("import ExamPilotCore"),
                "ZeroLose production source must not import ExamPilotCore: \(fileURL.path)"
            )
        }

        XCTAssertGreaterThan(inspectedSourceCount, 0, "Expected to inspect ZeroLose production Swift sources")
    }
}
