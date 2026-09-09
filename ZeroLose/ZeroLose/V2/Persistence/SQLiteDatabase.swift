import Foundation
import SQLite3

enum SQLiteDatabaseError: Error, Equatable {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
}

final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    init(databaseURL: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)

        guard result == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "sqlite3_open_v2 failed with code \(result)"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteDatabaseError.openFailed(message)
        }

        handle = database
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw SQLiteDatabaseError.executeFailed("Database is closed")
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map(String.init(cString:))
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseError.executeFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteDatabaseError.prepareFailed("Database is closed")
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    func lastErrorMessage() -> String {
        guard let handle else { return "Database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}
