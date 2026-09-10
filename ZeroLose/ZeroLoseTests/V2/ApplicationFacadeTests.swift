import XCTest
@testable import ZeroLose

final class ApplicationFacadeTests: XCTestCase {
    func testRuntimeCommandsRouteOnlyToRuntimeController() async throws {
        let runtime = RecordingRuntimeCommandController()
        let tools = RecordingToolManagementController()
        let memory = RecordingMemoryCommandController()
        let facade = ApplicationFacade(
            runtime: runtime,
            tools: tools,
            memory: memory
        )

        try await facade.send(.submitUserGoal("Ship V2"))
        try await facade.send(.sendChatMessage("hello"))
        try await facade.send(.pauseGoal(GoalID(rawValue: "g1")))
        try await facade.send(.resumeGoal(GoalID(rawValue: "g1")))
        try await facade.send(.cancelGoal(GoalID(rawValue: "g1")))
        try await facade.send(.approveInvocation(InvocationID(rawValue: "i1")))
        try await facade.send(.denyInvocation(InvocationID(rawValue: "i2")))
        try await facade.send(.changeAuthorityMode(.autonomous))

        let runtimeCommands = await runtime.recordedCommands
        let toolCommands = await tools.recordedCommands
        let memoryCommands = await memory.recordedCommands

        XCTAssertEqual(
            runtimeCommands,
            [
                .submitUserGoal("Ship V2"),
                .sendChatMessage("hello"),
                .pauseGoal("g1"),
                .resumeGoal("g1"),
                .cancelGoal("g1"),
                .approveInvocation("i1"),
                .denyInvocation("i2"),
                .changeAuthorityMode("autonomous")
            ]
        )
        XCTAssertTrue(toolCommands.isEmpty)
        XCTAssertTrue(memoryCommands.isEmpty)
    }

    func testToolAndMCPCommandsRouteOnlyToToolManager() async throws {
        let runtime = RecordingRuntimeCommandController()
        let tools = RecordingToolManagementController()
        let memory = RecordingMemoryCommandController()
        let facade = ApplicationFacade(runtime: runtime, tools: tools, memory: memory)

        try await facade.send(.enableTool(ToolID(rawValue: "tool.a")))
        try await facade.send(.disableTool(ToolID(rawValue: "tool.b")))
        try await facade.send(.enableMCPServer("docs"))
        try await facade.send(.disableMCPServer("browser"))

        let toolCommands = await tools.recordedCommands
        let runtimeCommands = await runtime.recordedCommands
        let memoryCommands = await memory.recordedCommands

        XCTAssertEqual(
            toolCommands,
            [
                .setToolEnabled("tool.a", true),
                .setToolEnabled("tool.b", false),
                .setMCPServerEnabled("docs", true),
                .setMCPServerEnabled("browser", false)
            ]
        )
        XCTAssertTrue(runtimeCommands.isEmpty)
        XCTAssertTrue(memoryCommands.isEmpty)
    }

    func testMemoryCommandsRouteOnlyToMemoryController() async throws {
        let runtime = RecordingRuntimeCommandController()
        let tools = RecordingToolManagementController()
        let memory = RecordingMemoryCommandController()
        let facade = ApplicationFacade(runtime: runtime, tools: tools, memory: memory)

        try await facade.send(.pinMemoryEntry("m1"))
        try await facade.send(.forgetMemoryEntry("m2"))

        let memoryCommands = await memory.recordedCommands
        let runtimeCommands = await runtime.recordedCommands
        let toolCommands = await tools.recordedCommands

        XCTAssertEqual(
            memoryCommands,
            [.pin("m1"), .forget("m2")]
        )
        XCTAssertTrue(runtimeCommands.isEmpty)
        XCTAssertTrue(toolCommands.isEmpty)
    }

    func testFacadeSurfaceContainsNoRawExecutionPrimitives() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("ZeroLose/V2/Application/ApplicationFacade.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "ToolInvocation",
            "ToolFabric",
            "PolicyKernel",
            "CredentialHandle",
            "InputDriving",
            "ZeroOperator"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Facade must not expose \(forbidden)")
        }
    }
}

private enum RecordedRuntimeCommand: Equatable {
    case submitUserGoal(String)
    case sendChatMessage(String)
    case pauseGoal(String)
    case resumeGoal(String)
    case cancelGoal(String)
    case approveInvocation(String)
    case denyInvocation(String)
    case changeAuthorityMode(String)
}

private actor RecordingRuntimeCommandController: RuntimeCommandControlling {
    private(set) var recordedCommands: [RecordedRuntimeCommand] = []

    func submitUserGoal(_ text: String) async throws {
        recordedCommands.append(.submitUserGoal(text))
    }

    func sendChatMessage(_ text: String) async throws {
        recordedCommands.append(.sendChatMessage(text))
    }

    func pauseGoal(_ goalID: GoalID) async throws {
        recordedCommands.append(.pauseGoal(goalID.rawValue))
    }

    func resumeGoal(_ goalID: GoalID) async throws {
        recordedCommands.append(.resumeGoal(goalID.rawValue))
    }

    func cancelGoal(_ goalID: GoalID) async throws {
        recordedCommands.append(.cancelGoal(goalID.rawValue))
    }

    func approveInvocation(_ invocationID: InvocationID) async throws {
        recordedCommands.append(.approveInvocation(invocationID.rawValue))
    }

    func denyInvocation(_ invocationID: InvocationID) async throws {
        recordedCommands.append(.denyInvocation(invocationID.rawValue))
    }

    func changeAuthorityMode(_ mode: AuthorityMode) async throws {
        recordedCommands.append(.changeAuthorityMode(mode.rawValue))
    }
}

private enum RecordedToolCommand: Equatable {
    case setToolEnabled(String, Bool)
    case setMCPServerEnabled(String, Bool)
}

private actor RecordingToolManagementController: ToolManagementControlling {
    private(set) var recordedCommands: [RecordedToolCommand] = []

    func setToolEnabled(_ toolID: ToolID, enabled: Bool) async throws {
        recordedCommands.append(.setToolEnabled(toolID.rawValue, enabled))
    }

    func setMCPServerEnabled(_ serverID: String, enabled: Bool) async throws {
        recordedCommands.append(.setMCPServerEnabled(serverID, enabled))
    }
}

private enum RecordedMemoryCommand: Equatable {
    case pin(String)
    case forget(String)
}

private actor RecordingMemoryCommandController: MemoryCommandControlling {
    private(set) var recordedCommands: [RecordedMemoryCommand] = []

    func pinMemoryEntry(_ id: String) async throws {
        recordedCommands.append(.pin(id))
    }

    func forgetMemoryEntry(_ id: String) async throws {
        recordedCommands.append(.forget(id))
    }
}
