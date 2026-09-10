import Foundation
import XCTest
@testable import ZeroLose

final class UIBoundaryTests: XCTestCase {
    func testContentViewUsesOnlyV2UIBoundary() throws {
        let source = try productionSource("Views/ContentView.swift")
        for forbidden in [
            "GhostViewModel",
            "DependencyContainer",
            "Secrets.",
            "ZeroOperator",
            ".zeroOperator",
            "@AppStorage(\"commandApprovalMode\")"
        ] {
            XCTAssertFalse(source.contains(forbidden), "ContentView must not reference \\(forbidden)")
        }
        XCTAssertTrue(source.contains("ChatViewModel"))
        XCTAssertTrue(source.contains("SettingsViewModel"))
        XCTAssertTrue(source.contains("TaskRuntimeViewModel"))
        XCTAssertTrue(source.contains("ApprovalViewModel"))
        XCTAssertTrue(source.contains("TimelineProjection"))
        XCTAssertTrue(source.contains("RuntimeProjectionCoordinator"))
    }

    func testSettingsViewHasNoDirectCredentialModelOrRuntimeServiceAccess() throws {
        let source = try productionSource("Views/SettingsView.swift")
        for forbidden in [
            "DependencyContainer",
            "Secrets.",
            "GhostViewModel",
            "ZeroOperator",
            "@AppStorage(\"commandApprovalMode\")"
        ] {
            XCTAssertFalse(source.contains(forbidden), "SettingsView must not reference \\(forbidden)")
        }
        XCTAssertTrue(source.contains("SettingsViewModel"))
    }

    func testWindowManagerComposesViewsFromV2RuntimeContainer() throws {
        let source = try productionSource("Services/WindowManager.swift")
        XCTAssertFalse(source.contains("ghostViewModel"))
        XCTAssertFalse(source.contains("GhostViewModel"))
        XCTAssertTrue(source.contains("ZeroLoseRuntimeContainer"))
        XCTAssertTrue(source.contains("taskRuntimeViewModel: runtimeContainer.taskRuntimeViewModel"))
        XCTAssertTrue(source.contains("approvalViewModel: runtimeContainer.approvalViewModel"))
        XCTAssertTrue(source.contains("timelineProjection: runtimeContainer.timelineProjection"))
        XCTAssertTrue(source.contains("runtimeProjectionCoordinator: runtimeContainer.runtimeProjectionCoordinator"))
        XCTAssertTrue(source.contains("runtimeProjectionInitializationError: runtimeContainer.runtimeProjectionInitializationError"))
        XCTAssertFalse(source.contains("eventStore: runtimeContainer"))
        XCTAssertFalse(source.contains("eventRecorder: runtimeContainer"))
    }

    func testV2UISourcesDoNotReferenceExecutionKernelOrRawCredentials() throws {
        let root = productionRoot().appendingPathComponent("V2/UI")
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let legacyActionToken = "[" + "ACTION:"

        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in [
                "ToolFabric",
                "PolicyKernel",
                "CredentialHandle",
                "ZeroOperator",
                "ComputerUseService",
                "Secrets.",
                "CGEvent",
                "AXUIElement",
                legacyActionToken
            ] {
                XCTAssertFalse(source.contains(forbidden), "\\(file.lastPathComponent) must not reference \\(forbidden)")
            }
        }
    }

    func testRuntimeContainerIsCompositionRootNotAUIExecutionBackdoor() throws {
        let source = try productionSource("V2/Application/ZeroLoseRuntimeContainer.swift")
        XCTAssertFalse(source.contains("func execute("))
        XCTAssertFalse(source.contains("InputDriving"))
        XCTAssertFalse(source.contains("CGEvent"))
        XCTAssertFalse(source.contains("AXUIElement"))
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
