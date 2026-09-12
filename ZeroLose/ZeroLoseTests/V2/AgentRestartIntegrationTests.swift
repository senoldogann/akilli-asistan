import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class AgentRestartIntegrationTests: XCTestCase {
    func testRestoreReplaysReadOnlyRefreshesAuthorityAndRemainsPausedWithoutPhysicalInput() async throws {
        let recorder = RestartStepRecorder()
        let sessionID = AgentSessionID(rawValue: "restart-session")
        let checkpoint = try makeCheckpoint(sessionID: sessionID)
        let checkpointStore = RestartCheckpointStore(checkpoint: checkpoint, recorder: recorder)
        let eventStore = RestartEventStore(
            events: [try makeReplayEvent(streamID: checkpoint.streamID, sequence: 11)],
            recorder: recorder
        )
        let restoreDependencies = RestartRestoreDependencies(recorder: recorder)
        let restoreCoordinator = AutonomousRuntimeRestoreCoordinator(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            replayExecutor: RestartReplayExecutor(recorder: recorder),
            registryRefresher: restoreDependencies,
            credentialHandleDiscarder: restoreDependencies,
            currentPolicyLoader: restoreDependencies,
            worldReobserver: restoreDependencies,
            mutationReconciler: restoreDependencies,
            readinessRebuilder: restoreDependencies
        )
        let physicalExecutor = RecordingRestartPhysicalExecutor()
        let orchestrator = makeOrchestrator(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            physicalExecutor: physicalExecutor,
            restoreCoordinator: restoreCoordinator
        )

        let restored = try await orchestrator.restore(sessionID: sessionID)

        let isPaused = await orchestrator.isPaused()
        let physicalCalls = await physicalExecutor.calls
        let recordedSteps = await recorder.steps

        XCTAssertEqual(restored.id, sessionID)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(physicalCalls, 0)
        XCTAssertEqual(
            recordedSteps,
            [
                "checkpoint",
                "events",
                "replay",
                "registry",
                "credentials",
                "policy",
                "world",
                "mutations",
                "readiness"
            ]
        )
    }

    func testUnknownHighRiskOutstandingMutationRequiresManualResolutionAndRejectsResume() async throws {
        let recorder = RestartStepRecorder()
        let sessionID = AgentSessionID(rawValue: "manual-session")
        let checkpoint = try makeCheckpoint(sessionID: sessionID)
        let checkpointStore = RestartCheckpointStore(checkpoint: checkpoint, recorder: recorder)
        let eventStore = RestartEventStore(events: [], recorder: recorder)
        let restoreDependencies = RestartRestoreDependencies(
            recorder: recorder,
            outstandingMutation: ExternalMutationRecord(
                logicalOperationID: "click-1",
                idempotencyKey: "click-1-attempt-1",
                invocationID: InvocationID(rawValue: "invocation-click-1"),
                attempt: 1,
                risk: .highImpactExternalMutation,
                receipt: nil,
                verification: nil,
                externalReference: nil,
                externalState: .unknown
            )
        )
        let restoreCoordinator = AutonomousRuntimeRestoreCoordinator(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            replayExecutor: RestartReplayExecutor(recorder: recorder),
            registryRefresher: restoreDependencies,
            credentialHandleDiscarder: restoreDependencies,
            currentPolicyLoader: restoreDependencies,
            worldReobserver: restoreDependencies,
            mutationReconciler: restoreDependencies,
            readinessRebuilder: restoreDependencies
        )
        let physicalExecutor = RecordingRestartPhysicalExecutor()
        let orchestrator = makeOrchestrator(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            physicalExecutor: physicalExecutor,
            restoreCoordinator: restoreCoordinator
        )

        let restored = try await orchestrator.restore(sessionID: sessionID)

        let isPaused = await orchestrator.isPaused()
        let physicalCallsBeforeResume = await physicalExecutor.calls
        let recordedSteps = await recorder.steps

        XCTAssertEqual(restored.lifecycle, .manualResolutionRequired)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(physicalCallsBeforeResume, 0)
        XCTAssertEqual(
            recordedSteps,
            ["checkpoint", "events", "registry", "credentials", "policy", "world", "mutations"]
        )

        do {
            try await orchestrator.resume()
            XCTFail("resume must remain fail-closed while manual resolution is required")
        } catch {
            XCTAssertEqual(error as? AgentOrchestratorError, .manualResolutionRequired)
        }
        let physicalCallsAfterResume = await physicalExecutor.calls
        XCTAssertEqual(physicalCallsAfterResume, 0)
    }

    private func makeOrchestrator(
        checkpointStore: any CheckpointStoring,
        eventStore: any EventStoring,
        physicalExecutor: RecordingRestartPhysicalExecutor,
        restoreCoordinator: any AutonomousSessionRestoring
    ) -> AgentOrchestrator {
        let budget = RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 300,
                maxModelCalls: 10,
                maxToolCalls: 10,
                maxRecoveryAttempts: 2,
                maxExternalSpend: 100,
                maxParallelTasks: 1,
                deadline: nil
            )
        )
        let taskRuntime = TaskRuntime(
            executor: physicalExecutor,
            verifier: RestartTaskVerifier(),
            budget: budget
        )

        return AgentOrchestrator(
            planner: RestartPlanner(),
            scheduler: Scheduler(maxParallelReads: 1),
            taskRuntime: taskRuntime,
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            goalVerifier: RestartGoalVerifier(),
            budget: budget,
            planningContext: PlanningContext(
                retrievedContext: ContextBundle(items: [], excluded: [], usedCharacters: 0),
                registry: ToolRegistrySnapshot(revision: 1, descriptors: [:])
            ),
            restoreCoordinator: restoreCoordinator
        )
    }

    private func makeCheckpoint(sessionID: AgentSessionID) throws -> RuntimeCheckpoint {
        let goalID = GoalID(rawValue: "goal-restart")
        let session = AgentSessionSnapshot(
            id: sessionID,
            goalID: goalID,
            lifecycle: .executing,
            verificationEvidenceID: nil
        )
        let graph = TaskGraphSnapshot(goalID: goalID, revision: 3, tasks: [:])
        let budget = RuntimeBudgetSnapshot(
            remainingModelCalls: 7,
            remainingToolCalls: 6,
            remainingRecoveryAttempts: 1,
            remainingExternalSpend: 100,
            deadline: nil
        )

        return RuntimeCheckpoint(
            streamID: "agent:\(sessionID.rawValue)",
            eventSequence: 10,
            taskGraphRevision: graph.revision,
            taskGraphSnapshot: try JSONEncoder().encode(graph),
            lifecycleSnapshot: try JSONEncoder().encode(session),
            budgetSnapshot: try JSONEncoder().encode(budget),
            boundedWorkingMemory: Data("{}".utf8),
            providerContinuationMetadata: Data(
                #"{"computer_call":{"actions":[{"type":"click","x":100,"y":200}]}}"#.utf8
            ),
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeReplayEvent(streamID: String, sequence: UInt64) throws -> RuntimeEvent {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(sequence))
        let artifact = ReplayArtifact(
            invocationID: InvocationID(rawValue: "recorded-invocation"),
            toolID: ToolID(rawValue: "computer.pointer.click"),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            providerReference: "recorded-only",
            resultProvenance: "recorded-runtime",
            resultTainted: false
        )

        return RuntimeEvent(
            eventID: RuntimeEventID(rawValue: "event-\(sequence)"),
            streamID: streamID,
            sequence: sequence,
            schemaVersion: 1,
            goalID: GoalID(rawValue: "goal-restart"),
            taskID: nil,
            sessionID: SessionID(rawValue: "restart-session"),
            eventKind: .tool,
            causationID: nil,
            correlationID: nil,
            taskGraphRevision: 3,
            toolRegistryRevision: 1,
            policyRevision: 1,
            payload: try JSONEncoder().encode(artifact),
            redactionClass: .normal,
            provenance: "recorded-runtime",
            tainted: false,
            recordedAt: startedAt
        )
    }
}

