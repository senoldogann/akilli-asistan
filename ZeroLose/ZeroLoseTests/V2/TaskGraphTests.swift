import XCTest
@testable import ZeroLose

final class TaskGraphTests: XCTestCase {
    func testAddingTaskCreatesNewGraphRevision() async throws {
        let graph = TaskGraph(goalID: GoalID(rawValue: "g1"))

        let initialRevision = await graph.revision
        XCTAssertEqual(initialRevision, 0)

        try await graph.add(
            TaskNode(
                id: TaskID(rawValue: "t1"),
                title: "Inspect current state"
            )
        )

        let updatedRevision = await graph.revision
        XCTAssertEqual(updatedRevision, 1)
        let snapshot = await graph.snapshot()
        XCTAssertEqual(snapshot.tasks[TaskID(rawValue: "t1")]?.lifecycle, .created)
    }

    func testSucceededRequiresVerificationEvidence() async throws {
        let graph = TaskGraph(goalID: GoalID(rawValue: "g1"))
        let taskID = TaskID(rawValue: "t1")
        try await graph.add(TaskNode(id: taskID, title: "Verify result"))

        do {
            try await graph.transition(taskID: taskID, to: .succeeded, evidence: nil)
            XCTFail("Task success must require verifier evidence")
        } catch {
            XCTAssertEqual(error as? TaskGraphError, .verificationEvidenceRequired)
        }

        let snapshot = await graph.snapshot()
        XCTAssertNotEqual(snapshot.tasks[taskID]?.lifecycle, .succeeded)
    }

    func testGraphMutationEmitsMonotonicRevisionEvent() async throws {
        let store = RecordingTaskGraphEventStore()
        let graph = TaskGraph(
            goalID: GoalID(rawValue: "g1"),
            eventStore: store
        )

        try await graph.add(
            TaskNode(
                id: TaskID(rawValue: "t1"),
                title: "Inspect current state"
            )
        )

        let events = await store.recordedEvents
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventKind, .taskGraph)
        XCTAssertEqual(events.first?.taskGraphRevision, 1)
        XCTAssertEqual(events.first?.goalID, GoalID(rawValue: "g1"))
    }
}

private actor RecordingTaskGraphEventStore: EventStoring {
    private(set) var recordedEvents: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) async throws {
        recordedEvents.append(event)
    }

    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent] {
        recordedEvents.filter { $0.streamID == streamID && $0.sequence > sequence }
    }
}
