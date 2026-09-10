import Foundation
import XCTest
@testable import ZeroLose

final class PlannerContractTests: XCTestCase {
    func testPlanningProposalContainsGraphChangesOnly() {
        let inspect = TaskNode(
            id: TaskID(rawValue: "inspect"),
            title: "Inspect current state"
        )
        let mutate = TaskNode(
            id: TaskID(rawValue: "mutate"),
            title: "Apply verified mutation"
        )
        let dependency = TaskDependency(
            taskID: mutate.id,
            dependsOn: inspect.id
        )

        let proposal = PlanningProposal(
            addTasks: [inspect, mutate],
            addDependencies: [dependency],
            markBlocked: [mutate.id]
        )

        XCTAssertEqual(proposal.addTasks.map(\.id), [inspect.id, mutate.id])
        XCTAssertEqual(proposal.addDependencies, [dependency])
        XCTAssertEqual(proposal.markBlocked, [mutate.id])
    }

    func testPlanningProtocolConsumesImmutableSnapshotsAndReturnsProposal() async throws {
        let planner = RecordingPlanner()
        let goal = GoalSnapshot(
            id: GoalID(rawValue: "goal-1"),
            objective: "Inspect before mutating"
        )
        let graph = TaskGraphSnapshot(
            goalID: goal.id,
            revision: 3,
            tasks: [:]
        )
        let budgets = RuntimeBudgetSnapshot(
            remainingModelCalls: 4,
            remainingToolCalls: 6,
            remainingRecoveryAttempts: 2,
            remainingExternalSpend: 0,
            deadline: nil
        )

        let proposal = try await planner.propose(
            goal: goal,
            graph: graph,
            budgets: budgets
        )

        XCTAssertTrue(proposal.addTasks.isEmpty)
        let calls = await planner.calls
        XCTAssertEqual(calls, 1)
    }

    func testPlannerSourceContainsNoExecutionAuthorityDependencies() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plannerURL = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Autonomy/Planner.swift")

        guard FileManager.default.fileExists(atPath: plannerURL.path) else {
            XCTFail("Planner.swift must exist")
            return
        }

        let source = try String(contentsOf: plannerURL, encoding: .utf8)
        for forbidden in ["ToolFabric", "InputDriving", "ComputerMutationGating"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Planner must not own execution authority through \(forbidden)"
            )
        }
    }
}

private actor RecordingPlanner: Planning {
    private(set) var calls = 0

    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot
    ) async throws -> PlanningProposal {
        calls += 1
        return PlanningProposal(
            addTasks: [],
            addDependencies: [],
            markBlocked: []
        )
    }
}
