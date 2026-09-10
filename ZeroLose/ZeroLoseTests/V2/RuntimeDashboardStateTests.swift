import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class RuntimeDashboardStateTests: XCTestCase {
    func testIdleRuntimeDisablesGoalControlsAndExplainsMissingAutonomy() {
        let viewModel = TaskRuntimeViewModel(commandSender: DashboardRecordingCommandSender())

        XCTAssertFalse(viewModel.hasActiveGoal)
        XCTAssertFalse(viewModel.canPause)
        XCTAssertFalse(viewModel.canResume)
        XCTAssertFalse(viewModel.canCancel)
        XCTAssertEqual(viewModel.statusText, "Autonomous runtime not configured")
    }

    func testActiveGoalEnablesTypedRuntimeControls() async throws {
        let sender = DashboardRecordingCommandSender()
        let viewModel = TaskRuntimeViewModel(commandSender: sender)
        viewModel.apply(
            TaskRuntimeProjectionSnapshot(
                goalID: GoalID(rawValue: "goal-42"),
                statusText: "Running"
            )
        )

        XCTAssertTrue(viewModel.hasActiveGoal)
        XCTAssertTrue(viewModel.canPause)
        XCTAssertTrue(viewModel.canResume)
        XCTAssertTrue(viewModel.canCancel)

        try await viewModel.pause()
        try await viewModel.resume()
        try await viewModel.cancel()

        let commands = await sender.commands
        XCTAssertEqual(
            commands,
            ["pause:goal-42", "resume:goal-42", "cancel:goal-42"]
        )
    }

    func testApprovalPresentationCarriesDetailedPresentationSafeContext() {
        let approval = ApprovalPresentation(
            invocationID: InvocationID(rawValue: "approval-1"),
            summary: "Send status update",
            tool: "builtin.send_message",
            provider: "builtin",
            risk: "externalCommunication",
            effect: "externalCommunication",
            destination: "project channel",
            credentialScope: "messaging.send",
            tainted: true,
            mutationStatus: "not-started",
            approvalReason: "Manual approval required"
        )
        let viewModel = ApprovalViewModel(commandSender: DashboardRecordingCommandSender())
        viewModel.apply(ApprovalProjectionSnapshot(pending: [approval]))

        XCTAssertEqual(viewModel.pendingCount, 1)
        XCTAssertTrue(viewModel.hasPendingApprovals)
        XCTAssertEqual(viewModel.pending[0].tool, "builtin.send_message")
        XCTAssertEqual(viewModel.pending[0].provider, "builtin")
        XCTAssertEqual(viewModel.pending[0].risk, "externalCommunication")
        XCTAssertEqual(viewModel.pending[0].effect, "externalCommunication")
        XCTAssertEqual(viewModel.pending[0].destination, "project channel")
        XCTAssertEqual(viewModel.pending[0].credentialScope, "messaging.send")
        XCTAssertTrue(viewModel.pending[0].tainted)
        XCTAssertEqual(viewModel.pending[0].mutationStatus, "not-started")
        XCTAssertEqual(viewModel.pending[0].approvalReason, "Manual approval required")
    }

    func testRuntimeContainerComposesDurableLedgerButDoesNotExposeRawStore() throws {
        let source = try runtimeContainerSource()

        XCTAssertTrue(source.contains("SQLiteEventStore("))
        XCTAssertTrue(source.contains("RuntimeEventRecorder("))
        XCTAssertTrue(source.contains("RuntimeProjectionCoordinator("))
        XCTAssertTrue(source.contains("runtime.sqlite3"))
        XCTAssertTrue(source.contains("let timelineProjection: TimelineProjection"))
        XCTAssertTrue(source.contains("let runtimeProjectionCoordinator: RuntimeProjectionCoordinator?"))
        XCTAssertTrue(source.contains("private let eventStore:"))
        XCTAssertTrue(source.contains("private let eventRecorder:"))
        XCTAssertFalse(source.contains("\n    let eventStore: SQLiteEventStore"))
        XCTAssertFalse(source.contains("\n    let eventRecorder: RuntimeEventRecorder"))
    }

    private func runtimeContainerSource() throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        let zeroLoseRoot = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = zeroLoseRoot
            .appendingPathComponent("ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private actor DashboardRecordingCommandSender: ApplicationCommandSending {
    private(set) var commands: [String] = []

    func send(_ command: ApplicationCommand) async throws {
        switch command {
        case .pauseGoal(let id): commands.append("pause:\(id.rawValue)")
        case .resumeGoal(let id): commands.append("resume:\(id.rawValue)")
        case .cancelGoal(let id): commands.append("cancel:\(id.rawValue)")
        default: break
        }
    }
}
