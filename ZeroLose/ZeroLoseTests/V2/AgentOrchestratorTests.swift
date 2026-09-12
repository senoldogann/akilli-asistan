import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class AgentOrchestratorTests: XCTestCase {
    func testHappyPathPersistsLifecycleAndCheckpointThroughVerifiedCompletion() async throws {
        let planner = SequencedPlanner(proposals: [singleReadProposal()])
        let executor = ImmediateTaskExecutor(result: .modelFinalText("status-ok"))
        let taskEvidence = VerificationEvidence(
            evidenceID: "task-evidence",
            summary: "Read result verified",
            provenance: "task-verifier",
            recordedAt: Date(timeIntervalSince1970: 10)
        )
        let goalEvidence = VerificationEvidence(
            evidenceID: "goal-evidence",
            summary: "Goal independently verified",
            provenance: "goal-verifier",
            recordedAt: Date(timeIntervalSince1970: 11)
        )
        let budget = makeBudget(maxRecoveryAttempts: 2)
        let runtime = TaskRuntime(
            executor: executor,
            verifier: FixedTaskVerifier(result: .verified(taskEvidence)),
            budget: budget
        )
        let events = RecordingAgentEventStore()
        let checkpoints = RecordingAgentCheckpointStore()
        let orchestrator = AgentOrchestrator(
            planner: planner,
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: runtime,
            checkpointStore: checkpoints,
            eventStore: events,
            goalVerifier: FixedGoalVerifier(
                result: GoalVerificationResult(completed: true, evidence: goalEvidence)
            ),
            budget: budget,
            planningContext: planningContext()
        )

        let result = try await orchestrator.start(goal: goal())

        XCTAssertEqual(result.lifecycle, .completed)
        XCTAssertEqual(result.verificationEvidenceID, "goal-evidence")

        let lifecycleEvents = try await recordedLifecycles(in: events)
        XCTAssertEqual(
            lifecycleEvents,
            [.planning, .ready, .executing, .observing, .verifying, .completed]
        )

        let savedCheckpoints = await checkpoints.saved
        XCTAssertGreaterThanOrEqual(savedCheckpoints.count, lifecycleEvents.count)
        let finalGraph = try XCTUnwrap(
            savedCheckpoints.last.flatMap {
                try? JSONDecoder().decode(TaskGraphSnapshot.self, from: $0.taskGraphSnapshot)
            }
        )
        XCTAssertEqual(finalGraph.tasks[TaskID(rawValue: "status")]?.lifecycle, .succeeded)
    }

    func testPolicyDenialBlocksSession() async throws {
        let planner = SequencedPlanner(proposals: [singleReadProposal()])
        let executor = ThrowingTaskExecutor(error: ToolFabricError.policyDenied(.hardPolicyDenied))
        let budget = makeBudget(maxRecoveryAttempts: 2)
        let runtime = TaskRuntime(
            executor: executor,
            verifier: FixedTaskVerifier(result: .rejected(reason: "unused")),
            budget: budget
        )
        let orchestrator = AgentOrchestrator(
            planner: planner,
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: runtime,
            checkpointStore: RecordingAgentCheckpointStore(),
            eventStore: RecordingAgentEventStore(),
            goalVerifier: FixedGoalVerifier(
                result: GoalVerificationResult(completed: false, evidence: nil)
            ),
            budget: budget,
            planningContext: planningContext()
        )

        let result = try await orchestrator.start(goal: goal())

        XCTAssertEqual(result.lifecycle, .blocked)
        let executorCalls = await executor.calls
        XCTAssertEqual(executorCalls, 1)
    }

    func testVerificationRejectionReplansUntilRecoveryBudgetIsExhausted() async throws {
        let planner = SequencedPlanner(
            proposals: [singleReadProposal(), emptyProposal(), emptyProposal()]
        )
        let executor = ImmediateTaskExecutor(result: .modelFinalText("unverified"))
        let budget = makeBudget(maxRecoveryAttempts: 1)
        let runtime = TaskRuntime(
            executor: executor,
            verifier: FixedTaskVerifier(result: .rejected(reason: "post-condition missing")),
            budget: budget
        )
        let orchestrator = AgentOrchestrator(
            planner: planner,
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: runtime,
            checkpointStore: RecordingAgentCheckpointStore(),
            eventStore: RecordingAgentEventStore(),
            goalVerifier: FixedGoalVerifier(
                result: GoalVerificationResult(completed: false, evidence: nil)
            ),
            budget: budget,
            planningContext: planningContext()
        )

        let result = try await orchestrator.start(goal: goal())

        XCTAssertEqual(result.lifecycle, .failed)
        let executorCalls = await executor.calls
        let plannerCalls = await planner.calls
        XCTAssertEqual(executorCalls, 2)
        XCTAssertGreaterThanOrEqual(plannerCalls, 2)
    }

    func testCancelPropagatesToTaskRuntimeAndEndsCancelled() async throws {
        let planner = SequencedPlanner(proposals: [singleReadProposal()])
        let executor = BlockingAgentTaskExecutor()
        let budget = makeBudget(maxRecoveryAttempts: 2)
        let runtime = TaskRuntime(
            executor: executor,
            verifier: FixedTaskVerifier(result: .rejected(reason: "unused")),
            budget: budget
        )
        let orchestrator = AgentOrchestrator(
            planner: planner,
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: runtime,
            checkpointStore: RecordingAgentCheckpointStore(),
            eventStore: RecordingAgentEventStore(),
            goalVerifier: FixedGoalVerifier(
                result: GoalVerificationResult(completed: false, evidence: nil)
            ),
            budget: budget,
            planningContext: planningContext()
        )

        let running = Task { try await orchestrator.start(goal: goal()) }
        try await waitUntil { await executor.didStart }

        await orchestrator.cancel()
        let result = try await running.value

        XCTAssertEqual(result.lifecycle, .cancelled)
        let wasCancellationRequested = await executor.wasCancellationRequested
        XCTAssertTrue(wasCancellationRequested)
    }

    func testEmergencyStopPreventsStartingLaterReadyTask() async throws {
        let planner = SequencedPlanner(proposals: [twoIndependentReadTasksProposal()])
        let executor = BlockingAgentTaskExecutor()
        let budget = makeBudget(maxRecoveryAttempts: 2)
        let runtime = TaskRuntime(
            executor: executor,
            verifier: FixedTaskVerifier(result: .rejected(reason: "unused")),
            budget: budget
        )
        let orchestrator = AgentOrchestrator(
            planner: planner,
            scheduler: Scheduler(maxParallelReads: 2),
            taskRuntime: runtime,
            checkpointStore: RecordingAgentCheckpointStore(),
            eventStore: RecordingAgentEventStore(),
            goalVerifier: FixedGoalVerifier(
                result: GoalVerificationResult(completed: false, evidence: nil)
            ),
            budget: budget,
            planningContext: planningContext()
        )

        let running = Task { try await orchestrator.start(goal: goal()) }
        try await waitUntil { await executor.didStart }

        await orchestrator.emergencyStop()
        let result = try await running.value

        XCTAssertEqual(result.lifecycle, .cancelled)
        let executorCalls = await executor.calls
        let wasCancellationRequested = await executor.wasCancellationRequested
        XCTAssertEqual(executorCalls, 1)
        XCTAssertTrue(wasCancellationRequested)
    }

    private func goal() -> GoalSnapshot {
        GoalSnapshot(id: GoalID(rawValue: "goal-1"), objective: "Read system status")
    }

    private func makeBudget(maxRecoveryAttempts: Int) -> RuntimeBudget {
        RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 300,
                maxModelCalls: 10,
                maxToolCalls: 10,
                maxRecoveryAttempts: maxRecoveryAttempts,
                maxExternalSpend: 100,
                maxParallelTasks: 4,
                deadline: nil
            )
        )
    }

    private func singleReadProposal() -> PlanningProposal {
        PlanningProposal(
            addTasks: [readTask(id: "status")],
            addDependencies: [],
            markBlocked: []
        )
    }

    private func twoIndependentReadTasksProposal() -> PlanningProposal {
        PlanningProposal(
            addTasks: [readTask(id: "first"), readTask(id: "second")],
            addDependencies: [],
            markBlocked: []
        )
    }

    private func emptyProposal() -> PlanningProposal {
        PlanningProposal(addTasks: [], addDependencies: [], markBlocked: [])
    }

    private func readTask(id: String) -> TaskNode {
        TaskNode(
            id: TaskID(rawValue: id),
            title: "Read status",
            concurrencyClass: .read,
            plannedInvocation: PlannedToolInvocation(
                toolID: ToolID(rawValue: "builtin.system_status"),
                argumentsJSON: Data(#"{}"#.utf8)
            )
        )
    }

    private func planningContext() -> PlanningContext {
        let descriptor = ToolDescriptor(
            id: ToolID(rawValue: "builtin.system_status"),
            providerID: "builtin",
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            outputSchemaJSON: nil,
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: [],
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: "read-result"),
            enabled: true
        )
        return PlanningContext(
            retrievedContext: ContextBundle(items: [], excluded: [], usedCharacters: 0),
            registry: ToolRegistrySnapshot(
                revision: 1,
                descriptors: [descriptor.id: descriptor]
            )
        )
    }

    private func recordedLifecycles(
        in store: RecordingAgentEventStore
    ) async throws -> [AgentLifecycle] {
        let events = await store.recorded
        return try events
            .filter { $0.eventKind == .runtime && $0.sessionID != nil }
            .map { event in
                try JSONDecoder().decode(AgentLifecycleEventPayload.self, from: event.payload).lifecycle
            }
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition did not become true")
    }
}

