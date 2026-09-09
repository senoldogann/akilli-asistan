import XCTest
@testable import ExamPilotCore

final class AgentReplayTests: XCTestCase {
    func testReplayProjectsHistoricalAnswerAndTransitionStateDeterministically() throws {
        let events = [
            stored(1, .observationAccepted, cycle: 1, stateVersion: 1, questionGeneration: 1),
            stored(2, .answerVerified, cycle: 1, stateVersion: 2, questionGeneration: 1),
            stored(3, .boundaryTransitionStarted, cycle: 1, stateVersion: 3, questionGeneration: 1),
            stored(4, .boundaryTransitionCompleted, cycle: 2, stateVersion: 4, questionGeneration: 2),
            stored(5, .observationAccepted, cycle: 2, stateVersion: 5, questionGeneration: 2),
        ]

        let snapshot = try AgentReplayProjector().project(events: events)

        XCTAssertEqual(snapshot.sessionID, "session-replay")
        XCTAssertEqual(snapshot.eventCount, 5)
        XCTAssertEqual(snapshot.lastSequence, 5)
        XCTAssertEqual(snapshot.lastCycle, 2)
        XCTAssertEqual(snapshot.lastStateVersion, 5)
        XCTAssertEqual(snapshot.lastQuestionGeneration, 2)
        XCTAssertFalse(snapshot.historicalAnswerVerified)
        XCTAssertEqual(snapshot.historicalUIPhase, .stable)
        XCTAssertEqual(snapshot.lastEventKind, .observationAccepted)
        XCTAssertTrue(snapshot.historicalOnly)
    }

    func testReplayCanDescribeVerifiedAnswerWithoutGrantingLiveAuthority() throws {
        let snapshot = try AgentReplayProjector().project(events: [
            stored(1, .observationAccepted, cycle: 1, stateVersion: 1, questionGeneration: 1),
            stored(2, .answerVerified, cycle: 1, stateVersion: 2, questionGeneration: 1),
        ])

        XCTAssertTrue(snapshot.historicalAnswerVerified)
        XCTAssertTrue(snapshot.historicalOnly)
    }

    func testEmptyReplayIsInert() throws {
        let snapshot = try AgentReplayProjector().project(events: [])

        XCTAssertNil(snapshot.sessionID)
        XCTAssertEqual(snapshot.eventCount, 0)
        XCTAssertNil(snapshot.lastSequence)
        XCTAssertNil(snapshot.lastCycle)
        XCTAssertNil(snapshot.lastStateVersion)
        XCTAssertNil(snapshot.lastQuestionGeneration)
        XCTAssertFalse(snapshot.historicalAnswerVerified)
        XCTAssertEqual(snapshot.historicalUIPhase, .stable)
        XCTAssertNil(snapshot.lastEventKind)
        XCTAssertTrue(snapshot.historicalOnly)
    }

    func testReplayRejectsMixedSessionsAndNonMonotonicSequence() {
        let mixed = [
            stored(1, .observationAccepted, sessionID: "session-a"),
            stored(2, .proposalReceived, sessionID: "session-b"),
        ]
        XCTAssertThrowsError(try AgentReplayProjector().project(events: mixed)) { error in
            XCTAssertEqual(error as? AgentPersistenceError, .malformedRecord)
        }

        let nonMonotonic = [
            stored(2, .observationAccepted),
            stored(1, .proposalReceived),
        ]
        XCTAssertThrowsError(try AgentReplayProjector().project(events: nonMonotonic)) { error in
            XCTAssertEqual(error as? AgentPersistenceError, .malformedRecord)
        }
    }

    func testResumeCheckpointTreatsConversationAndVerifiedAnswerAsHistoricalOnly() throws {
        let replay = try AgentReplayProjector().project(events: [
            stored(1, .observationAccepted, cycle: 1, stateVersion: 1, questionGeneration: 4),
            stored(2, .answerVerified, cycle: 1, stateVersion: 2, questionGeneration: 4),
            stored(3, .boundaryTransitionStarted, cycle: 1, stateVersion: 3, questionGeneration: 4),
        ])
        let conversation = AgentConversationRecord(
            sessionID: "session-replay",
            state: ProviderConversationState(
                previousResponseID: "resp_historical",
                pendingComputerCallID: "call_historical"
            )
        )
        let memory = AgentMemoryRecord(
            sessionID: "session-replay",
            snapshot: AgentWorkingMemorySnapshot(
                currentRecoveryStrategy: .reobserveAndReplan
            )
        )

        let checkpoint = try AgentResumeCheckpoint(
            sessionID: "session-replay",
            replaySnapshot: replay,
            conversationHistory: conversation,
            memoryHistory: memory
        )

        XCTAssertTrue(checkpoint.replaySnapshot.historicalAnswerVerified)
        XCTAssertEqual(checkpoint.replaySnapshot.historicalUIPhase, .transitioning)
        XCTAssertEqual(checkpoint.conversationHistory?.state.pendingComputerCallID, "call_historical")
        XCTAssertEqual(checkpoint.memoryHistory?.snapshot.currentRecoveryStrategy, .reobserveAndReplan)
        XCTAssertTrue(checkpoint.requiresFreshObservation)
        XCTAssertTrue(checkpoint.requiresReconciliation)
        XCTAssertFalse(checkpoint.restoresRuntimeAuthority)
    }

    func testResumeCheckpointRejectsMismatchedHistoricalSession() throws {
        let replay = try AgentReplayProjector().project(events: [
            stored(1, .observationAccepted, sessionID: "session-replay")
        ])
        let conversation = AgentConversationRecord(
            sessionID: "different-session",
            state: ProviderConversationState(previousResponseID: "resp_1")
        )

        XCTAssertThrowsError(
            try AgentResumeCheckpoint(
                sessionID: "session-replay",
                replaySnapshot: replay,
                conversationHistory: conversation,
                memoryHistory: nil
            )
        ) { error in
            XCTAssertEqual(error as? AgentPersistenceError, .malformedRecord)
        }
    }

    private func stored(
        _ sequence: Int64,
        _ kind: AgentEventKind,
        sessionID: String = "session-replay",
        cycle: Int = 1,
        stateVersion: UInt64 = 1,
        questionGeneration: UInt64 = 1
    ) -> StoredAgentEvent {
        StoredAgentEvent(
            sequence: sequence,
            event: AgentEvent(
                sessionID: sessionID,
                kind: kind,
                cycle: cycle,
                stateVersion: stateVersion,
                questionGeneration: questionGeneration,
                detail: kind.rawValue.lowercased()
            )
        )
    }
}
