import Foundation
import SQLite3
import XCTest
@testable import ZeroLose

final class ConversationMigrationTests: XCTestCase {
    func testRerunDoesNotDuplicateConversation() async throws {
        let source = InMemoryLegacyConversationReader(records: [
            LegacyConversationChunk(
                sourceRecordID: "chunk-1",
                sessionID: "session-1",
                text: "USER: Hello\n\nAI: Hi there",
                recordedAt: Date(timeIntervalSince1970: 100)
            )
        ])
        let databaseURL = temporaryURL(name: "conversation.sqlite")
        let defaults = makeDefaults()
        defer {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
            clear(defaults)
        }

        let store = try SQLiteConversationStore(databaseURL: databaseURL)
        let stateStore = MigrationStateStore(defaults: defaults, namespace: "conversation-test")
        let migrator = LegacyConversationMigrator(
            source: source,
            destination: store,
            stateStore: stateStore
        )

        try await migrator.run()
        let firstCount = try await store.count()
        try await migrator.run()
        let secondCount = try await store.count()

        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(secondCount, firstCount)
    }

    func testMigrationPreservesConversationProvenanceWithoutPromotingSemanticTruth() async throws {
        let timestamp = Date(timeIntervalSince1970: 123)
        let source = InMemoryLegacyConversationReader(records: [
            LegacyConversationChunk(
                sourceRecordID: "legacy-row-7",
                sessionID: "session-abc",
                text: "USER: Keep this context\n\nAI: Context retained",
                recordedAt: timestamp
            )
        ])
        let databaseURL = temporaryURL(name: "conversation.sqlite")
        let defaults = makeDefaults()
        defer {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
            clear(defaults)
        }

        let store = try SQLiteConversationStore(databaseURL: databaseURL)
        let migrator = LegacyConversationMigrator(
            source: source,
            destination: store,
            stateStore: MigrationStateStore(defaults: defaults, namespace: "conversation-provenance")
        )

        try await migrator.run()
        let messages = try await store.messages(conversationID: "session-abc")

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Keep this context", "Context retained"])
        XCTAssertTrue(messages.allSatisfy { !$0.verifiedSemanticTruth })
        XCTAssertTrue(messages.allSatisfy { $0.provenance.source == .legacyVectorStore })
        XCTAssertTrue(messages.allSatisfy { $0.provenance.sourceRecordID == "legacy-row-7" })
        XCTAssertTrue(messages.allSatisfy { $0.provenance.sourceSessionID == "session-abc" })
        XCTAssertTrue(messages.allSatisfy { $0.recordedAt == timestamp })
    }

    func testUnparseableLegacyChunkIsPreservedLosslesslyAsTranscript() async throws {
        let sourceText = "partial overlap without role prefix AI: later response"
        let source = InMemoryLegacyConversationReader(records: [
            LegacyConversationChunk(
                sourceRecordID: "chunk-overlap",
                sessionID: "session-overlap",
                text: sourceText,
                recordedAt: Date(timeIntervalSince1970: 200)
            )
        ])
        let databaseURL = temporaryURL(name: "conversation.sqlite")
        let defaults = makeDefaults()
        defer {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
            clear(defaults)
        }

        let store = try SQLiteConversationStore(databaseURL: databaseURL)
        let migrator = LegacyConversationMigrator(
            source: source,
            destination: store,
            stateStore: MigrationStateStore(defaults: defaults, namespace: "conversation-overlap")
        )

        try await migrator.run()
        let messages = try await store.messages(conversationID: "session-overlap")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .transcript)
        XCTAssertEqual(messages.first?.text, sourceText)
    }

    func testSQLiteLegacyReaderImportsOnlyChatRowsAndIgnoresUntrustedMetadataExtras() async throws {
        let directory = temporaryURL(name: "legacy").deletingLastPathComponent()
        let legacyURL = directory.appendingPathComponent("vectors.db")
        defer { try? FileManager.default.removeItem(at: directory) }

        try createLegacyVectorDatabase(at: legacyURL)
        let reader = SQLiteLegacyConversationReader(databaseURL: legacyURL)
        let records = try await reader.records()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sourceRecordID, "chat-row")
        XCTAssertEqual(records.first?.sessionID, "session-secret")
        XCTAssertEqual(records.first?.text, "USER: hello\n\nAI: welcome")
        XCTAssertFalse(String(describing: records).contains("Bearer legacy-secret"))
    }

    func testMissingLegacyDatabaseIsSafeNoOpAndCompletesMigration() async throws {
        let directory = temporaryURL(name: "missing").deletingLastPathComponent()
        let legacyURL = directory.appendingPathComponent("does-not-exist.db")
        let destinationURL = directory.appendingPathComponent("conversation.sqlite")
        let defaults = makeDefaults()
        defer {
            try? FileManager.default.removeItem(at: directory)
            clear(defaults)
        }

        let store = try SQLiteConversationStore(databaseURL: destinationURL)
        let stateStore = MigrationStateStore(defaults: defaults, namespace: "conversation-missing")
        let migrator = LegacyConversationMigrator(
            source: SQLiteLegacyConversationReader(databaseURL: legacyURL),
            destination: store,
            stateStore: stateStore
        )

        try await migrator.run()
        let count = try await store.count()
        let state = await stateStore.state()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(state, .completed)
    }

    func testConversationMigrationSourceDoesNotDependOnRuntimeEventOrMemoryStores() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("ZeroLose/V2/Migration/LegacyConversationMigrator.swift"),
            encoding: .utf8
        )

        for forbidden in ["EventStore", "EventStoring", "MemoryStore", "MemoryStoring", "CredentialHandle"] {
            XCTAssertFalse(source.contains(forbidden), "Conversation migration must not depend on \\(forbidden)")
        }
    }

    private func createLegacyVectorDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "ConversationMigrationTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE embeddings (
            id TEXT PRIMARY KEY,
            chunk_text TEXT NOT NULL,
            embedding BLOB NOT NULL,
            metadata_json TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ConversationMigrationTests", code: 2)
        }

        try insertLegacyRow(
            db: db,
            id: "chat-row",
            text: "USER: hello\n\nAI: welcome",
            metadata: #"{"sourceType":"chat","sourceID":"session-secret","timestamp":300,"authorization":"Bearer legacy-secret"}"#,
            createdAt: 300
        )
        try insertLegacyRow(
            db: db,
            id: "pdf-row",
            text: "not conversation history",
            metadata: #"{"sourceType":"pdf","sourceID":"document.pdf","timestamp":301}"#,
            createdAt: 301
        )
    }

    private func insertLegacyRow(
        db: OpaquePointer,
        id: String,
        text: String,
        metadata: String,
        createdAt: Double
    ) throws {
        let sql = "INSERT INTO embeddings (id, chunk_text, embedding, metadata_json, created_at) VALUES (?, ?, X'00000000', ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "ConversationMigrationTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, text, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, metadata, -1, sqliteTransient)
        sqlite3_bind_double(statement, 4, createdAt)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "ConversationMigrationTests", code: 4)
        }
    }

    private func temporaryURL(name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroLose.ConversationMigrationTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ZeroLose.ConversationMigrationTests.\(UUID().uuidString)")!
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

private actor InMemoryLegacyConversationReader: LegacyConversationReading {
    let storedRecords: [LegacyConversationChunk]

    init(records: [LegacyConversationChunk]) {
        storedRecords = records
    }

    func records() async throws -> [LegacyConversationChunk] {
        storedRecords
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
