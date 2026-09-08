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
}
