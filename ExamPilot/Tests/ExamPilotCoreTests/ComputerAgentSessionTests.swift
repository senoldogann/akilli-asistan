import XCTest
@testable import ExamPilotCore

final class ComputerAgentSessionTests: XCTestCase {
    func testExplicitSessionIdentityAndGoalRemainStable() {
        let session = ComputerAgentSession(
            id: "session-123",
            goal: "Complete the authorized task",
            taskProfile: .exam
        )

        XCTAssertEqual(session.id, "session-123")
        XCTAssertEqual(session.goal, "Complete the authorized task")
        XCTAssertEqual(session.taskProfile, .exam)
    }

    func testDefaultSessionIdentityIsNonEmptyAndStable() {
        let session = ComputerAgentSession(goal: "Run")
        let first = session.id

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(session.id, first)
    }

    func testRuntimeTransitionsAreOwnedBySession() {
        let session = ComputerAgentSession(
            id: "runtime-session",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(
                stateVersion: 5,
                questionGeneration: 2,
                answerState: .unanswered,
                uiPhase: .stable
            )
        )

        session.acceptObservation()
        XCTAssertEqual(session.runtimeState.stateVersion, 6)

        session.recordAnswerVerified()
        XCTAssertTrue(session.runtimeState.navigationAllowed)

        session.beginBoundaryTransition()
        XCTAssertEqual(session.runtimeState.uiPhase, .transitioning)

        session.completeBoundaryTransition()
        XCTAssertEqual(session.runtimeState.questionGeneration, 3)
        XCTAssertEqual(session.runtimeState.answerState, .unanswered)
        XCTAssertEqual(session.runtimeState.uiPhase, .stable)
    }

    func testWorkingMemorySurvivesRuntimeTransitions() {
        let memory = AgentWorkingMemory()
        memory.recordEvidence(
            .answerMutation,
            sequence: 1,
            stateVersion: 1,
            questionGeneration: 1
        )
        let session = ComputerAgentSession(
            id: "memory-session",
            goal: "Run",
            workingMemory: memory
        )

        session.acceptObservation()
        session.recordAnswerVerified()

        XCTAssertEqual(session.workingMemory.snapshot().evidence.count, 1)
        XCTAssertEqual(session.workingMemory.snapshot().evidence.first?.outcome, .answerMutation)
    }

    func testProviderConversationStateCanUpdateAndClearWithoutChangingRuntimeState() {
        let session = ComputerAgentSession(
            id: "provider-session",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(stateVersion: 9)
        )

        session.updatePreviousResponseID("resp_123")
        XCTAssertEqual(session.providerConversationState.previousResponseID, "resp_123")
        XCTAssertEqual(session.runtimeState.stateVersion, 9)

        session.updatePreviousResponseID(nil)
        XCTAssertNil(session.providerConversationState.previousResponseID)
        XCTAssertEqual(session.runtimeState.stateVersion, 9)
    }

    func testStopStateMovesForwardOnly() {
        let session = ComputerAgentSession(id: "stop-session", goal: "Run")
        XCTAssertEqual(session.stopState, .running)

        session.requestStop()
        XCTAssertEqual(session.stopState, .stopRequested)

        session.markStopped()
        XCTAssertEqual(session.stopState, .stopped)

        session.requestStop()
        XCTAssertEqual(session.stopState, .stopped)
    }

    func testFailureAndEvidenceHelpersUseCurrentRuntimeCoordinatesAndMonotonicSequence() {
        let session = ComputerAgentSession(
            id: "memory-helper-session",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(
                stateVersion: 10,
                questionGeneration: 4
            )
        )

        session.recordFailure(.noVisibleEffect, recoveryStrategy: .reobserveAndReplan)
        session.recordEvidence(.viewportChange)

        let snapshot = session.workingMemory.snapshot()
        XCTAssertEqual(snapshot.failures.first?.sequence, 1)
        XCTAssertEqual(snapshot.failures.first?.stateVersion, 10)
        XCTAssertEqual(snapshot.failures.first?.questionGeneration, 4)
        XCTAssertEqual(snapshot.evidence.first?.sequence, 2)
        XCTAssertEqual(snapshot.evidence.first?.stateVersion, 10)
        XCTAssertEqual(snapshot.evidence.first?.questionGeneration, 4)
    }
}
