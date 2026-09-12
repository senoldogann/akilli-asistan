import XCTest
@testable import ZeroLose

@MainActor
final class AgentApplicationCommandTests: XCTestCase {
    func testAgentCommandRuntimeRoutesAuthoritativeSessionControlsAndEmergencyStop() async throws {
        let orchestrator = RecordingAgentOrchestrator(session: nil)
        let stopState = AgentEmergencyStopState()
        let runtime = AgentCommandRuntime(
            orchestrator: orchestrator,
            emergencyStopState: stopState
        )

        let started = try await runtime.submitUserGoal("Ship the autonomous runtime")
        try await runtime.pause(sessionID: started.id)
        try await runtime.resume(sessionID: started.id)
        try await runtime.cancel(sessionID: started.id)
        try await runtime.emergencyStop()

        let calls = await orchestrator.calls
        XCTAssertEqual(
            calls,
            [
                .start("Ship the autonomous runtime"),
                .pause,
                .resume,
                .cancel,
                .emergencyStop
            ]
        )
        XCTAssertTrue(stopState.isStopped)
    }

    func testSubmitUserGoalPublishesActiveSessionBeforeRunCompletes() async throws {
        let orchestrator = BlockingAgentOrchestrator()
        let runtime = AgentCommandRuntime(
            orchestrator: orchestrator,
            emergencyStopState: AgentEmergencyStopState(),
            mutationExecutionActive: { true }
        )

        let session = try await withThrowingTaskGroup(of: AgentSessionSnapshot.self) { group in
            group.addTask {
                try await runtime.submitUserGoal("Keep running until cancelled")
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(150))
                throw AgentApplicationCommandTestError.timedOutWaitingForActiveSession
            }

            let first = try await group.next()
            group.cancelAll()
            return try XCTUnwrap(first)
        }