private actor RestartStepRecorder {
    private(set) var steps: [String] = []

    func record(_ step: String) {
        steps.append(step)
    }
}

private actor RestartCheckpointStore: CheckpointStoring {
    private let checkpoint: RuntimeCheckpoint?
    private let recorder: RestartStepRecorder

    init(checkpoint: RuntimeCheckpoint?, recorder: RestartStepRecorder) {
        self.checkpoint = checkpoint
        self.recorder = recorder
    }

    func save(_ checkpoint: RuntimeCheckpoint) async throws {}

    func latest(streamID: String) async throws -> RuntimeCheckpoint? {
        await recorder.record("checkpoint")
        return checkpoint
    }
}

private actor RestartEventStore: EventStoring {
    private let storedEvents: [RuntimeEvent]
    private let recorder: RestartStepRecorder

    init(events: [RuntimeEvent], recorder: RestartStepRecorder) {
        self.storedEvents = events
        self.recorder = recorder
    }

    func append(_ event: RuntimeEvent) async throws {}

    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent] {
        await recorder.record("events")
        return storedEvents.filter { $0.streamID == streamID && $0.sequence > sequence }
    }
}

private actor RestartReplayExecutor: ReplayExecuting {
    private let recorder: RestartStepRecorder

    init(recorder: RestartStepRecorder) {
        self.recorder = recorder
    }

    func receipt(for recordedEvent: RuntimeEvent) async throws -> ToolExecutionReceipt {
        await recorder.record("replay")
        let startedAt = Date(timeIntervalSince1970: 50)
        return ToolExecutionReceipt(
            invocationID: InvocationID(rawValue: "replayed-invocation"),
            toolID: ToolID(rawValue: "computer.pointer.click"),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            providerReference: "read-only-replay",
            resultProvenance: "replay",
            resultTainted: false
        )
    }
}

