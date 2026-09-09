import XCTest
@testable import ExamPilotCore

final class AgentPersistenceCoordinatorTests: XCTestCase {
    func testCompositeSinkPreservesSinkOrdering() {
        var calls: [String] = []
        let first = RecordingSink { calls.append("first:\($0.kind.rawValue)") }
        let second = RecordingSink { calls.append("second:\($0.kind.rawValue)") }
        let sink = CompositeAgentEventSink(sinks: [first, second])

        sink.record(sampleEvent(kind: .proposalReceived))

        XCTAssertEqual(calls, ["first:proposalReceived", "second:proposalReceived"])
    }

    func testPersistentSinkReportsOnlyBoundedErrorIdentifier() {
        let store = MemoryStores()
        store.appendError = ArbitraryStorageError.rawDetail("private-storage-detail-42")
        var reported: [String] = []
        let sink = PersistentAgentEventSink(
            store: store,
            onFailure: { reported.append($0) }
        )

        sink.record(
            AgentEvent(
                sessionID: "session-error",
                kind: .proposalReceived,
                cycle: 1,
                stateVersion: 1,
                questionGeneration: 1,
                detail: "user supplied private content 42"
            )
        )

        XCTAssertEqual(reported, ["storage_failure"])
        XCTAssertFalse(reported.joined().contains("private-storage-detail-42"))
        XCTAssertFalse(reported.joined().contains("user supplied private content 42"))
    }

    func testCheckpointStoresConversationAndMemorySeparately() throws {
        let stores = MemoryStores()
        let coordinator = AgentPersistenceCoordinator(
            eventStore: stores,
            conversationStore: stores,
            memoryStore: stores
        )
        let session = ComputerAgentSession(id: "session-checkpoint", goal: "Authorized task")
        session.updatePreviousResponseID("resp_1")
        session.setCurrentRecoveryStrategy(.waitForStability)
        session.recordFailure(.transitionStillRunning, recoveryStrategy: .waitForStability)

        try coordinator.checkpoint(session: session)

        XCTAssertEqual(stores.savedConversations.count, 1)
        XCTAssertEqual(stores.savedMemories.count, 1)
        XCTAssertEqual(stores.savedConversations.first?.sessionID, "session-checkpoint")
        XCTAssertEqual(stores.savedConversations.first?.state.previousResponseID, "resp_1")
        XCTAssertEqual(
            stores.savedMemories.first?.snapshot.currentRecoveryStrategy,
            .waitForStability
        )
        XCTAssertEqual(stores.savedMemories.first?.snapshot.failures.count, 1)
    }

    func testPrepareResumeReadsHistoryWithoutWritingOrCreatingLiveAuthority() throws {
        let stores = MemoryStores()
        stores.storedEvents = [
            StoredAgentEvent(
                sequence: 1,
                event: sampleEvent(
                    sessionID: "session-resume",
                    kind: .observationAccepted,
                    stateVersion: 1
                )
            ),
            StoredAgentEvent(
                sequence: 2,
                event: sampleEvent(
                    sessionID: "session-resume",
                    kind: .answerVerified,
                    stateVersion: 2
                )
            ),
        ]
        stores.storedConversation = AgentConversationRecord(
            sessionID: "session-resume",
            state: ProviderConversationState(
                previousResponseID: "resp_historical",
                pendingComputerCallID: "call_historical"
            )
        )
        stores.storedMemory = AgentMemoryRecord(
            sessionID: "session-resume",
            snapshot: AgentWorkingMemorySnapshot(
                currentRecoveryStrategy: .reobserveAndReplan
            )
        )
        let coordinator = AgentPersistenceCoordinator(
            eventStore: stores,
            conversationStore: stores,
            memoryStore: stores
        )

        let checkpoint = try coordinator.prepareResume(sessionID: "session-resume")

        XCTAssertTrue(checkpoint.replaySnapshot.historicalAnswerVerified)
        XCTAssertTrue(checkpoint.requiresFreshObservation)
        XCTAssertTrue(checkpoint.requiresReconciliation)
        XCTAssertFalse(checkpoint.restoresRuntimeAuthority)
        XCTAssertEqual(stores.eventsReadCount, 1)
        XCTAssertEqual(stores.conversationReadCount, 1)
        XCTAssertEqual(stores.memoryReadCount, 1)
        XCTAssertEqual(stores.appendCount, 0)
        XCTAssertTrue(stores.savedConversations.isEmpty)
        XCTAssertTrue(stores.savedMemories.isEmpty)
    }

