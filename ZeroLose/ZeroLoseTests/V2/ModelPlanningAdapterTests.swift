import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class ModelPlanningAdapterTests: XCTestCase {
    func testValidStructuredPlanPreservesTaskDependencyToolAndArguments() async throws {
        let provider = RecordingModelProvider(
            id: "planner",
            events: [
                .started,
                .textDelta(
                    #"{"tasks":[{"id":"inspect","dependencies":[],"toolID":"builtin.system_status","arguments":{}},{"id":"verify","dependencies":["inspect"],"toolID":"builtin.system_status","arguments":{"detail":"summary"}}]}"#
                ),
                .completed
            ]
        )
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: ModelProviderID(rawValue: "planner")
        )
        let adapter = ModelPlanningAdapter(providerFabric: fabric, modelID: "planner-model")

        let proposal = try await adapter.propose(
            goal: goal(),
            graph: emptyGraph(),
            budgets: budget(),
            context: context(enabledToolIDs: ["builtin.system_status"])
        )

        XCTAssertEqual(proposal.addTasks.map(\.id.rawValue), ["inspect", "verify"])
        XCTAssertEqual(proposal.addTasks[1].dependencies, [TaskID(rawValue: "inspect")])
        XCTAssertEqual(
            proposal.addTasks.map { $0.plannedInvocation?.toolID.rawValue },
            ["builtin.system_status", "builtin.system_status"]
        )
        XCTAssertEqual(
            try jsonObject(proposal.addTasks[1].plannedInvocation?.argumentsJSON),
            ["detail": "summary"]
        )
        XCTAssertEqual(
            proposal.addDependencies,
            [TaskDependency(taskID: TaskID(rawValue: "verify"), dependsOn: TaskID(rawValue: "inspect"))]
        )

        let lastRequest = await provider.lastRequest
        XCTAssertEqual(lastRequest?.responseMode, .json)
        XCTAssertEqual(lastRequest?.modelID, "planner-model")
    }

    func testUnknownToolFailsClosed() async throws {
        let adapter = makeAdapter(
            json: #"{"tasks":[{"id":"inspect","dependencies":[],"toolID":"builtin.unknown","arguments":{}}]}"#
        )

        await assertInvalidProposal(adapter, context: context(enabledToolIDs: ["builtin.system_status"]))
    }

    func testCyclicDependenciesFailClosed() async throws {
        let adapter = makeAdapter(
            json: #"{"tasks":[{"id":"a","dependencies":["b"],"toolID":"builtin.system_status","arguments":{}},{"id":"b","dependencies":["a"],"toolID":"builtin.system_status","arguments":{}}]}"#
        )

        await assertInvalidProposal(adapter, context: context(enabledToolIDs: ["builtin.system_status"]))
    }

    func testMissingTaskIDFailsClosed() async throws {
        let adapter = makeAdapter(
            json: #"{"tasks":[{"dependencies":[],"toolID":"builtin.system_status","arguments":{}}]}"#
        )

        await assertInvalidProposal(adapter, context: context(enabledToolIDs: ["builtin.system_status"]))
    }

    func testFreeFormTextFailsClosed() async throws {
        let adapter = makeAdapter(json: "Inspect the computer and then continue.")

        await assertInvalidProposal(adapter, context: context(enabledToolIDs: ["builtin.system_status"]))
    }

    private func assertInvalidProposal(
        _ adapter: ModelPlanningAdapter,
        context: PlanningContext
    ) async {
        do {
            _ = try await adapter.propose(
                goal: goal(),
                graph: emptyGraph(),
                budgets: budget(),
                context: context
            )
            XCTFail("expected invalid proposal")
        } catch let error as PlanningError {
            XCTAssertEqual(error, .invalidProposal)
        } catch {
            XCTFail("expected PlanningError.invalidProposal, got \(error)")
        }
    }

    private func makeAdapter(json: String) -> ModelPlanningAdapter {
        let provider = RecordingModelProvider(
            id: "planner",
            events: [.textDelta(json), .completed]
        )
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: ModelProviderID(rawValue: "planner")
        )
        return ModelPlanningAdapter(providerFabric: fabric, modelID: "planner-model")
    }

    private func goal() -> GoalSnapshot {
        GoalSnapshot(id: GoalID(rawValue: "g1"), objective: "check status")
    }

    private func emptyGraph() -> TaskGraphSnapshot {
        TaskGraphSnapshot(goalID: GoalID(rawValue: "g1"), revision: 0, tasks: [:])
    }

    private func budget() -> RuntimeBudgetSnapshot {
        RuntimeBudgetSnapshot(
            remainingModelCalls: 4,
            remainingToolCalls: 6,
            remainingRecoveryAttempts: 2,
            remainingExternalSpend: 0,
            deadline: nil
        )
    }

    private func context(enabledToolIDs: [String]) -> PlanningContext {
        let descriptors = Dictionary(uniqueKeysWithValues: enabledToolIDs.map { id in
            let toolID = ToolID(rawValue: id)
            return (toolID, descriptor(id: id))
        })
        return PlanningContext(
            retrievedContext: ContextBundle(items: [], excluded: [], usedCharacters: 0),
            registry: ToolRegistrySnapshot(revision: 1, descriptors: descriptors)
        )
    }

    private func descriptor(id: String) -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: id),
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
    }

    private func jsonObject(_ data: Data?) throws -> NSDictionary {
        guard let data else {
            throw TestError.missingArguments
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            throw TestError.invalidArguments
        }
        return object
    }
}

private enum TestError: Error {
    case missingArguments
    case invalidArguments
}
