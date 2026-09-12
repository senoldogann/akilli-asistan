import Foundation
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

    func testReadOnlyAgentTaskCanReachCompletedWithProductionVerifiers() async throws {
        let descriptor = productionReadDescriptor()
        let registry = ToolRegistry()
        await registry.register(descriptor)
        let fabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: InMemoryCredentialBroker(),
            providers: [ProductionReadToolProvider()],
            authorityMode: .autonomous
        )
        let budget = productionBudget(maxRecoveryAttempts: 0)
        let taskRuntime = TaskRuntime(
            executor: AgentToolInvocationExecutor(
                registry: registry,
                toolFabric: fabric,
                mutationExecutionState: AgentMutationExecutionState(),
                settle: {}
            ),
            verifier: ProductionAgentTaskVerifier(),
            budget: budget
        )
        let orchestrator = AgentOrchestrator(
            planner: StaticProductionPlanner(task: productionReadTask()),
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: taskRuntime,
            checkpointStore: ProductionCheckpointStore(),
            eventStore: ProductionEventStore(),
            goalVerifier: ProductionAgentGoalVerifier(),
            budget: budget,
            planningContext: productionPlanningContext(descriptor: descriptor)
        )

        let result = try await orchestrator.start(
            goal: GoalSnapshot(id: GoalID(rawValue: "production-read-goal"), objective: "Read status")
        )

        XCTAssertEqual(result.lifecycle, .completed)
        XCTAssertNotNil(result.verificationEvidenceID)
    }

    func testBareReceiptCannotReachCompletedWithProductionVerifiers() async throws {
        let descriptor = productionReadDescriptor()
        let receipt = ToolExecutionReceipt(
            invocationID: InvocationID(rawValue: "bare-receipt"),
            toolID: descriptor.id,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            providerReference: nil,
            resultProvenance: "test:bare",
            resultJSON: Data(#"{"status":"ok"}"#.utf8)
        )
        let budget = productionBudget(maxRecoveryAttempts: 0)
        let taskRuntime = TaskRuntime(
            executor: BareReceiptTaskExecutor(receipt: receipt),
            verifier: ProductionAgentTaskVerifier(),
            budget: budget
        )
        let orchestrator = AgentOrchestrator(
            planner: StaticProductionPlanner(task: productionReadTask()),
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: taskRuntime,
            checkpointStore: ProductionCheckpointStore(),
            eventStore: ProductionEventStore(),
            goalVerifier: ProductionAgentGoalVerifier(),
            budget: budget,
            planningContext: productionPlanningContext(descriptor: descriptor)
        )

        let result = try await orchestrator.start(
            goal: GoalSnapshot(id: GoalID(rawValue: "production-read-goal"), objective: "Read status")
        )

        XCTAssertEqual(result.lifecycle, .failed)
        XCTAssertNil(result.verificationEvidenceID)
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
    private func productionReadDescriptor() -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: "builtin.system_status"),
            providerID: "production-read",
            provenance: "test:production-read",
            descriptorRevision: 1,
            schemaDigest: "sha256:production-read",
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            outputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: [],
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: "read-result"),
            enabled: true
        )
    }

    private func productionReadTask() -> TaskNode {
        TaskNode(
            id: TaskID(rawValue: "production-read-task"),
            title: "Read status",
            concurrencyClass: .read,
            plannedInvocation: PlannedToolInvocation(
                toolID: ToolID(rawValue: "builtin.system_status"),
                argumentsJSON: Data("{}".utf8),
                verificationExpectation: .readResult
            )
        )
    }

    private func productionPlanningContext(descriptor: ToolDescriptor) -> PlanningContext {
        PlanningContext(
            retrievedContext: ContextBundle(items: [], excluded: [], usedCharacters: 0),
            registry: ToolRegistrySnapshot(
                revision: 1,
                descriptors: [descriptor.id: descriptor]
            )
        )
    }

    private func productionBudget(maxRecoveryAttempts: Int) -> RuntimeBudget {
        RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 60,
                maxModelCalls: 2,
                maxToolCalls: 2,
                maxRecoveryAttempts: maxRecoveryAttempts,
                maxExternalSpend: 0,
                maxParallelTasks: 1,
                deadline: nil
            )
        )
    }
}

private actor StaticProductionPlanner: Planning {
    private let task: TaskNode

    init(task: TaskNode) {
        self.task = task
    }

    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) async throws -> PlanningProposal {
        PlanningProposal(
            addTasks: graph.tasks.isEmpty ? [task] : [],
            addDependencies: [],
            markBlocked: []
        )
    }
}

private struct ProductionReadToolProvider: ToolProviding {
    let providerID = "production-read"

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            providerReference: nil,
            resultProvenance: "production-read:system-status",
            resultJSON: Data(#"{"status":"ok"}"#.utf8),
            resultTainted: false
        )
    }
}

private actor BareReceiptTaskExecutor: TaskInvocationExecuting {
    private let receipt: ToolExecutionReceipt

    init(receipt: ToolExecutionReceipt) {
        self.receipt = receipt
    }

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        .toolReceipt(receipt)
    }

    func cancelActiveInvocation() async {}
}

private actor ProductionEventStore: EventStoring {
    private var events: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) async throws {
        events.append(event)
    }

    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent] {
        events.filter { $0.streamID == streamID && $0.sequence > sequence }
    }
}

private actor ProductionCheckpointStore: CheckpointStoring {
    private var checkpoints: [RuntimeCheckpoint] = []

    func save(_ checkpoint: RuntimeCheckpoint) async throws {
        checkpoints.append(checkpoint)
    }

    func latest(streamID: String) async throws -> RuntimeCheckpoint? {
        checkpoints.last { $0.streamID == streamID }
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
