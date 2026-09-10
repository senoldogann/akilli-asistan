import Foundation
import XCTest
@testable import ZeroLose

final class AutonomousRuntimeResumeTests: XCTestCase {
    func testResumeNeverExecutesCheckpointedPhysicalProposal() async throws {
        let recorder = RestoreOrderRecorder()
        let checkpoint = makeCheckpoint(
            providerContinuationMetadata: Data(
                #"{"computer_call":{"actions":[{"type":"click","x":100,"y":200}]}}"#.utf8
            )
        )
        let checkpointStore = StubCheckpointStore(checkpoint: checkpoint)
        let eventStore = StubEventStore(events: [try makeToolEvent(sequence: 11)])
        let replayExecutor = RecordingReplayExecutor(recorder: recorder)
        let dependencies = RecordingRestoreDependencies(recorder: recorder)
        let runtime = makeRuntime(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            replayExecutor: replayExecutor,
            dependencies: dependencies,
            goalVerifier: RejectingGoalVerifier()
        )

        try await runtime.restore()

        let lifecycle = await runtime.lifecycle
        let requiresReconciliation = await runtime.requiresReconciliation
        let steps = await recorder.steps
        let eventRequest = await eventStore.lastRequest
        let checkpointStreamID = checkpoint.streamID
        let checkpointEventSequence = checkpoint.eventSequence

        XCTAssertEqual(lifecycle, .paused)
        XCTAssertFalse(requiresReconciliation)
        XCTAssertEqual(
            steps,
            ["replay", "registry", "credentials", "policy", "world", "mutations", "readiness"]
        )
        XCTAssertEqual(eventRequest?.streamID, checkpointStreamID)
        XCTAssertEqual(eventRequest?.afterSequence, checkpointEventSequence)
    }

    func testRestoreFailureRemainsPausedAndRequiresReconciliation() async throws {
        let recorder = RestoreOrderRecorder()
        let checkpointStore = StubCheckpointStore(checkpoint: makeCheckpoint())
        let eventStore = StubEventStore(events: [])
        let replayExecutor = RecordingReplayExecutor(recorder: recorder)
        let dependencies = RecordingRestoreDependencies(
            recorder: recorder,
            failingStep: .world
        )
        let runtime = makeRuntime(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            replayExecutor: replayExecutor,
            dependencies: dependencies,
            goalVerifier: RejectingGoalVerifier()
        )

        do {
            try await runtime.restore()
            XCTFail("Restore must fail closed when re-observation fails")
        } catch {
            XCTAssertEqual(error as? RestoreTestError, .injectedFailure(.world))
        }

        let lifecycle = await runtime.lifecycle
        let requiresReconciliation = await runtime.requiresReconciliation
        let steps = await recorder.steps

        XCTAssertEqual(lifecycle, .paused)
        XCTAssertTrue(requiresReconciliation)
        XCTAssertEqual(steps, ["registry", "credentials", "policy", "world"])
    }

    func testGoalCompletionRequiresGoalVerifier() async throws {
        let recorder = RestoreOrderRecorder()
        let dependencies = RecordingRestoreDependencies(recorder: recorder)
        let runtime = makeRuntime(
            checkpointStore: StubCheckpointStore(checkpoint: makeCheckpoint()),
            eventStore: StubEventStore(events: []),
            replayExecutor: RecordingReplayExecutor(recorder: recorder),
            dependencies: dependencies,
            goalVerifier: RejectingGoalVerifier()
        )

        let result = try await runtime.evaluateGoalCompletion()

        XCTAssertFalse(result.completed)
        let lifecycle = await runtime.lifecycle
        XCTAssertNotEqual(lifecycle, .completed)
    }

