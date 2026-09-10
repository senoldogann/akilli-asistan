import Foundation
import XCTest
@testable import ZeroLose

final class RuntimeProjectionCoordinatorTests: XCTestCase {
    func testRecorderContinuesExistingRuntimeStreamSequenceAfterRestart() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteEventStore(databaseURL: databaseURL)
        try await store.append(makeExistingEvent(streamID: "runtime:test", sequence: 3))

        let recorder = RuntimeEventRecorder(eventStore: store, streamID: "runtime:test")
        try await recorder.recordTool(
            invocationID: InvocationID(rawValue: "inv-4"),
            toolID: ToolID(rawValue: "builtin.system_status"),
            state: .started,
            summary: "System status started",
            tainted: false
        )

        let events = try await store.events(streamID: "runtime:test", after: 0)
        XCTAssertEqual(events.map(\.sequence), [3, 4])
    }

    @MainActor
    func testCoordinatorConsumesOnlyUnseenToolEventsAndMarksReceiptExecutedNotSucceeded() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteEventStore(databaseURL: databaseURL)
        let recorder = RuntimeEventRecorder(eventStore: store, streamID: "runtime:test")
        let timeline = TimelineProjection()
        let coordinator = RuntimeProjectionCoordinator(
            eventStore: store,
            streamID: "runtime:test",
            timeline: timeline
        )

        try await recorder.recordTool(
            invocationID: InvocationID(rawValue: "inv-1"),
            toolID: ToolID(rawValue: "builtin.system_status"),
            state: .started,
            summary: "System status started",
            tainted: false
        )
        try await recorder.recordTool(
            invocationID: InvocationID(rawValue: "inv-1"),
            toolID: ToolID(rawValue: "builtin.system_status"),
            state: .completed,
            summary: "System status completed",
            tainted: false
        )

        await coordinator.refresh()

        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(timeline.items.count, 1)
        XCTAssertEqual(timeline.items[0].id, "tool:inv-1")
        XCTAssertEqual(timeline.items[0].state, .executed)
        XCTAssertEqual(timeline.items[0].summary, "System status completed")

        await coordinator.refresh()
        XCTAssertEqual(timeline.items.count, 1, "Refresh must not replay already-consumed events")
    }

    @MainActor
    func testFailedToolEventProjectsAsFailedWithoutExposingArguments() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteEventStore(databaseURL: databaseURL)
        let recorder = RuntimeEventRecorder(eventStore: store, streamID: "runtime:test")
        let timeline = TimelineProjection()
        let coordinator = RuntimeProjectionCoordinator(
            eventStore: store,
            streamID: "runtime:test",
            timeline: timeline
        )

        try await recorder.recordTool(
            invocationID: InvocationID(rawValue: "inv-secret"),
            toolID: ToolID(rawValue: "builtin.web_search"),
            state: .failed,
            summary: "Web search denied by policy",
            tainted: true
        )

        await coordinator.refresh()

        XCTAssertEqual(timeline.items.count, 1)
        XCTAssertEqual(timeline.items[0].state, .failed)
        XCTAssertEqual(timeline.items[0].summary, "Web search denied by policy")

        let events = try await store.events(streamID: "runtime:test", after: 0)
        XCTAssertEqual(events.count, 1)
        let payloadText = String(data: events[0].payload, encoding: .utf8) ?? ""
        XCTAssertFalse(payloadText.contains("argumentsJSON"))
        XCTAssertFalse(payloadText.contains("credential"))
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zerolose-v2-runtime-projection-\(UUID().uuidString).sqlite")
    }

    private func makeExistingEvent(streamID: String, sequence: UInt64) -> RuntimeEvent {
        RuntimeEvent(
            eventID: RuntimeEventID(rawValue: "existing-\(sequence)"),
            streamID: streamID,
            sequence: sequence,
            schemaVersion: 1,
            goalID: nil,
            taskID: nil,
            sessionID: nil,
            eventKind: .runtime,
            causationID: nil,
            correlationID: nil,
            taskGraphRevision: nil,
            toolRegistryRevision: nil,
            policyRevision: nil,
            payload: Data("{}".utf8),
            redactionClass: .normal,
            provenance: "test",
            tainted: false,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
