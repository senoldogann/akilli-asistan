import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class ViewModelProjectionTests: XCTestCase {
    func testTimelineDoesNotShowSuccessForReceiptAlone() throws {
        let projection = TimelineProjection()
        projection.consume(makeEvent(kind: .tool, sequence: 1, taskID: "t1"))

        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items[0].state, .running)

        let verification = VerificationProjectionPayload(
            verified: true,
            summary: "Independent post-condition observed"
        )
        projection.consume(
            makeEvent(
                kind: .verification,
                sequence: 2,
                taskID: "t1",
                payload: try JSONEncoder().encode(verification)
            )
        )

        XCTAssertEqual(projection.items[0].state, .succeeded)
        XCTAssertEqual(projection.items[0].summary, verification.summary)
    }

    func testUnverifiedVerificationCannotPromoteTimelineToSuccess() throws {
        let projection = TimelineProjection()
        projection.consume(makeEvent(kind: .tool, sequence: 1, taskID: "t1"))
        let verification = VerificationProjectionPayload(verified: false, summary: "Mismatch")
        projection.consume(
            makeEvent(
                kind: .verification,
                sequence: 2,
                taskID: "t1",
                payload: try JSONEncoder().encode(verification)
            )
        )

        XCTAssertEqual(projection.items[0].state, .failed)
    }

    func testFocusedViewModelsForwardOnlyTypedApplicationCommands() async throws {
        let sender = RecordingApplicationCommandSender()
        let chat = ChatViewModel(commandSender: sender)
        let tasks = TaskRuntimeViewModel(commandSender: sender)
        let approvals = ApprovalViewModel(commandSender: sender)
        let tools = ToolManagementViewModel(commandSender: sender)
        let memory = MemoryInspectorViewModel(commandSender: sender)
        let settings = SettingsViewModel(commandSender: sender)

        chat.apply(ChatProjectionSnapshot(messages: [ChatPresentation(id: "m1", text: "ready", isUser: false)]))
        tasks.apply(TaskRuntimeProjectionSnapshot(goalID: GoalID(rawValue: "g1"), statusText: "Running"))
        approvals.apply(ApprovalProjectionSnapshot(pending: [ApprovalPresentation(invocationID: InvocationID(rawValue: "i1"), summary: "Send message")]))
        tools.apply(ToolManagementProjectionSnapshot(tools: [ToolPresentation(id: ToolID(rawValue: "tool.a"), enabled: true)]))
        memory.apply(MemoryProjectionSnapshot(entries: [MemoryPresentation(id: "mem1", summary: "Pinned fact", pinned: false)]))
        settings.apply(SettingsProjectionSnapshot(authorityMode: .manual))

        try await chat.submit("hello")
        try await tasks.pause()
        try await approvals.approve(InvocationID(rawValue: "i1"))
        try await tools.disable(ToolID(rawValue: "tool.a"))
        try await memory.pin("mem1")
        try await settings.setAuthorityMode(.auto)

        let commands = await sender.commands
        XCTAssertEqual(
            commands,
            [
                "chat:hello",
                "pause:g1",
                "approve:i1",
                "disable-tool:tool.a",
                "pin:mem1",
                "authority:auto"
            ]
        )
        XCTAssertEqual(chat.messages.map(\.text), ["ready"])
        XCTAssertEqual(tasks.statusText, "Running")
        XCTAssertEqual(approvals.pending.count, 1)
        XCTAssertEqual(tools.tools.count, 1)
        XCTAssertEqual(memory.entries.count, 1)
        XCTAssertEqual(settings.authorityMode, .manual)
    }

    func testV2UISourcesContainNoExecutionKernelDependencies() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiDirectory = root.appendingPathComponent("ZeroLose/V2/UI")
        let urls = try FileManager.default.contentsOfDirectory(
            at: uiDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for url in urls {
            let source = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["ToolFabric", "PolicyKernel", "CredentialHandle", "InputDriving", "ZeroOperator"] {
                XCTAssertFalse(source.contains(forbidden), "\(url.lastPathComponent) references \(forbidden)")
            }
        }
    }

    private func makeEvent(
        kind: RuntimeEventKind,
        sequence: UInt64,
        taskID: String,
        payload: Data = Data()
    ) -> RuntimeEvent {
        RuntimeEvent(
            eventID: RuntimeEventID(rawValue: "e\(sequence)"),
            streamID: "g1",
            sequence: sequence,
            schemaVersion: 1,
            goalID: GoalID(rawValue: "g1"),
            taskID: TaskID(rawValue: taskID),
            sessionID: nil,
            eventKind: kind,
            causationID: nil,
            correlationID: nil,
            taskGraphRevision: 1,
            toolRegistryRevision: nil,
            policyRevision: nil,
            payload: payload,
            redactionClass: .normal,
            provenance: "test",
            tainted: false,
            recordedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }
}

private actor RecordingApplicationCommandSender: ApplicationCommandSending {
    private(set) var commands: [String] = []

    func send(_ command: ApplicationCommand) async throws {
        switch command {
        case .submitUserGoal(let text): commands.append("goal:\(text)")
        case .sendChatMessage(let text): commands.append("chat:\(text)")
        case .pauseGoal(let id): commands.append("pause:\(id.rawValue)")
        case .resumeGoal(let id): commands.append("resume:\(id.rawValue)")
        case .cancelGoal(let id): commands.append("cancel:\(id.rawValue)")
        case .approveInvocation(let id): commands.append("approve:\(id.rawValue)")
        case .denyInvocation(let id): commands.append("deny:\(id.rawValue)")
        case .enableTool(let id): commands.append("enable-tool:\(id.rawValue)")
        case .disableTool(let id): commands.append("disable-tool:\(id.rawValue)")
        case .enableMCPServer(let id): commands.append("enable-mcp:\(id)")
        case .disableMCPServer(let id): commands.append("disable-mcp:\(id)")
        case .forgetMemoryEntry(let id): commands.append("forget:\(id)")
        case .pinMemoryEntry(let id): commands.append("pin:\(id)")
        case .changeAuthorityMode(let mode): commands.append("authority:\(mode.rawValue)")
        }
    }
}
