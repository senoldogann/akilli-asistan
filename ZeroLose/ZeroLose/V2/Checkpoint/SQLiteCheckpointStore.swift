import Foundation
import SQLite3

enum SQLiteCheckpointStoreError: Error, Equatable {
    case databaseFailure(String)
    case encodingFailure(String)
    case invalidCheckpoint(String)
    case integerOverflow(String)
}

actor SQLiteCheckpointStore: CheckpointStoring {
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(databaseURL: databaseURL)
        try database.execute(Self.createTableSQL)
    }

    func save(_ checkpoint: RuntimeCheckpoint) async throws {
        guard checkpoint.eventSequence <= UInt64(Int64.max) else {
            throw SQLiteCheckpointStoreError.integerOverflow("eventSequence")
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(checkpoint)
        } catch {
            throw SQLiteCheckpointStoreError.encodingFailure(String(describing: error))
        }

        guard encoded.count <= Int(Int32.max) else {
            throw SQLiteCheckpointStoreError.integerOverflow("checkpointBlob")
        }

        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.insertSQL)
        } catch {
            throw SQLiteCheckpointStoreError.databaseFailure(String(describing: error))
        }
        defer { sqlite3_finalize(statement) }

        try bindText(checkpoint.streamID, to: statement, index: 1)
        guard sqlite3_bind_int64(statement, 2, Int64(checkpoint.eventSequence)) == SQLITE_OK else {
            throw SQLiteCheckpointStoreError.databaseFailure(database.lastErrorMessage())
        }
        try bindBlob(encoded, to: statement, index: 3)
        guard sqlite3_bind_double(statement, 4, checkpoint.createdAt.timeIntervalSince1970) == SQLITE_OK else {
            throw SQLiteCheckpointStoreError.databaseFailure(database.lastErrorMessage())
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteCheckpointStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    func latest(streamID: String) async throws -> RuntimeCheckpoint? {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectLatestSQL)
        } catch {
            throw SQLiteCheckpointStoreError.databaseFailure(String(describing: error))
        }
        defer { sqlite3_finalize(statement) }

        try bindText(streamID, to: statement, index: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let data = columnBlob(statement, index: 0)
            do {
                return try JSONDecoder().decode(RuntimeCheckpoint.self, from: data)
            } catch {
                throw SQLiteCheckpointStoreError.invalidCheckpoint(String(describing: error))
            }
        case SQLITE_DONE:
            return nil
        default:
            throw SQLiteCheckpointStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteCheckpointStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func bindBlob(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        let result = data.withUnsafeBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return sqlite3_bind_blob(statement, index, nil, 0, Self.sqliteTransient)
            }
            return sqlite3_bind_blob(statement, index, baseAddress, Int32(buffer.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteCheckpointStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func columnBlob(_ statement: OpaquePointer, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS runtime_checkpoints (
        stream_id TEXT NOT NULL,
        event_sequence INTEGER NOT NULL,
        checkpoint_blob BLOB NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (stream_id, event_sequence)
    );
    """

    private static let insertSQL = """
    INSERT INTO runtime_checkpoints (
        stream_id, event_sequence, checkpoint_blob, created_at
    ) VALUES (?, ?, ?, ?);
    """

    private static let selectLatestSQL = """
    SELECT checkpoint_blob
    FROM runtime_checkpoints
    WHERE stream_id = ?
    ORDER BY event_sequence DESC
    LIMIT 1;
    """
}
