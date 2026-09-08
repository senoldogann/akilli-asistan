import Foundation
import SQLite3
import XCTest
@testable import ExamPilotCore

final class SQLiteAgentPersistenceTests: XCTestCase {
    func testEventsAppendInMonotonicOrderAndReadBySession() throws {
        try withTemporaryDatabase { url in
            let store = try SQLiteAgentPersistence(url: url)

            let first = try store.append(event(sessionID: "session-a", cycle: 1, detail: "observation_accepted"))
            let other = try store.append(event(sessionID: "session-b", cycle: 1, detail: "proposal_received"))
            let second = try store.append(event(sessionID: "session-a", cycle: 2, detail: "answer_mutation_verified"))

            XCTAssertLessThan(first.sequence, other.sequence)
            XCTAssertLessThan(other.sequence, second.sequence)
            XCTAssertEqual(
                try store.events(sessionID: "session-a").map(\.sequence),
                [first.sequence, second.sequence]
            )
            XCTAssertEqual(
                try store.events(sessionID: "session-a").map(\.event.detail),
                ["observation_accepted", "answer_mutation_verified"]
            )
        }
    }

    func testUnsafeEventDetailIsRedactedBeforeSQLiteWrite() throws {
        try withTemporaryDatabase { url in
            let store = try SQLiteAgentPersistence(url: url)
            _ = try store.append(
                event(
                    sessionID: "session-redaction",
                    cycle: 1,
                    detail: "Authorization: Bearer private-token"
                )
            )

            let events = try store.events(sessionID: "session-redaction")
            XCTAssertEqual(events.map(\.event.detail), ["redacted_detail"])

            let raw = try String(contentsOf: url, encoding: .isoLatin1)
            XCTAssertFalse(raw.contains("private-token"))
            XCTAssertFalse(raw.lowercased().contains("authorization"))
        }
    }

    func testConversationAndMemoryAreSeparateReplaceableRecords() throws {
        try withTemporaryDatabase { url in
            let store = try SQLiteAgentPersistence(url: url)

            try store.saveConversation(
                AgentConversationRecord(
                    sessionID: "session-checkpoint",
                    state: ProviderConversationState(
                        previousResponseID: "resp_old",
                        pendingComputerCallID: "call_old"
                    )
                )
            )
            try store.saveMemory(
                AgentMemoryRecord(
                    sessionID: "session-checkpoint",
                    snapshot: AgentWorkingMemorySnapshot(
                        currentRecoveryStrategy: .waitForStability
                    )
                )
            )
            try store.saveConversation(
                AgentConversationRecord(
                    sessionID: "session-checkpoint",
                    state: ProviderConversationState(
                        previousResponseID: "resp_new",
                        pendingComputerCallID: nil
                    )
                )
            )

            XCTAssertEqual(
                try store.conversation(sessionID: "session-checkpoint")?.state,
                ProviderConversationState(previousResponseID: "resp_new", pendingComputerCallID: nil)
            )
            XCTAssertEqual(
                try store.memory(sessionID: "session-checkpoint")?.snapshot.currentRecoveryStrategy,
                .waitForStability
            )
        }
    }

    func testRecordsSurviveStoreReopen() throws {
        try withTemporaryDatabase { url in
            do {
                let store = try SQLiteAgentPersistence(url: url)
                _ = try store.append(event(sessionID: "session-reopen", cycle: 1, detail: "observation_accepted"))
                try store.saveConversation(
                    AgentConversationRecord(
                        sessionID: "session-reopen",
                        state: ProviderConversationState(previousResponseID: "resp_1")
                    )
                )
            }

            let reopened = try SQLiteAgentPersistence(url: url)
            XCTAssertEqual(try reopened.events(sessionID: "session-reopen").count, 1)
            XCTAssertEqual(
                try reopened.conversation(sessionID: "session-reopen")?.state.previousResponseID,
                "resp_1"
            )
        }
    }

    func testDatabaseTriggerRejectsEventUpdateAndDelete() throws {
        try withTemporaryDatabase { url in
            let store = try SQLiteAgentPersistence(url: url)
            _ = try store.append(event(sessionID: "session-append-only", cycle: 1, detail: "observation_accepted"))

            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }

            XCTAssertNotEqual(
                sqlite3_exec(db, "UPDATE agent_events SET detail='tampered' WHERE sequence=1", nil, nil, nil),
                SQLITE_OK
            )
            XCTAssertNotEqual(
                sqlite3_exec(db, "DELETE FROM agent_events WHERE sequence=1", nil, nil, nil),
                SQLITE_OK
            )
            XCTAssertEqual(try store.events(sessionID: "session-append-only").count, 1)
            XCTAssertEqual(try store.events(sessionID: "session-append-only").first?.event.detail, "observation_accepted")
        }
    }

    func testMalformedConversationBlobFailsClosed() throws {
        try withTemporaryDatabase { url in
            let store = try SQLiteAgentPersistence(url: url)
            try store.saveConversation(
                AgentConversationRecord(
                    sessionID: "session-corrupt",
                    state: ProviderConversationState(previousResponseID: "resp_valid")
                )
            )

            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "UPDATE agent_conversations SET payload=X'7B' WHERE session_id='session-corrupt'",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )

            XCTAssertThrowsError(try store.conversation(sessionID: "session-corrupt")) { error in
                XCTAssertEqual(error as? AgentPersistenceError, .malformedRecord)
            }
        }
    }

    func testInvalidSessionAndOversizedRecordsFailBeforeWrite() throws {
        try withTemporaryDatabase { url in
            let store = try SQLiteAgentPersistence(url: url, maxRecordBytes: 128)

            XCTAssertThrowsError(try store.events(sessionID: "")) { error in
                XCTAssertEqual(error as? AgentPersistenceError, .invalidSessionID)
            }

            XCTAssertThrowsError(
                try store.saveConversation(
                    AgentConversationRecord(
                        sessionID: "session-large",
                        state: ProviderConversationState(previousResponseID: String(repeating: "x", count: 512))
                    )
                )
            ) { error in
                XCTAssertEqual(error as? AgentPersistenceError, .recordTooLarge)
            }
        }
    }

    private func event(sessionID: String, cycle: Int, detail: String) -> AgentEvent {
        AgentEvent(
            sessionID: sessionID,
            kind: .observationAccepted,
            cycle: cycle,
            stateVersion: UInt64(cycle),
            questionGeneration: 1,
            detail: detail
        )
    }

    private func withTemporaryDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exampilot-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try body(directory.appendingPathComponent("agent.sqlite"))
    }
}