    func testPrepareResumeNormalizesUnknownStoreFailure() {
        let stores = MemoryStores()
        stores.readError = ArbitraryStorageError.rawDetail("private-storage-path-detail")
        let coordinator = AgentPersistenceCoordinator(
            eventStore: stores,
            conversationStore: stores,
            memoryStore: stores
        )

        XCTAssertThrowsError(try coordinator.prepareResume(sessionID: "session-resume")) { error in
            XCTAssertEqual(error as? AgentPersistenceError, .storageFailure)
            XCTAssertFalse(error.localizedDescription.contains("private-storage-path-detail"))
        }
    }

    private func sampleEvent(
        sessionID: String = "session-sink",
        kind: AgentEventKind,
        stateVersion: UInt64 = 1
    ) -> AgentEvent {
        AgentEvent(
            sessionID: sessionID,
            kind: kind,
            cycle: 1,
            stateVersion: stateVersion,
            questionGeneration: 1,
            detail: "bounded_detail"
        )
    }
}

private final class RecordingSink: AgentEventSinking {
    private let handler: (AgentEvent) -> Void

    init(handler: @escaping (AgentEvent) -> Void) {
        self.handler = handler
    }

    func record(_ event: AgentEvent) {
        handler(event)
    }
}

private enum ArbitraryStorageError: Error, LocalizedError {
    case rawDetail(String)

    var errorDescription: String? {
        switch self {
        case .rawDetail(let value):
            return value
        }
    }
}

private final class MemoryStores: AgentEventStore, AgentConversationStore, AgentMemoryStore {
    var storedEvents: [StoredAgentEvent] = []
    var storedConversation: AgentConversationRecord?
    var storedMemory: AgentMemoryRecord?
    var savedConversations: [AgentConversationRecord] = []
    var savedMemories: [AgentMemoryRecord] = []
    var appendError: Error?
    var readError: Error?
    var appendCount = 0
    var eventsReadCount = 0
    var conversationReadCount = 0
    var memoryReadCount = 0

    func append(_ event: AgentEvent) throws -> StoredAgentEvent {
        appendCount += 1
        if let appendError { throw appendError }
        let stored = StoredAgentEvent(
            sequence: Int64(storedEvents.count + 1),
            event: event
        )
        storedEvents.append(stored)
        return stored
    }

    func events(sessionID: String) throws -> [StoredAgentEvent] {
        eventsReadCount += 1
        if let readError { throw readError }
        return storedEvents.filter { $0.event.sessionID == sessionID }
    }

    func saveConversation(_ record: AgentConversationRecord) throws {
        if let readError { throw readError }
        savedConversations.append(record)
        storedConversation = record
    }

    func conversation(sessionID: String) throws -> AgentConversationRecord? {
        conversationReadCount += 1
        if let readError { throw readError }
        return storedConversation?.sessionID == sessionID ? storedConversation : nil
    }

    func saveMemory(_ record: AgentMemoryRecord) throws {
        if let readError { throw readError }
        savedMemories.append(record)
        storedMemory = record
    }

    func memory(sessionID: String) throws -> AgentMemoryRecord? {
        memoryReadCount += 1
        if let readError { throw readError }
        return storedMemory?.sessionID == sessionID ? storedMemory : nil
    }
}
