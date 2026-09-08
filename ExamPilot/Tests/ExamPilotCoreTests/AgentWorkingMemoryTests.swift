import XCTest
@testable import ExamPilotCore

final class AgentWorkingMemoryTests: XCTestCase {
    func testActionHistoryIsBoundedFIFO() {
        let memory = AgentWorkingMemory(maxActions: 2, maxFailures: 2, maxEvidence: 2)

        memory.recordAction(makeIntent(x: 8), sequence: 1, stateVersion: 10, questionGeneration: 1)
        memory.recordAction(makeIntent(x: 16), sequence: 2, stateVersion: 11, questionGeneration: 1)
        memory.recordAction(makeIntent(x: 24), sequence: 3, stateVersion: 12, questionGeneration: 1)

        XCTAssertEqual(memory.snapshot().actions.map(\.sequence), [2, 3])
        XCTAssertEqual(memory.snapshot().actions.map(\.stateVersion), [11, 12])
    }

    func testFailureAndEvidencePreserveStructuredRuntimeCoordinates() {
        let memory = AgentWorkingMemory(maxActions: 2, maxFailures: 2, maxEvidence: 2)

        memory.recordFailure(
            .noVisibleEffect,
            recoveryStrategy: .reobserveAndReplan,
            sequence: 4,
            stateVersion: 20,
            questionGeneration: 3
        )
        memory.recordEvidence(
            .answerMutation,
            sequence: 5,
            stateVersion: 21,
            questionGeneration: 3
        )

        let snapshot = memory.snapshot()
        XCTAssertEqual(snapshot.failures.first?.reason, .noVisibleEffect)
        XCTAssertEqual(snapshot.failures.first?.recoveryStrategy, .reobserveAndReplan)
        XCTAssertEqual(snapshot.failures.first?.stateVersion, 20)
        XCTAssertEqual(snapshot.failures.first?.questionGeneration, 3)
        XCTAssertEqual(snapshot.evidence.first?.outcome, .answerMutation)
        XCTAssertEqual(snapshot.evidence.first?.stateVersion, 21)
        XCTAssertEqual(snapshot.evidence.first?.questionGeneration, 3)
    }

    func testCurrentRecoveryStrategyCanBeSetAndCleared() {
        let memory = AgentWorkingMemory()

        memory.setCurrentRecoveryStrategy(.waitForStability)
        XCTAssertEqual(memory.snapshot().currentRecoveryStrategy, .waitForStability)

        memory.setCurrentRecoveryStrategy(nil)
        XCTAssertNil(memory.snapshot().currentRecoveryStrategy)
    }

    func testSnapshotDoesNotRetainRawTypedTextOrModelSummary() {
        let privateAnswer = "private-answer-42"
        let privateSummary = "secret-model-summary"
        let decision = ExamDecision(
            summary: privateSummary,
            expectsVisualChange: true,
            actions: [.typeText(privateAnswer)]
        )
        let intent = AgentIntentFingerprint(decision: decision, questionGeneration: 1)
        let memory = AgentWorkingMemory()

        memory.recordAction(intent, sequence: 1, stateVersion: 1, questionGeneration: 1)

        let text = String(describing: memory.snapshot())
        XCTAssertFalse(text.contains(privateAnswer))
        XCTAssertFalse(text.contains(privateSummary))
    }

    func testSnapshotIsStableValueAfterMemoryMutates() {
        let memory = AgentWorkingMemory()
        memory.recordAction(makeIntent(x: 8), sequence: 1, stateVersion: 1, questionGeneration: 1)
        let before = memory.snapshot()

        memory.recordAction(makeIntent(x: 16), sequence: 2, stateVersion: 2, questionGeneration: 1)

        XCTAssertEqual(before.actions.map(\.sequence), [1])
        XCTAssertEqual(memory.snapshot().actions.map(\.sequence), [1, 2])
    }

    private func makeIntent(x: Double) -> AgentIntentFingerprint {
        AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "ignored",
                expectsVisualChange: true,
                actions: [.moveClick(x: x, y: 40)]
            ),
            questionGeneration: 1,
            coordinateBucketSize: 8
        )
    }
}
