import Foundation
import SQLite3

enum SQLiteMemoryStoreError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case databaseFailure(String)
}

actor SQLiteMemoryStore: MemoryStoring {
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(databaseURL: databaseURL)
        try database.execute(Self.schemaSQL)
    }

    func save(_ record: MemoryRecord) async throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(record)
        } catch {
            throw SQLiteMemoryStoreError.encodingFailed
        }

        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.upsertSQL)
        } catch {
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(record.id, to: statement, at: 1)
        try bindText(record.kind, to: statement, at: 2)
        try bindText(record.scope.storageKey, to: statement, at: 3)
        try bindBlob(payload, to: statement, at: 4)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    func record(id: String) async throws -> MemoryRecord? {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectByIDSQL)
        } catch {
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(id, to: statement, at: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeRecord(from: statement, column: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    func semantic(id: String) async throws -> SemanticMemoryRecord? {
        guard let record = try await record(id: id) else {
            return nil
        }
        guard case .semantic(let semantic) = record else {
            return nil
        }
        return semantic
    }

    func records(scope: MemoryScope) async throws -> [MemoryRecord] {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectByScopeSQL)
        } catch {
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(scope.storageKey, to: statement, at: 1)

        var records: [MemoryRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try decodeRecord(from: statement, column: 0))
            case SQLITE_DONE:
                return records
            default:
                throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
            }
        }
    }

    private func decodeRecord(from statement: OpaquePointer, column: Int32) throws -> MemoryRecord {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw SQLiteMemoryStoreError.decodingFailed
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        let data = Data(bytes: bytes, count: count)
        do {
            return try JSONDecoder().decode(MemoryRecord.self, from: data)
        } catch {
            throw SQLiteMemoryStoreError.decodingFailed
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func bindBlob(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return sqlite3_bind_blob(statement, index, nil, 0, Self.sqliteTransient)
            }
            return sqlite3_bind_blob(statement, index, baseAddress, Int32(buffer.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteMemoryStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS v2_memory_records (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        scope_key TEXT NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_v2_memory_records_scope
        ON v2_memory_records(scope_key);
    """

    private static let upsertSQL = """
    INSERT OR REPLACE INTO v2_memory_records (id, kind, scope_key, payload)
    VALUES (?, ?, ?, ?);
    """

    private static let selectByIDSQL = """
    SELECT payload
    FROM v2_memory_records
    WHERE id = ?
    LIMIT 1;
    """

    private static let selectByScopeSQL = """
    SELECT payload
    FROM v2_memory_records
    WHERE scope_key = ?
    ORDER BY rowid ASC;
    """

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
