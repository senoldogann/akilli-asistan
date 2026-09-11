import Foundation
import XCTest
@testable import ZeroLose

final class ComputerAgentPackageIntegrationTests: XCTestCase {
    func testZeroLoseLinksExistingComputerAgentPackages() {
        XCTAssertEqual(
            ComputerAgentPackageProbe.linkedProducts,
            ["ComputerAgentCore", "ComputerAgentMacOS", "ExamPilotCore"]
        )
    }

    func testZeroLoseDeclaresLocalComputerAgentPackageProducts() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZeroLose.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: projectFile, encoding: .utf8)

        XCTAssertTrue(
            contents.contains("relativePath = ../ExamPilot;"),
            "ZeroLose must reference the repository-local ExamPilot package"
        )
        for product in ["ComputerAgentCore", "ComputerAgentMacOS", "ExamPilotCore"] {
            XCTAssertTrue(
                contents.contains("productName = \(product);"),
                "ZeroLose must link the \(product) package product"
            )
        }
    }
}
