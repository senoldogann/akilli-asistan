import Foundation
import SQLite3

enum ExternalMutationState: String, Codable, Sendable {
    case alreadyApplied
    case notApplied
    case unknown
}

struct ExternalMutationRecord: Codable, Sendable, Equatable {
    let logicalOperationID: String
    let idempotencyKey: String
    let invocationID: InvocationID
    let attempt: UInt32
    let risk: RiskLevel
    let receipt: Data?
    let verification: Data?
    let externalReference: String?
    let externalState: ExternalMutationState
}

enum ExternalMutationJournalError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case databaseFailure(String)
}

actor ExternalMutationJournal {
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(databaseURL: databaseURL)
        try database.execute(Self.schemaSQL)
    }

    func append(_ record: ExternalMutationRecord) async throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(record)
        } catch {
            throw ExternalMutationJournalError.encodingFailed
        }

        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.insertSQL)
        } catch {
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(record.logicalOperationID, to: statement, at: 1)
        guard sqlite3_bind_int64(statement, 2, sqlite3_int64(record.attempt)) == SQLITE_OK else {
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
        }
        try bindText(record.idempotencyKey, to: statement, at: 3)
        try bindBlob(payload, to: statement, at: 4)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
        }
    }

    func latest(logicalOperationID: String) async throws -> ExternalMutationRecord? {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectLatestSQL)
        } catch {
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(logicalOperationID, to: statement, at: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeRecord(from: statement, column: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
        }
    }

    private func decodeRecord(from statement: OpaquePointer, column: Int32) throws -> ExternalMutationRecord {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw ExternalMutationJournalError.decodingFailed
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        let data = Data(bytes: bytes, count: count)

        do {
            return try JSONDecoder().decode(ExternalMutationRecord.self, from: data)
        } catch {
            throw ExternalMutationJournalError.decodingFailed
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
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
            throw ExternalMutationJournalError.databaseFailure(database.lastErrorMessage())
        }
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS v2_external_mutation_journal (
        logical_operation_id TEXT NOT NULL,
        attempt INTEGER NOT NULL,
        idempotency_key TEXT NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY (logical_operation_id, attempt)
    );
    CREATE INDEX IF NOT EXISTS idx_v2_external_mutation_journal_operation
        ON v2_external_mutation_journal(logical_operation_id, attempt DESC);
    """

    private static let insertSQL = """
    INSERT INTO v2_external_mutation_journal (
        logical_operation_id,
        attempt,
        idempotency_key,
        payload
    ) VALUES (?, ?, ?, ?);
    """

    private static let selectLatestSQL = """
    SELECT payload
    FROM v2_external_mutation_journal
    WHERE logical_operation_id = ?
    ORDER BY attempt DESC
    LIMIT 1;
    """

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
