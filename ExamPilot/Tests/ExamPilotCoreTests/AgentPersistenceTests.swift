import XCTest
@testable import ExamPilotCore

final class AgentPersistenceTests: XCTestCase {
    func testStoredEventSanitizesUnsafeDetailBeforePersistence() {
        let unsafe = AgentEvent(
            sessionID: "session-persistence-1",
            kind: .proposalReceived,
            cycle: 3,
            stateVersion: 7,
            questionGeneration: 2,
            detail: "Authorization: Bearer private-token"
        )

        let stored = StoredAgentEvent(sequence: 1, event: unsafe)

        XCTAssertEqual(stored.sequence, 1)
        XCTAssertEqual(stored.event.sessionID, "session-persistence-1")
        XCTAssertEqual(stored.event.detail, "redacted_detail")
    }

    func testStoredEventKeepsBoundedIdentifierDetail() {
        let safe = AgentEvent(
            sessionID: "session-persistence-2",
            kind: .outcomeVerified,
            cycle: 4,
            stateVersion: 9,
            questionGeneration: 2,
            detail: "answer_mutation_verified"
        )

        let stored = StoredAgentEvent(sequence: 2, event: safe)

        XCTAssertEqual(stored.event.detail, "answer_mutation_verified")
    }

    func testPersistenceRecordsRoundTripWithoutSecretMetadataFields() throws {
        let conversation = AgentConversationRecord(
            sessionID: "session-conversation-1",
            state: ProviderConversationState(
                previousResponseID: "resp_123",
                pendingComputerCallID: "call_456"
            )
        )
        let memory = AgentMemoryRecord(
            sessionID: "session-memory-1",
            snapshot: AgentWorkingMemorySnapshot(
                currentRecoveryStrategy: .reobserveAndReplan
            )
        )
        let event = StoredAgentEvent(
            sequence: 3,
            event: AgentEvent(
                sessionID: "session-event-1",
                kind: .recoveryPlanned,
                cycle: 5,
                stateVersion: 10,
                questionGeneration: 2,
                detail: "reobserve_and_replan"
            )
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let conversationData = try encoder.encode(conversation)
        let memoryData = try encoder.encode(memory)
        let eventData = try encoder.encode(event)

        XCTAssertEqual(
            try decoder.decode(AgentConversationRecord.self, from: conversationData),
            conversation
        )
        XCTAssertEqual(
            try decoder.decode(AgentMemoryRecord.self, from: memoryData),
            memory
        )
        XCTAssertEqual(
            try decoder.decode(StoredAgentEvent.self, from: eventData),
            event
        )

        let serialized = String(
            decoding: conversationData + memoryData + eventData,
            as: UTF8.self
        ).lowercased()
        XCTAssertFalse(serialized.contains("authorization"))
        XCTAssertFalse(serialized.contains("api_key"))
        XCTAssertFalse(serialized.contains("screenshot"))
    }

    func testPersistenceErrorExposesStableBoundedDiagnosticIdentifier() {
        XCTAssertEqual(AgentPersistenceError.invalidSessionID.diagnosticID, "invalid_session_id")
        XCTAssertEqual(AgentPersistenceError.recordTooLarge.diagnosticID, "record_too_large")
        XCTAssertEqual(AgentPersistenceError.malformedRecord.diagnosticID, "malformed_record")
        XCTAssertEqual(AgentPersistenceError.storageFailure.diagnosticID, "storage_failure")
    }
}