private actor RestartRestoreDependencies:
    RuntimeRegistryRefreshing,
    CredentialHandleDiscarding,
    CurrentPolicyLoading,
    WorldReobserving,
    OutstandingMutationReconciling,
    ReadinessRebuilding
{
    private let recorder: RestartStepRecorder
    private let outstandingMutation: ExternalMutationRecord?

    init(
        recorder: RestartStepRecorder,
        outstandingMutation: ExternalMutationRecord? = nil
    ) {
        self.recorder = recorder
        self.outstandingMutation = outstandingMutation
    }

    func refreshRegistry() async throws {
        await recorder.record("registry")
    }

    func discardCredentialHandles() async throws {
        await recorder.record("credentials")
    }

    func loadCurrentPolicy() async throws {
        await recorder.record("policy")
    }

    func reobserveWorld() async throws {
        await recorder.record("world")
    }

    func reconcileOutstandingMutations() async throws {
        await recorder.record("mutations")
        guard let outstandingMutation else {
            return
        }

        let decision = await MutationReconciler(
            policy: .failClosedForUnknownHighRisk
        ).decide(record: outstandingMutation)
        if case .requiresManualResolution = decision {
            throw AutonomousRuntimeError.manualResolutionRequired
        }
    }

    func rebuildReadiness() async throws {
        await recorder.record("readiness")
    }
}

private actor RecordingRestartPhysicalExecutor: TaskInvocationExecuting {
    private(set) var calls = 0

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        calls += 1
        return .modelFinalText("unexpected physical execution")
    }

    func cancelActiveInvocation() async {}
}

private struct RestartTaskVerifier: TaskVerifying {
    func verify(task: TaskNode, executionResult: TaskExecutionResult) async -> TaskVerificationResult {
        .rejected(reason: "unused during restore")
    }
}

private struct RestartGoalVerifier: GoalVerifying {
    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult {
        GoalVerificationResult(completed: false, evidence: nil)
    }
}

private struct RestartPlanner: Planning {
    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) async throws -> PlanningProposal {
        PlanningProposal(addTasks: [], addDependencies: [], markBlocked: [])
    }
}
