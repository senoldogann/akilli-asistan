import XCTest
@testable import ExamPilotCore

final class RecoveryEngineTests: XCTestCase {
    func testNearbyClickCoordinatesProduceSameIntentFingerprint() {
        let a = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "ignored",
                expectsVisualChange: true,
                actions: [.moveClick(x: 100, y: 200, boundary: true)]
            ),
            questionGeneration: 2,
            coordinateBucketSize: 8
        )
        let b = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "also ignored",
                expectsVisualChange: true,
                actions: [.moveClick(x: 103, y: 207, boundary: true)]
            ),
            questionGeneration: 2,
            coordinateBucketSize: 8
        )

        XCTAssertEqual(a, b)
    }

    func testDifferentQuestionGenerationProducesDifferentFingerprint() {
        let decision = ExamDecision(
            summary: "next",
            expectsVisualChange: true,
            actions: [.moveClick(x: 100, y: 200, boundary: true)]
        )

        XCTAssertNotEqual(
            AgentIntentFingerprint(decision: decision, questionGeneration: 2),
            AgentIntentFingerprint(decision: decision, questionGeneration: 3)
        )
    }

    func testFingerprintDoesNotRetainTypedTextOrSummary() {
        let fingerprint = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "secret summary",
                expectsVisualChange: true,
                actions: [.typeText("private-answer")]
            ),
            questionGeneration: 1
        )

        let text = String(describing: fingerprint)
        XCTAssertFalse(text.contains("secret summary"))
        XCTAssertFalse(text.contains("private-answer"))
    }

    func testSameIntentExhaustsOnThirdFailure() {
        let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
        let intent = makeIntent(x: 100, boundary: true)

        XCTAssertEqual(
            engine.handle(failure: .invalidModelPlan, intent: intent),
            .recover(strategy: .reobserveAndReplan, attempt: 1)
        )
        XCTAssertEqual(
            engine.handle(failure: .invalidModelPlan, intent: intent),
            .recover(strategy: .reobserveAndReplan, attempt: 2)
        )
        XCTAssertEqual(
            engine.handle(failure: .invalidModelPlan, intent: intent),
            .exhausted(reason: .repeatedIntentLoop)
        )
    }

    func testChangedIntentHasIndependentBudget() {
        let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
        let first = makeIntent(x: 100)
        let changed = makeIntent(x: 180)

        _ = engine.handle(failure: .noVisibleEffect, intent: first)
        _ = engine.handle(failure: .noVisibleEffect, intent: first)

        XCTAssertEqual(
            engine.handle(failure: .noVisibleEffect, intent: changed),
            .recover(strategy: .reobserveAndReplan, attempt: 1)
        )
    }

    func testTransitionFailureWaitsInsteadOfReplanning() {
        let engine = RecoveryEngine()
        XCTAssertEqual(
            engine.handle(failure: .transitionStillRunning, intent: makeIntent(x: 100, boundary: true)),
            .recover(strategy: .waitForStability, attempt: 1)
        )
    }

    func testSuccessClearsRepeatedIntentBudget() {
        let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
        let intent = makeIntent(x: 100)

        _ = engine.handle(failure: .noVisibleEffect, intent: intent)
        _ = engine.handle(failure: .noVisibleEffect, intent: intent)
        engine.recordSuccess(intent: intent)

        XCTAssertEqual(
            engine.handle(failure: .noVisibleEffect, intent: intent),
            .recover(strategy: .reobserveAndReplan, attempt: 1)
        )
    }

    private func makeIntent(x: Double, boundary: Bool = false) -> AgentIntentFingerprint {
        AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "ignored",
                expectsVisualChange: true,
                actions: [.moveClick(x: x, y: 100, boundary: boundary)]
            ),
            questionGeneration: 1
        )
    }
}
