import Foundation
import SQLite3

enum SQLiteConversationStoreError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case databaseFailure(String)
}

actor SQLiteConversationStore: ConversationStoring {
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(databaseURL: databaseURL)
        try database.execute(Self.schemaSQL)
    }

    func save(_ message: ConversationMessage) async throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(message)
        } catch {
            throw SQLiteConversationStoreError.encodingFailed
        }

        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.insertSQL)
        } catch {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(message.id, to: statement, at: 1)
        try bindText(message.conversationID, to: statement, at: 2)
        guard sqlite3_bind_double(statement, 3, message.recordedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
        try bindBlob(payload, to: statement, at: 4)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    func message(id: String) async throws -> ConversationMessage? {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectByIDSQL)
        } catch {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(id, to: statement, at: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeMessage(from: statement, column: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    func messages(conversationID: String) async throws -> [ConversationMessage] {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.selectByConversationSQL)
        } catch {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bindText(conversationID, to: statement, at: 1)

        var result: [ConversationMessage] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeMessage(from: statement, column: 0))
            case SQLITE_DONE:
                return result
            default:
                throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
            }
        }
    }

    func count() async throws -> Int {
        let statement: OpaquePointer
        do {
            statement = try database.prepare(Self.countSQL)
        } catch {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func decodeMessage(from statement: OpaquePointer, column: Int32) throws -> ConversationMessage {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw SQLiteConversationStoreError.decodingFailed
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        let data = Data(bytes: bytes, count: count)
        do {
            return try JSONDecoder().decode(ConversationMessage.self, from: data)
        } catch {
            throw SQLiteConversationStoreError.decodingFailed
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
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
            throw SQLiteConversationStoreError.databaseFailure(database.lastErrorMessage())
        }
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS v2_conversation_messages (
        id TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL,
        recorded_at REAL NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_v2_conversation_messages_conversation
        ON v2_conversation_messages(conversation_id, recorded_at);
    """

    private static let insertSQL = """
    INSERT OR IGNORE INTO v2_conversation_messages (id, conversation_id, recorded_at, payload)
    VALUES (?, ?, ?, ?);
    """

    private static let selectByIDSQL = """
    SELECT payload
    FROM v2_conversation_messages
    WHERE id = ?
    LIMIT 1;
    """

    private static let selectByConversationSQL = """
    SELECT payload
    FROM v2_conversation_messages
    WHERE conversation_id = ?
    ORDER BY recorded_at ASC, rowid ASC;
    """

    private static let countSQL = "SELECT COUNT(*) FROM v2_conversation_messages;"
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
