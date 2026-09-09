import Foundation
import SQLite3

enum SQLiteEventStoreError: Error, Equatable {
    case nonPersistableEvent
    case unsupportedSchemaVersion(UInt32)
    case invalidStoredValue(String)
    case integerOverflow(String)
    case databaseFailure(String)
}

actor SQLiteEventStore: EventStoring {
    private static let supportedSchemaVersion: UInt32 = 1
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(databaseURL: databaseURL)
        try database.execute(Self.createTableSQL)
    }

    func append(_ event: RuntimeEvent) async throws {
        guard event.redactionClass.isPersistable else {
            throw SQLiteEventStoreError.nonPersistableEvent
        }
        guard event.schemaVersion == Self.supportedSchemaVersion else {
            throw SQLiteEventStoreError.unsupportedSchemaVersion(event.schemaVersion)
        }

        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.insertSQL)
        } catch {
            throw SQLiteEventStoreError.databaseFailure(String(describing: error))
        }
        defer { sqlite3_finalize(statement) }

        do {
            try bind(event, to: statement)
        } catch {
            throw error
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent] {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectSQL)
        } catch {
            throw SQLiteEventStoreError.databaseFailure(String(describing: error))
        }
        defer { sqlite3_finalize(statement) }

        try bindText(streamID, to: statement, index: 1)
        try bindUnsigned(sequence, to: statement, index: 2, field: "sequence")

        var result: [RuntimeEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeEvent(from: statement))
            case SQLITE_DONE:
                return result
            default:
                throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
            }
        }
    }

    private func bind(_ event: RuntimeEvent, to statement: OpaquePointer) throws {
        try bindText(event.eventID.rawValue, to: statement, index: 1)
        try bindText(event.streamID, to: statement, index: 2)
        try bindUnsigned(event.sequence, to: statement, index: 3, field: "sequence")
        try bindUnsigned(UInt64(event.schemaVersion), to: statement, index: 4, field: "schemaVersion")
        try bindOptionalText(event.goalID?.rawValue, to: statement, index: 5)
        try bindOptionalText(event.taskID?.rawValue, to: statement, index: 6)
        try bindOptionalText(event.sessionID?.rawValue, to: statement, index: 7)
        try bindText(event.eventKind.rawValue, to: statement, index: 8)
        try bindOptionalText(event.causationID, to: statement, index: 9)
        try bindOptionalText(event.correlationID, to: statement, index: 10)
        try bindOptionalUnsigned(event.taskGraphRevision, to: statement, index: 11, field: "taskGraphRevision")
        try bindOptionalUnsigned(event.toolRegistryRevision, to: statement, index: 12, field: "toolRegistryRevision")
        try bindOptionalUnsigned(event.policyRevision, to: statement, index: 13, field: "policyRevision")
        try bindBlob(event.payload, to: statement, index: 14)
        try bindText(event.redactionClass.rawValue, to: statement, index: 15)
        try bindText(event.provenance, to: statement, index: 16)

        guard sqlite3_bind_int(statement, 17, event.tainted ? 1 : 0) == SQLITE_OK else {
            throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
        }
        guard sqlite3_bind_double(statement, 18, event.recordedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func decodeEvent(from statement: OpaquePointer) throws -> RuntimeEvent {
        let schemaVersionValue = sqlite3_column_int64(statement, 3)
        guard schemaVersionValue >= 0, schemaVersionValue <= Int64(UInt32.max) else {
            throw SQLiteEventStoreError.invalidStoredValue("schemaVersion")
        }
        let schemaVersion = UInt32(schemaVersionValue)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw SQLiteEventStoreError.unsupportedSchemaVersion(schemaVersion)
        }

        guard let eventKindRaw = columnText(statement, index: 7),
              let eventKind = RuntimeEventKind(rawValue: eventKindRaw) else {
            throw SQLiteEventStoreError.invalidStoredValue("eventKind")
        }
        guard let redactionRaw = columnText(statement, index: 14),
              let redactionClass = RedactionClass(rawValue: redactionRaw),
              redactionClass.isPersistable else {
            throw SQLiteEventStoreError.invalidStoredValue("redactionClass")
        }
        guard let eventID = columnText(statement, index: 0),
              let streamID = columnText(statement, index: 1),
              let provenance = columnText(statement, index: 15) else {
            throw SQLiteEventStoreError.invalidStoredValue("required text column")
        }

        let sequence = try columnUnsigned(statement, index: 2, field: "sequence")
        let payload = columnBlob(statement, index: 13)
        let tainted = sqlite3_column_int(statement, 16) != 0
        let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))

        return RuntimeEvent(
            eventID: RuntimeEventID(rawValue: eventID),
            streamID: streamID,
            sequence: sequence,
            schemaVersion: schemaVersion,
            goalID: columnText(statement, index: 4).map(GoalID.init(rawValue:)),
            taskID: columnText(statement, index: 5).map(TaskID.init(rawValue:)),
            sessionID: columnText(statement, index: 6).map(SessionID.init(rawValue:)),
            eventKind: eventKind,
            causationID: columnText(statement, index: 8),
            correlationID: columnText(statement, index: 9),
            taskGraphRevision: try columnOptionalUnsigned(statement, index: 10, field: "taskGraphRevision"),
            toolRegistryRevision: try columnOptionalUnsigned(statement, index: 11, field: "toolRegistryRevision"),
            policyRevision: try columnOptionalUnsigned(statement, index: 12, field: "policyRevision"),
            payload: payload,
            redactionClass: redactionClass,
            provenance: provenance,
            tainted: tainted,
            recordedAt: recordedAt
        )
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer, index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
            }
            return
        }
        try bindText(value, to: statement, index: index)
    }

    private func bindUnsigned(_ value: UInt64, to statement: OpaquePointer, index: Int32, field: String) throws {
        guard value <= UInt64(Int64.max) else {
            throw SQLiteEventStoreError.integerOverflow(field)
        }
        guard sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK else {
            throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func bindOptionalUnsigned(_ value: UInt64?, to statement: OpaquePointer, index: Int32, field: String) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
            }
            return
        }
        try bindUnsigned(value, to: statement, index: index, field: field)
    }

    private func bindBlob(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        let result = data.withUnsafeBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return sqlite3_bind_blob(statement, index, nil, 0, Self.sqliteTransient)
            }
            return sqlite3_bind_blob(statement, index, baseAddress, Int32(buffer.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteEventStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func columnBlob(_ statement: OpaquePointer, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }

    private func columnUnsigned(_ statement: OpaquePointer, index: Int32, field: String) throws -> UInt64 {
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else {
            throw SQLiteEventStoreError.invalidStoredValue(field)
        }
        return UInt64(value)
    }

    private func columnOptionalUnsigned(_ statement: OpaquePointer, index: Int32, field: String) throws -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return try columnUnsigned(statement, index: index, field: field)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS runtime_events (
        event_id TEXT NOT NULL UNIQUE,
        stream_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        schema_version INTEGER NOT NULL,
        goal_id TEXT,
        task_id TEXT,
        session_id TEXT,
        event_kind TEXT NOT NULL,
        causation_id TEXT,
        correlation_id TEXT,
        task_graph_revision INTEGER,
        tool_registry_revision INTEGER,
        policy_revision INTEGER,
        payload BLOB NOT NULL,
        redaction_class TEXT NOT NULL,
        provenance TEXT NOT NULL,
        tainted INTEGER NOT NULL,
        recorded_at REAL NOT NULL,
        PRIMARY KEY (stream_id, sequence)
    );
    """

    private static let insertSQL = """
    INSERT INTO runtime_events (
        event_id, stream_id, sequence, schema_version, goal_id, task_id, session_id,
        event_kind, causation_id, correlation_id, task_graph_revision,
        tool_registry_revision, policy_revision, payload, redaction_class,
        provenance, tainted, recorded_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """

    private static let selectSQL = """
    SELECT
        event_id, stream_id, sequence, schema_version, goal_id, task_id, session_id,
        event_kind, causation_id, correlation_id, task_graph_revision,
        tool_registry_revision, policy_revision, payload, redaction_class,
        provenance, tainted, recorded_at
    FROM runtime_events
    WHERE stream_id = ? AND sequence > ?
    ORDER BY sequence ASC;
    """
}
