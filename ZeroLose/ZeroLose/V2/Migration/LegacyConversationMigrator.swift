import Foundation
import SQLite3

struct LegacyConversationChunk: Sendable, Equatable {
    let sourceRecordID: String
    let sessionID: String
    let text: String
    let recordedAt: Date
}

protocol LegacyConversationReading: Sendable {
    func records() async throws -> [LegacyConversationChunk]
}

enum LegacyConversationReaderError: Error, Equatable {
    case sourceOpenFailed
    case queryFailed
    case malformedRecord(String)
    case malformedMetadata(String)
}

actor SQLiteLegacyConversationReader: LegacyConversationReading {
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    init() {
        self.databaseURL = Self.defaultDatabaseURL()
    }

    func records() async throws -> [LegacyConversationChunk] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw LegacyConversationReaderError.sourceOpenFailed
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT id, chunk_text, metadata_json, created_at
        FROM embeddings
        ORDER BY created_at ASC, rowid ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LegacyConversationReaderError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var result: [LegacyConversationChunk] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idPointer = sqlite3_column_text(statement, 0),
                      let textPointer = sqlite3_column_text(statement, 1),
                      let metadataPointer = sqlite3_column_text(statement, 2) else {
                    throw LegacyConversationReaderError.malformedRecord("unknown")
                }

                let sourceRecordID = String(cString: idPointer)
                let text = String(cString: textPointer)
                let metadataJSON = String(cString: metadataPointer)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))

                guard let metadataData = metadataJSON.data(using: .utf8),
                      let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
                    throw LegacyConversationReaderError.malformedMetadata(sourceRecordID)
                }

                guard let sourceType = metadata["sourceType"] as? String else {
                    throw LegacyConversationReaderError.malformedMetadata(sourceRecordID)
                }
                guard sourceType == "chat" else {
                    continue
                }
                guard let sessionID = metadata["sourceID"] as? String,
                      !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LegacyConversationReaderError.malformedMetadata(sourceRecordID)
                }

                let timestamp = (metadata["timestamp"] as? Double)
                    .map(Date.init(timeIntervalSince1970:)) ?? createdAt
                result.append(
                    LegacyConversationChunk(
                        sourceRecordID: sourceRecordID,
                        sessionID: sessionID,
                        text: text,
                        recordedAt: timestamp
                    )
                )
            case SQLITE_DONE:
                return result
            default:
                throw LegacyConversationReaderError.queryFailed
            }
        }
    }

    private nonisolated static func defaultDatabaseURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("ZeroLose/vectors.db")
    }
}

enum LegacyConversationMigrationError: Error, Equatable {
    case readbackMismatch(String)
}

actor LegacyConversationMigrator {
    private let source: any LegacyConversationReading
    private let destination: any ConversationStoring
    private let stateStore: MigrationStateStore

    init(
        source: any LegacyConversationReading,
        destination: any ConversationStoring,
        stateStore: MigrationStateStore
    ) {
        self.source = source
        self.destination = destination
        self.stateStore = stateStore
    }

    func run() async throws {
        await stateStore.set(.running)
        do {
            let sourceRecords = try await source.records()
            let messages = sourceRecords.flatMap(Self.makeMessages(from:))

            for message in messages {
                try await destination.save(message)
            }

            for expected in messages {
                guard let restored = try await destination.message(id: expected.id),
                      restored == expected else {
                    throw LegacyConversationMigrationError.readbackMismatch(expected.id)
                }
            }

            await stateStore.set(.completed)
        } catch {
            await stateStore.set(.failed)
            throw error
        }
    }

    private nonisolated static func makeMessages(from record: LegacyConversationChunk) -> [ConversationMessage] {
        let blocks = record.text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parsed = blocks.enumerated().compactMap { index, block -> ConversationMessage? in
            let role: ConversationRole
            let text: String
            if block.hasPrefix("USER:") {
                role = .user
                text = String(block.dropFirst("USER:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if block.hasPrefix("AI:") {
                role = .assistant
                text = String(block.dropFirst("AI:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return nil
            }

            return makeMessage(
                record: record,
                ordinal: index,
                role: role,
                text: text
            )
        }

        if !blocks.isEmpty, parsed.count == blocks.count {
            return parsed
        }

        return [
            makeMessage(
                record: record,
                ordinal: 0,
                role: .transcript,
                text: record.text
            )
        ]
    }

    private nonisolated static func makeMessage(
        record: LegacyConversationChunk,
        ordinal: Int,
        role: ConversationRole,
        text: String
    ) -> ConversationMessage {
        ConversationMessage(
            id: "legacy-vector:\(record.sourceRecordID):\(ordinal)",
            conversationID: record.sessionID,
            role: role,
            text: text,
            recordedAt: record.recordedAt,
            provenance: ConversationProvenance(
                source: .legacyVectorStore,
                sourceRecordID: record.sourceRecordID,
                sourceSessionID: record.sessionID
            ),
            verifiedSemanticTruth: false
        )
    }
}
