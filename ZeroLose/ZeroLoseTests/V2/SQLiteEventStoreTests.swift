import Foundation
import SQLite3
import XCTest
@testable import ZeroLose

final class SQLiteEventStoreTests: XCTestCase {
    func testEventsReturnInSequenceOrder() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteEventStore(databaseURL: databaseURL)
        try await store.append(.test(streamID: "g1", sequence: 2))
        try await store.append(.test(streamID: "g1", sequence: 1))

        let events = try await store.events(streamID: "g1", after: 0)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
    }

    func testUnknownSchemaVersionFailsClosed() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteEventStore(databaseURL: databaseURL)
        try await store.append(.test(streamID: "g1", sequence: 1))
        try overwriteSchemaVersion(999, streamID: "g1", sequence: 1, databaseURL: databaseURL)

        do {
            _ = try await store.events(streamID: "g1", after: 0)
            XCTFail("Expected unsupported schema version to fail closed")
        } catch let error as SQLiteEventStoreError {
            XCTAssertEqual(error, .unsupportedSchemaVersion(999))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialMaterialIsNeverPersisted() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteEventStore(databaseURL: databaseURL)
        let event = RuntimeEvent.test(
            streamID: "g1",
            sequence: 1,
            redactionClass: .credentialMaterial
        )

        do {
            try await store.append(event)
            XCTFail("Expected credential material persistence to fail closed")
        } catch let error as SQLiteEventStoreError {
            XCTAssertEqual(error, .nonPersistableEvent)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try await store.events(streamID: "g1", after: 0), [])
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zerolose-v2-events-\(UUID().uuidString).sqlite")
    }

    private func overwriteSchemaVersion(
        _ schemaVersion: UInt32,
        streamID: String,
        sequence: UInt64,
        databaseURL: URL
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw TestSQLiteError.openFailed
        }
        defer { sqlite3_close(database) }

        let sql = "UPDATE runtime_events SET schema_version = \(schemaVersion) WHERE stream_id = '\(streamID)' AND sequence = \(sequence);"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestSQLiteError.updateFailed
        }
    }
}

private enum TestSQLiteError: Error {
    case openFailed
    case updateFailed
}

private extension RuntimeEvent {
    static func test(
        streamID: String,
        sequence: UInt64,
        schemaVersion: UInt32 = 1,
        redactionClass: RedactionClass = .normal
    ) -> RuntimeEvent {
        RuntimeEvent(
            eventID: RuntimeEventID(rawValue: "event-\(streamID)-\(sequence)"),
            streamID: streamID,
            sequence: sequence,
            schemaVersion: schemaVersion,
            goalID: GoalID(rawValue: "goal-1"),
            taskID: TaskID(rawValue: "task-1"),
            sessionID: SessionID(rawValue: "session-1"),
            eventKind: .runtime,
            causationID: "cause-1",
            correlationID: "correlation-1",
            taskGraphRevision: 3,
            toolRegistryRevision: 4,
            policyRevision: 5,
            payload: Data("{\"status\":\"ok\"}".utf8),
            redactionClass: redactionClass,
            provenance: "test",
            tainted: false,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
