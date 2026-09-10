import Foundation
import XCTest
@testable import ZeroLose

final class SchedulerTests: XCTestCase {
    func testMutationTasksAreSerializedByDefault() async {
        let scheduler = Scheduler(maxParallelReads: 4)
        let ready = [
            TaskNode(
                id: TaskID(rawValue: "m1"),
                title: "Mutation one",
                lifecycle: .ready,
                concurrencyClass: .mutation
            ),
            TaskNode(
                id: TaskID(rawValue: "m2"),
                title: "Mutation two",
                lifecycle: .ready,
                concurrencyClass: .mutation
            )
        ]

        let selected = await scheduler.select(from: ready)

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first, TaskID(rawValue: "m1"))
    }

    func testReadsRespectConfiguredBound() async {
        let scheduler = Scheduler(maxParallelReads: 2)
        let ready = (1...5).map { index in
            TaskNode(
                id: TaskID(rawValue: "r\(index)"),
                title: "Read \(index)",
                lifecycle: .ready,
                concurrencyClass: .read
            )
        }

        let selected = await scheduler.select(from: ready)

        XCTAssertEqual(selected.count, 2)
        XCTAssertEqual(selected, [TaskID(rawValue: "r1"), TaskID(rawValue: "r2")])
    }

    func testSchedulerSelectsReadyTasksOnly() async {
        let scheduler = Scheduler(maxParallelReads: 4)
        let tasks = [
            TaskNode(
                id: TaskID(rawValue: "created"),
                title: "Created",
                lifecycle: .created,
                concurrencyClass: .read
            ),
            TaskNode(
                id: TaskID(rawValue: "ready"),
                title: "Ready",
                lifecycle: .ready,
                concurrencyClass: .read
            ),
            TaskNode(
                id: TaskID(rawValue: "blocked"),
                title: "Blocked",
                lifecycle: .blocked,
                concurrencyClass: .read
            )
        ]

        let selected = await scheduler.select(from: tasks)

        XCTAssertEqual(selected, [TaskID(rawValue: "ready")])
    }

    func testZeroReadLimitSelectsNoReadTasks() async {
        let scheduler = Scheduler(maxParallelReads: 0)
        let ready = [
            TaskNode(
                id: TaskID(rawValue: "r1"),
                title: "Read",
                lifecycle: .ready,
                concurrencyClass: .read
            )
        ]

        let selected = await scheduler.select(from: ready)

        XCTAssertTrue(selected.isEmpty)
    }

    func testSchedulerSourceContainsNoExecutionAuthorityDependencies() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schedulerURL = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Autonomy/Scheduler.swift")

        guard FileManager.default.fileExists(atPath: schedulerURL.path) else {
            XCTFail("Scheduler.swift must exist")
            return
        }

        let source = try String(contentsOf: schedulerURL, encoding: .utf8)
        for forbidden in ["ToolFabric", "InputDriving", "ComputerMutationGating", "OpenAI", "URLSession"] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Scheduler must not own execution authority through \(forbidden)"
            )
        }
    }
}