    func testGoalVerifierCanCompleteGoalWithIndependentEvidence() async throws {
        let recorder = RestoreOrderRecorder()
        let dependencies = RecordingRestoreDependencies(recorder: recorder)
        let evidence = VerificationEvidence(
            evidenceID: "goal-evidence-1",
            summary: "Goal success criteria independently observed",
            provenance: "goal-verifier",
            recordedAt: Date(timeIntervalSince1970: 200)
        )
        let runtime = makeRuntime(
            checkpointStore: StubCheckpointStore(checkpoint: makeCheckpoint()),
            eventStore: StubEventStore(events: []),
            replayExecutor: RecordingReplayExecutor(recorder: recorder),
            dependencies: dependencies,
            goalVerifier: AcceptingGoalVerifier(evidence: evidence)
        )

        let result = try await runtime.evaluateGoalCompletion()

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.evidence, evidence)
        let lifecycle = await runtime.lifecycle
        XCTAssertEqual(lifecycle, .completed)
    }

    func testGoalVerifierCannotCompleteGoalWithoutEvidence() async throws {
        let recorder = RestoreOrderRecorder()
        let dependencies = RecordingRestoreDependencies(recorder: recorder)
        let runtime = makeRuntime(
            checkpointStore: StubCheckpointStore(checkpoint: makeCheckpoint()),
            eventStore: StubEventStore(events: []),
            replayExecutor: RecordingReplayExecutor(recorder: recorder),
            dependencies: dependencies,
            goalVerifier: EvidenceFreeCompletingGoalVerifier()
        )

        let result = try await runtime.evaluateGoalCompletion()

        XCTAssertFalse(result.completed)
        XCTAssertNil(result.evidence)
        let lifecycle = await runtime.lifecycle
        XCTAssertNotEqual(lifecycle, .completed)
    }

    func testAutonomousRuntimeSourceContainsNoLivePhysicalExecutionAuthority() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeURL = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Autonomy/AutonomousRuntime.swift")

        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            XCTFail("AutonomousRuntime.swift must exist")
            return
        }

        let source = try String(contentsOf: runtimeURL, encoding: .utf8)
        for forbidden in [
            "ToolInvocation",
            "ToolFabricComputerMutationGateway",
            "ComputerMutationGating",
            "InputDriving"
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Restore runtime must not own live physical execution authority through \(forbidden)"
            )
        }
    }

    private func makeRuntime(
        checkpointStore: StubCheckpointStore,
        eventStore: StubEventStore,
        replayExecutor: RecordingReplayExecutor,
        dependencies: RecordingRestoreDependencies,
        goalVerifier: any GoalVerifying
    ) -> AutonomousRuntime {
        let goal = GoalSnapshot(
            id: GoalID(rawValue: "goal-1"),
            objective: "Reach independently verified completion"
        )
        let graph = TaskGraph(goalID: goal.id)

        return AutonomousRuntime(
            streamID: "goal-1",
            goal: goal,
            graph: graph,
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            replayExecutor: replayExecutor,
            registryRefresher: dependencies,
            credentialHandleDiscarder: dependencies,
            currentPolicyLoader: dependencies,
            worldReobserver: dependencies,
            mutationReconciler: dependencies,
            readinessRebuilder: dependencies,
            goalVerifier: goalVerifier
        )
    }

    private func makeCheckpoint(
        providerContinuationMetadata: Data? = nil
    ) -> RuntimeCheckpoint {
        RuntimeCheckpoint(
            streamID: "goal-1",
            eventSequence: 10,
            taskGraphRevision: 3,
            taskGraphSnapshot: Data("graph-snapshot".utf8),
            lifecycleSnapshot: Data("running".utf8),
            budgetSnapshot: Data("budget".utf8),
            boundedWorkingMemory: Data("memory".utf8),
            providerContinuationMetadata: providerContinuationMetadata,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeToolEvent(sequence: UInt64) throws -> RuntimeEvent {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(sequence))
        let artifact = ReplayArtifact(
            invocationID: InvocationID(rawValue: "recorded-invocation"),
            toolID: ToolID(rawValue: "builtin.recorded"),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            providerReference: "recorded-reference",
            resultProvenance: "recorded-runtime",
            resultTainted: false
        )

        return RuntimeEvent(
            eventID: RuntimeEventID(rawValue: "event-\(sequence)"),
            streamID: "goal-1",
            sequence: sequence,
            schemaVersion: 1,
            goalID: GoalID(rawValue: "goal-1"),
            taskID: nil,
            sessionID: nil,
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

private actor StubCheckpointStore: CheckpointStoring {
    private let checkpoint: RuntimeCheckpoint?

    init(checkpoint: RuntimeCheckpoint?) {
        self.checkpoint = checkpoint
    }

    func save(_ checkpoint: RuntimeCheckpoint) async throws {}

    func latest(streamID: String) async throws -> RuntimeCheckpoint? {
        checkpoint
    }
}

private struct EventReadRequest: Sendable, Equatable {
    let streamID: String
    let afterSequence: UInt64
}

private actor StubEventStore: EventStoring {
    private let storedEvents: [RuntimeEvent]
    private(set) var lastRequest: EventReadRequest?

    init(events: [RuntimeEvent]) {
        self.storedEvents = events
    }

    func append(_ event: RuntimeEvent) async throws {}

    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent] {
        lastRequest = EventReadRequest(streamID: streamID, afterSequence: sequence)
        return storedEvents
    }
}

private actor RestoreOrderRecorder {
    private(set) var steps: [String] = []

    func record(_ step: String) {
        steps.append(step)
    }
}

private actor RecordingReplayExecutor: ReplayExecuting {
    private let recorder: RestoreOrderRecorder

    init(recorder: RestoreOrderRecorder) {
        self.recorder = recorder
    }

    func receipt(for recordedEvent: RuntimeEvent) async throws -> ToolExecutionReceipt {
        await recorder.record("replay")
        let startedAt = Date(timeIntervalSince1970: 50)
        return ToolExecutionReceipt(
            invocationID: InvocationID(rawValue: "replayed-invocation"),
            toolID: ToolID(rawValue: "builtin.replayed"),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            providerReference: "replay-only",
            resultProvenance: "replay",
            resultTainted: false
        )
    }
}

private enum RestoreStep: String, Sendable, Equatable {
    case registry
    case credentials
    case policy
    case world
    case mutations
    case readiness
}

private enum RestoreTestError: Error, Equatable {
    case injectedFailure(RestoreStep)
}

private actor RecordingRestoreDependencies:
    RuntimeRegistryRefreshing,
    CredentialHandleDiscarding,
    CurrentPolicyLoading,
    WorldReobserving,
    OutstandingMutationReconciling,
    ReadinessRebuilding
{
    private let recorder: RestoreOrderRecorder
    private let failingStep: RestoreStep?

    init(
        recorder: RestoreOrderRecorder,
        failingStep: RestoreStep? = nil
    ) {
        self.recorder = recorder
        self.failingStep = failingStep
    }

    func refreshRegistry() async throws {
        try await perform(.registry)
    }

    func discardCredentialHandles() async throws {
        try await perform(.credentials)
    }

    func loadCurrentPolicy() async throws {
        try await perform(.policy)
    }

    func reobserveWorld() async throws {
        try await perform(.world)
    }

    func reconcileOutstandingMutations() async throws {
        try await perform(.mutations)
    }

    func rebuildReadiness() async throws {
        try await perform(.readiness)
    }

    private func perform(_ step: RestoreStep) async throws {
        await recorder.record(step.rawValue)
        if failingStep == step {
            throw RestoreTestError.injectedFailure(step)
        }
    }
}

private struct RejectingGoalVerifier: GoalVerifying {
    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult {
        GoalVerificationResult(completed: false, evidence: nil)
    }
}

private struct AcceptingGoalVerifier: GoalVerifying {
    let evidence: VerificationEvidence

    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult {
        GoalVerificationResult(completed: true, evidence: evidence)
    }
}

private struct EvidenceFreeCompletingGoalVerifier: GoalVerifying {
    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult {
        GoalVerificationResult(completed: true, evidence: nil)
    }
}
