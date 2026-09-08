import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteAgentPersistence: AgentEventStore, AgentConversationStore, AgentMemoryStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let maxRecordBytes: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL, maxRecordBytes: Int = 64 * 1024) throws {
        guard maxRecordBytes > 0 else {
            throw AgentPersistenceError.recordTooLarge
        }
        self.maxRecordBytes = maxRecordBytes

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            if let opened {
                sqlite3_close(opened)
            }
            throw AgentPersistenceError.storageFailure
        }
        database = opened

        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=1000")
            try verifySchemaVersion()
            try createSchema()
        } catch {
            sqlite3_close(opened)
            database = nil
            throw normalized(error)
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    @discardableResult
    public func append(_ event: AgentEvent) throws -> StoredAgentEvent {
        try withLock {
            try validateSessionID(event.sessionID)
            guard event.cycle >= 0,
                  event.stateVersion <= UInt64(Int64.max),
                  event.questionGeneration <= UInt64(Int64.max) else {
                throw AgentPersistenceError.malformedRecord
            }

            let sanitized = AgentPersistenceSanitizer.event(event)
            let statement = try prepare(
                """
                INSERT INTO agent_events(
                    session_id, kind, cycle, state_version, question_generation, detail
                ) VALUES (?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }

            try bindText(sanitized.sessionID, to: statement, at: 1)
            try bindText(sanitized.kind.rawValue, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(sanitized.cycle))
            sqlite3_bind_int64(statement, 4, Int64(sanitized.stateVersion))
            sqlite3_bind_int64(statement, 5, Int64(sanitized.questionGeneration))
            try bindText(sanitized.detail, to: statement, at: 6)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AgentPersistenceError.storageFailure
            }

            let sequence = sqlite3_last_insert_rowid(database)
            return StoredAgentEvent(sequence: sequence, event: sanitized)
        }
    }

    public func events(sessionID: String) throws -> [StoredAgentEvent] {
        try withLock {
            try validateSessionID(sessionID)
            let statement = try prepare(
                """
                SELECT sequence, kind, cycle, state_version, question_generation, detail
                FROM agent_events
                WHERE session_id = ?
                ORDER BY sequence ASC
                """
            )
            defer { sqlite3_finalize(statement) }
            try bindText(sessionID, to: statement, at: 1)

            var values: [StoredAgentEvent] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let sequence = sqlite3_column_int64(statement, 0)
                    guard let kindValue = columnText(statement, at: 1),
                          let kind = AgentEventKind(rawValue: kindValue),
                          let detail = columnText(statement, at: 5) else {
                        throw AgentPersistenceError.malformedRecord
                    }
                    let cycle = sqlite3_column_int64(statement, 2)
                    let stateVersion = sqlite3_column_int64(statement, 3)
                    let questionGeneration = sqlite3_column_int64(statement, 4)
                    guard sequence > 0,
                          cycle >= 0,
                          stateVersion >= 0,
                          questionGeneration >= 0,
                          cycle <= Int64(Int.max) else {
                        throw AgentPersistenceError.malformedRecord
                    }

                    values.append(
                        StoredAgentEvent(
                            sequence: sequence,
                            event: AgentEvent(
                                sessionID: sessionID,
                                kind: kind,
                                cycle: Int(cycle),
                                stateVersion: UInt64(stateVersion),
                                questionGeneration: UInt64(questionGeneration),
                                detail: detail
                            )
                        )
                    )
                case SQLITE_DONE:
                    return values
                default:
                    throw AgentPersistenceError.storageFailure
                }
            }
        }
    }

    public func saveConversation(_ record: AgentConversationRecord) throws {
        try saveRecord(
            table: "agent_conversations",
            sessionID: record.sessionID,
            value: record
        )
    }

    public func conversation(sessionID: String) throws -> AgentConversationRecord? {
        let value: AgentConversationRecord? = try loadRecord(
            table: "agent_conversations",
            sessionID: sessionID,
            as: AgentConversationRecord.self
        )
        guard value?.sessionID == sessionID || value == nil else {
            throw AgentPersistenceError.malformedRecord
        }
        return value
    }

    public func saveMemory(_ record: AgentMemoryRecord) throws {
        try saveRecord(
            table: "agent_memory",
            sessionID: record.sessionID,
            value: record
        )
    }

    public func memory(sessionID: String) throws -> AgentMemoryRecord? {
        let value: AgentMemoryRecord? = try loadRecord(
            table: "agent_memory",
            sessionID: sessionID,
            as: AgentMemoryRecord.self
        )
        guard value?.sessionID == sessionID || value == nil else {
            throw AgentPersistenceError.malformedRecord
        }
        return value
    }

    private func saveRecord<T: Encodable>(
        table: String,
        sessionID: String,
        value: T
    ) throws {
        try withLock {
            try validateSessionID(sessionID)
            let data: Data
            do {
                data = try encoder.encode(value)
            } catch {
                throw AgentPersistenceError.malformedRecord
            }
            guard data.count <= maxRecordBytes else {
                throw AgentPersistenceError.recordTooLarge
            }

            let statement = try prepare(
                """
                INSERT INTO \(table)(session_id, payload)
                VALUES (?, ?)
                ON CONFLICT(session_id) DO UPDATE SET payload = excluded.payload
                """
            )
            defer { sqlite3_finalize(statement) }
            try bindText(sessionID, to: statement, at: 1)
            try bindData(data, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw AgentPersistenceError.storageFailure
            }
        }
    }

    private func loadRecord<T: Decodable>(
        table: String,
        sessionID: String,
        as type: T.Type
    ) throws -> T? {
        try withLock {
            try validateSessionID(sessionID)
            let statement = try prepare(
                "SELECT payload FROM \(table) WHERE session_id = ? LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try bindText(sessionID, to: statement, at: 1)

            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                let byteCount = Int(sqlite3_column_bytes(statement, 0))
                guard byteCount >= 0, byteCount <= maxRecordBytes else {
                    throw AgentPersistenceError.recordTooLarge
                }
                guard byteCount == 0 || sqlite3_column_blob(statement, 0) != nil else {
                    throw AgentPersistenceError.malformedRecord
                }
                let data: Data
                if byteCount == 0 {
                    data = Data()
                } else if let bytes = sqlite3_column_blob(statement, 0) {
                    data = Data(bytes: bytes, count: byteCount)
                } else {
                    throw AgentPersistenceError.malformedRecord
                }
                do {
                    return try decoder.decode(type, from: data)
                } catch {
                    throw AgentPersistenceError.malformedRecord
                }
            default:
                throw AgentPersistenceError.storageFailure
            }
        }
    }

    private func validateSessionID(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value == trimmed,
              value.count <= 200,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentPersistenceError.invalidSessionID
        }
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS agent_events(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                cycle INTEGER NOT NULL CHECK(cycle >= 0),
                state_version INTEGER NOT NULL CHECK(state_version >= 0),
                question_generation INTEGER NOT NULL CHECK(question_generation >= 0),
                detail TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS agent_events_session_sequence
                ON agent_events(session_id, sequence);
            CREATE TRIGGER IF NOT EXISTS agent_events_no_update
                BEFORE UPDATE ON agent_events
                BEGIN
                    SELECT RAISE(ABORT, 'agent_events_append_only');
                END;
            CREATE TRIGGER IF NOT EXISTS agent_events_no_delete
                BEFORE DELETE ON agent_events
                BEGIN
                    SELECT RAISE(ABORT, 'agent_events_append_only');
                END;
            CREATE TABLE IF NOT EXISTS agent_conversations(
                session_id TEXT PRIMARY KEY,
                payload BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agent_memory(
                session_id TEXT PRIMARY KEY,
                payload BLOB NOT NULL
            );
            PRAGMA user_version=1;
            """
        )
    }

    private func verifySchemaVersion() throws {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AgentPersistenceError.storageFailure
        }
        let version = sqlite3_column_int(statement, 0)
        guard version == 0 || version == 1 else {
            throw AgentPersistenceError.storageFailure
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw AgentPersistenceError.storageFailure
        }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AgentPersistenceError.storageFailure
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw AgentPersistenceError.storageFailure
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AgentPersistenceError.storageFailure
        }
        return statement
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw AgentPersistenceError.storageFailure
        }
    }

    private func bindData(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(data.count),
                sqliteTransient
            )
        }
        guard result == SQLITE_OK else {
            throw AgentPersistenceError.storageFailure
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try operation()
        } catch {
            throw normalized(error)
        }
    }

    private func normalized(_ error: Error) -> AgentPersistenceError {
        error as? AgentPersistenceError ?? .storageFailure
    }
}
