import Foundation
import XCTest
@testable import ZeroLose

final class RuntimeDashboardViewTests: XCTestCase {
    func testDashboardSourceExposesRequiredV2RuntimeSectionsAndTypedControls() throws {
        let source = try productionSource("V2/UI/RuntimeDashboardView.swift")

        XCTAssertTrue(source.contains("struct RuntimeDashboardView: View"))
        XCTAssertTrue(source.contains("Text(\"Runtime\")"))
        XCTAssertTrue(source.contains("Text(\"Controls\")"))
        XCTAssertTrue(source.contains("Text(\"Pending Approvals\")"))
        XCTAssertTrue(source.contains("Text(\"Activity Timeline\")"))
        XCTAssertTrue(source.contains("taskRuntimeViewModel.pause()"))
        XCTAssertTrue(source.contains("taskRuntimeViewModel.resume()"))
        XCTAssertTrue(source.contains("taskRuntimeViewModel.cancel()"))
        XCTAssertTrue(source.contains("approvalViewModel.approve("))
        XCTAssertTrue(source.contains("approvalViewModel.deny("))
        XCTAssertTrue(source.contains(".disabled(!taskRuntimeViewModel.canPause)"))
        XCTAssertTrue(source.contains(".disabled(!taskRuntimeViewModel.canResume)"))
        XCTAssertTrue(source.contains(".disabled(!taskRuntimeViewModel.canCancel)"))
    }

    func testDashboardSourceHasNoExecutionOrCredentialBackdoor() throws {
        let source = try productionSource("V2/UI/RuntimeDashboardView.swift")
        for forbidden in [
            "ToolFabric",
            "PolicyKernel",
            "CredentialHandle",
            "Secrets.",
            "ZeroOperator",
            "CGEvent",
            "AXUIElement",
            "[ACTION:"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Runtime dashboard must not reference \\(forbidden)")
        }
    }

    func testContentViewShowsAlwaysVisibleRuntimeStripAndRefreshesProjection() throws {
        let source = try productionSource("Views/ContentView.swift")

        XCTAssertTrue(source.contains("runtimeStrip"))
        XCTAssertTrue(source.contains("v2.runtime.strip"))
        XCTAssertTrue(source.contains("RuntimeDashboardView("))
        XCTAssertTrue(source.contains("await coordinator.refresh()"))
        XCTAssertTrue(source.contains("Task.sleep(for: .seconds(1))"))
        XCTAssertTrue(source.contains("runtimeProjectionInitializationError"))
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