        XCTAssertEqual(session.lifecycle, .executing)
        let activeState = await runtime.snapshot()
        XCTAssertTrue(activeState.mutationExecutionActive)
        try await runtime.cancel(sessionID: session.id)
        let final = await runtime.waitForCurrentRun()
        XCTAssertEqual(final?.lifecycle, .cancelled)
    }

    func testSubmitUserGoalFailsClosedWhenStructuredPlanningIsUnavailable() async throws {
        let orchestrator = RecordingAgentOrchestrator(session: nil)
        let runtime = AgentCommandRuntime(
            orchestrator: orchestrator,
            emergencyStopState: AgentEmergencyStopState(),
            structuredPlanningAvailable: { false }
        )

        do {
            _ = try await runtime.submitUserGoal("Do not start without structured planning")
            XCTFail("expected structured planning to fail closed")
        } catch let error as V2RuntimeCommandError {
            XCTAssertEqual(
                error,
                .unsupportedCommand("agent-structured-planning-unavailable")
            )
        }

        let calls = await orchestrator.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAgentCommandRuntimeRejectsControlForNonActiveSession() async throws {
        let activeID = AgentSessionID(rawValue: "active")
        let orchestrator = RecordingAgentOrchestrator(
            session: AgentSessionSnapshot(
                id: activeID,
                goalID: GoalID(rawValue: "goal-active"),
                lifecycle: .executing,
                verificationEvidenceID: nil
            )
        )
        let runtime = AgentCommandRuntime(
            orchestrator: orchestrator,
            emergencyStopState: AgentEmergencyStopState()
        )

        do {
            try await runtime.pause(sessionID: AgentSessionID(rawValue: "other"))
            XCTFail("expected active-session mismatch")
        } catch let error as V2RuntimeCommandError {
            XCTAssertEqual(error, .unsupportedCommand("agent-session-not-active"))
        }

        let calls = await orchestrator.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTaskRuntimeViewModelEnablesOnlyValidAgentControls() async throws {
        let sender = RecordingAgentApplicationCommandSender()
        let viewModel = TaskRuntimeViewModel(commandSender: sender)
        let sessionID = AgentSessionID(rawValue: "session-ui")
        let goalID = GoalID(rawValue: "goal-ui")

        XCTAssertEqual(viewModel.statusText, "Idle")
        XCTAssertFalse(viewModel.canPause)
        XCTAssertFalse(viewModel.canResume)
        XCTAssertFalse(viewModel.canCancel)
        XCTAssertFalse(viewModel.canEmergencyStop)

        viewModel.apply(
            TaskRuntimeProjectionSnapshot(
                goalID: goalID,
                statusText: "Executing",
                sessionID: sessionID,
                lifecycle: .executing,
                isPaused: false,
                mutationCapableExecutionActive: true
            )
        )
        XCTAssertTrue(viewModel.canPause)
        XCTAssertFalse(viewModel.canResume)
        XCTAssertTrue(viewModel.canCancel)
        XCTAssertTrue(viewModel.canEmergencyStop)

        try await viewModel.pause()
        try await viewModel.cancel()
        try await viewModel.emergencyStop()

        viewModel.apply(
            TaskRuntimeProjectionSnapshot(
                goalID: goalID,
                statusText: "Paused",
                sessionID: sessionID,
                lifecycle: .executing,
                isPaused: true,
                mutationCapableExecutionActive: false
            )
        )
        XCTAssertFalse(viewModel.canPause)
        XCTAssertTrue(viewModel.canResume)
        XCTAssertTrue(viewModel.canCancel)
        XCTAssertFalse(viewModel.canEmergencyStop)
        try await viewModel.resume()

        viewModel.apply(
            TaskRuntimeProjectionSnapshot(
                goalID: goalID,
                statusText: "Completed",
                sessionID: sessionID,
                lifecycle: .completed,
                isPaused: false,
                mutationCapableExecutionActive: false
            )
        )
        XCTAssertFalse(viewModel.canPause)
        XCTAssertFalse(viewModel.canResume)
        XCTAssertFalse(viewModel.canCancel)
        XCTAssertFalse(viewModel.canEmergencyStop)

        let commands = await sender.commands
        XCTAssertEqual(
            commands,
            [
                .pause(sessionID),
                .cancel(sessionID),
                .emergencyStop,
                .resume(sessionID)
            ]
        )
    }
}

private enum RecordedAgentOrchestratorCall: Sendable, Equatable {
    case start(String)
    case pause
    case resume
    case cancel
    case emergencyStop
}

private enum AgentApplicationCommandTestError: Error {
    case timedOutWaitingForActiveSession
}

private actor RecordingAgentOrchestrator: AgentOrchestrating {
    private var session: AgentSessionSnapshot?
    private(set) var calls: [RecordedAgentOrchestratorCall] = []
    private var paused = false

    init(session: AgentSessionSnapshot?) {
        self.session = session
    }

    func start(goal: GoalSnapshot) async throws -> AgentSessionSnapshot {
        calls.append(.start(goal.objective))
        if let session {
            return session
        }
        let created = AgentSessionSnapshot(
            id: AgentSessionID(rawValue: "created-session"),
            goalID: goal.id,
            lifecycle: .executing,
            verificationEvidenceID: nil
        )
        session = created
        return created
    }

    func pause() async {
        calls.append(.pause)
        paused = true
    }

    func resume() async throws {
        calls.append(.resume)
        paused = false
    }

    func cancel() async {
        calls.append(.cancel)
    }

    func emergencyStop() async {
        calls.append(.emergencyStop)
    }

    func snapshot() async -> AgentSessionSnapshot? {
        session
    }

    func isPaused() async -> Bool {
        paused
    }

}

private actor BlockingAgentOrchestrator: AgentOrchestrating {
    private var session: AgentSessionSnapshot?
    private var shouldFinish = false

    func start(goal: GoalSnapshot) async throws -> AgentSessionSnapshot {
        let running = AgentSessionSnapshot(
            id: AgentSessionID(rawValue: "blocking-session"),
            goalID: goal.id,
            lifecycle: .executing,
            verificationEvidenceID: nil
        )
        session = running

        while !shouldFinish {
            try await Task.sleep(for: .milliseconds(10))
        }

        let cancelled = AgentSessionSnapshot(
            id: running.id,
            goalID: running.goalID,
            lifecycle: .cancelled,
            verificationEvidenceID: nil
        )
        session = cancelled
        return cancelled
    }

    func pause() async {}
    func resume() async throws {}

    func cancel() async {
        shouldFinish = true
    }

    func emergencyStop() async {
        shouldFinish = true
    }

    func snapshot() async -> AgentSessionSnapshot? {
        session
    }

    func isPaused() async -> Bool {
        false
    }

}

private enum RecordedAgentApplicationCommand: Equatable {
    case pause(AgentSessionID)
    case resume(AgentSessionID)
    case cancel(AgentSessionID)
    case emergencyStop
}

private actor RecordingAgentApplicationCommandSender: ApplicationCommandSending {
    private(set) var commands: [RecordedAgentApplicationCommand] = []

    func send(_ command: ApplicationCommand) async throws {
        switch command {
        case .pauseAgentSession(let id): commands.append(.pause(id))
        case .resumeAgentSession(let id): commands.append(.resume(id))
        case .cancelAgentSession(let id): commands.append(.cancel(id))
        case .emergencyStop: commands.append(.emergencyStop)
        default: break
        }
    }
}
