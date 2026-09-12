import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class ProductionAgentGoalVerifierTests: XCTestCase {
    func testGoalRejectsEmptyGraph() async throws {
        let result = try await ProductionAgentGoalVerifier().verify(
            goal: goal(),
            graph: TaskGraphSnapshot(goalID: goal().id, revision: 0, tasks: [:])
        )
        XCTAssertFalse(result.completed)
        XCTAssertNil(result.evidence)
    }

    func testGoalRejectsAnyNonSucceededTask() async throws {
        let task = makeTask(id: "t1", lifecycle: .ready, evidence: [])
        let result = try await ProductionAgentGoalVerifier().verify(
            goal: goal(),
            graph: graph(tasks: [task])
        )
        XCTAssertFalse(result.completed)
        XCTAssertNil(result.evidence)
    }

    func testGoalRejectsSucceededTaskWithoutEvidence() async throws {
        let task = makeTask(id: "t1", lifecycle: .succeeded, evidence: [])
        let result = try await ProductionAgentGoalVerifier().verify(
            goal: goal(),
            graph: graph(tasks: [task])
        )
        XCTAssertFalse(result.completed)
        XCTAssertNil(result.evidence)
    }

    func testGoalCompletesFromVerifiedTasks() async throws {
        let tasks = [
            makeTask(id: "t1", lifecycle: .succeeded, evidence: [evidence(id: "e1")]),
            makeTask(id: "t2", lifecycle: .succeeded, evidence: [evidence(id: "e2")]),
        ]

        let result = try await ProductionAgentGoalVerifier().verify(
            goal: goal(),
            graph: graph(tasks: tasks)
        )

        XCTAssertTrue(result.completed)
        XCTAssertNotNil(result.evidence)
        XCTAssertEqual(result.evidence?.tainted, false)
        XCTAssertEqual(result.evidence?.provenance, "agent-goal-verifier:task-evidence")
    }

    func testGoalEvidencePreservesTaint() async throws {
        let tasks = [
            makeTask(id: "t1", lifecycle: .succeeded, evidence: [evidence(id: "e1")]),
            makeTask(id: "t2", lifecycle: .succeeded, evidence: [evidence(id: "e2", tainted: true)]),
        ]

        let result = try await ProductionAgentGoalVerifier().verify(
            goal: goal(),
            graph: graph(tasks: tasks)
        )

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.evidence?.tainted, true)
    }

    func testGoalRejectsGraphForDifferentGoal() async throws {
        let task = makeTask(id: "t1", lifecycle: .succeeded, evidence: [evidence(id: "e1")])
        let result = try await ProductionAgentGoalVerifier().verify(
            goal: goal(),
            graph: TaskGraphSnapshot(
                goalID: GoalID(rawValue: "other-goal"),
                revision: 1,
                tasks: [task.id: task]
            )
        )
        XCTAssertFalse(result.completed)
        XCTAssertNil(result.evidence)
    }

    private func goal() -> GoalSnapshot {
        GoalSnapshot(id: GoalID(rawValue: "goal-1"), objective: "finish verified work")
    }

    private func graph(tasks: [TaskNode]) -> TaskGraphSnapshot {
        TaskGraphSnapshot(
            goalID: goal().id,
            revision: UInt64(tasks.count),
            tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        )
    }

    private func makeTask(
        id: String,
        lifecycle: TaskLifecycle,
        evidence: [VerificationEvidence]
    ) -> TaskNode {
        TaskNode(
            id: TaskID(rawValue: id),
            title: id,
            lifecycle: lifecycle,
            verificationEvidence: evidence,
            concurrencyClass: .read
        )
    }

    private func evidence(id: String, tainted: Bool = false) -> VerificationEvidence {
        VerificationEvidence(
            evidenceID: id,
            summary: "verified",
            provenance: "test-verifier",
            tainted: tainted,
            recordedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