private actor SequencedPlanner: Planning {
    private var proposals: [PlanningProposal]
    private(set) var calls = 0

    init(proposals: [PlanningProposal]) {
        self.proposals = proposals
    }

    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) async throws -> PlanningProposal {
        calls += 1
        guard !proposals.isEmpty else {
            return PlanningProposal(addTasks: [], addDependencies: [], markBlocked: [])
        }
        return proposals.removeFirst()
    }
}

private actor ImmediateTaskExecutor: TaskInvocationExecuting {
    private let result: TaskExecutionResult
    private(set) var calls = 0

    init(result: TaskExecutionResult) {
        self.result = result
    }

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        calls += 1
        return result
    }

    func cancelActiveInvocation() async {}
}

private actor ThrowingTaskExecutor: TaskInvocationExecuting {
    private let error: Error
    private(set) var calls = 0

    init(error: Error) {
        self.error = error
    }

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        calls += 1
        throw error
    }

    func cancelActiveInvocation() async {}
}

private actor BlockingAgentTaskExecutor: TaskInvocationExecuting {
    private(set) var calls = 0
    private(set) var didStart = false
    private(set) var wasCancellationRequested = false

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        calls += 1
        didStart = true
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }

    func cancelActiveInvocation() async {
        wasCancellationRequested = true
    }
}

private struct FixedTaskVerifier: TaskVerifying {
    let result: TaskVerificationResult

    func verify(task: TaskNode, executionResult: TaskExecutionResult) async -> TaskVerificationResult {
        result
    }
}

private struct FixedGoalVerifier: GoalVerifying {
    let result: GoalVerificationResult

    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult {
        result
    }
}

private actor RecordingAgentEventStore: EventStoring {
    private(set) var recorded: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) async throws {
        recorded.append(event)
    }

    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent] {
        recorded.filter { $0.streamID == streamID && $0.sequence > sequence }
    }
}

private actor RecordingAgentCheckpointStore: CheckpointStoring {
    private(set) var saved: [RuntimeCheckpoint] = []

    func save(_ checkpoint: RuntimeCheckpoint) async throws {
        saved.append(checkpoint)
    }

    func latest(streamID: String) async throws -> RuntimeCheckpoint? {
        saved.last { $0.streamID == streamID }
    }
}
