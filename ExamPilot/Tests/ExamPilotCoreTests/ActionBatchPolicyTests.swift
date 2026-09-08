import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ActionBatchPolicyTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testTruncatesActionsAfterFirstBoundary() throws {
        let decision = ExamDecision(
            summary: "select answer then navigate",
            expectsVisualChange: true,
            actions: [
                .moveClick(x: 300, y: 300),
                .moveClick(x: 1200, y: 820, boundary: true),
                .moveClick(x: 400, y: 400),
            ]
        )

        let batch = try ActionBatchPolicy().validate(decision, screenBounds: bounds)

        XCTAssertEqual(batch.actions.count, 2)
        XCTAssertEqual(batch.actions.last?.boundary, true)
    }

    func testBoundaryForcesVisualVerificationEvenIfModelSaysNoChange() throws {
        let decision = ExamDecision(
            summary: "navigate",
            expectsVisualChange: false,
            actions: [.moveClick(x: 1200, y: 820, boundary: true)]
        )

        let batch = try ActionBatchPolicy().validate(decision, screenBounds: bounds)

        XCTAssertTrue(batch.expectsVisualChange)
    }

    func testRejectsProtectedBoundaryAsFirstActionWhenQuestionIsUnanswered() {
        let decision = ExamDecision(
            summary: "skip current question",
            expectsVisualChange: true,
            actions: [.moveClick(x: 1200, y: 820, boundary: true)]
        )
        let context = ActionPolicyContext(stateVersion: 9, navigationAllowed: false)

        XCTAssertThrowsError(
            try ActionBatchPolicy().validate(decision, screenBounds: bounds, context: context)
        ) { error in
            XCTAssertEqual(error as? ActionValidationError, .protectedBoundaryBeforeAnswer)
        }
    }

    func testDefersBoundaryAfterAnswerActionsUntilAnswerVerification() throws {
        let decision = ExamDecision(
            summary: "answer then next",
            expectsVisualChange: true,
            actions: [
                .moveClick(x: 400, y: 400),
                .moveClick(x: 1200, y: 820, boundary: true),
            ]
        )
        let context = ActionPolicyContext(stateVersion: 11, navigationAllowed: false)

        let batch = try ActionBatchPolicy().validate(decision, screenBounds: bounds, context: context)

        XCTAssertEqual(batch.actions, [.moveClick(x: 400, y: 400)])
        XCTAssertTrue(batch.deferredProtectedBoundary)
        XCTAssertTrue(batch.expectsVisualChange)
        XCTAssertTrue(batch.hasPotentialAnswerMutation)
        XCTAssertEqual(batch.stateVersion, 11)
    }

    func testAllowsProtectedBoundaryAfterVerifiedAnswer() throws {
        let decision = ExamDecision(
            summary: "go next",
            expectsVisualChange: true,
            actions: [.moveClick(x: 1200, y: 820, boundary: true)]
        )
        let context = ActionPolicyContext(stateVersion: 12, navigationAllowed: true)

        let batch = try ActionBatchPolicy().validate(decision, screenBounds: bounds, context: context)

        XCTAssertTrue(batch.containsProtectedBoundary)
        XCTAssertFalse(batch.deferredProtectedBoundary)
        XCTAssertEqual(batch.stateVersion, 12)
    }

    func testProtectedBoundaryProducesNavigationExpectation() throws {
        let batch = try ActionBatchPolicy().validate(
            ExamDecision(
                summary: "next",
                expectsVisualChange: true,
                actions: [.moveClick(x: 50, y: 50, boundary: true)]
            ),
            screenBounds: bounds,
            context: ActionPolicyContext(stateVersion: 4, navigationAllowed: true)
        )

        XCTAssertEqual(batch.expectedOutcome, .navigation)
    }

    func testDeferredBoundaryProducesAnswerMutationExpectation() throws {
        let batch = try ActionBatchPolicy().validate(
            ExamDecision(
                summary: "answer then next",
                expectsVisualChange: true,
                actions: [
                    .moveClick(x: 20, y: 20),
                    .moveClick(x: 80, y: 80, boundary: true),
                ]
            ),
            screenBounds: bounds,
            context: ActionPolicyContext(stateVersion: 4, navigationAllowed: false)
        )

        XCTAssertTrue(batch.deferredProtectedBoundary)
        XCTAssertEqual(batch.expectedOutcome, .answerMutation)
    }

    func testScrollOnlyProducesViewportExpectation() throws {
        let batch = try ActionBatchPolicy().validate(
            ExamDecision(summary: "scroll", expectsVisualChange: true, actions: [.scroll(amount: -300)]),
            screenBounds: bounds,
            context: ActionPolicyContext(stateVersion: 4, navigationAllowed: false)
        )

        XCTAssertEqual(batch.expectedOutcome, .viewportChange)
    }

    func testWaitOnlyProducesNoSemanticExpectation() throws {
        let batch = try ActionBatchPolicy().validate(
            ExamDecision(summary: "wait", expectsVisualChange: false, actions: [.wait(milliseconds: 100)]),
            screenBounds: bounds,
            context: ActionPolicyContext(stateVersion: 4, navigationAllowed: false)
        )

        XCTAssertEqual(batch.expectedOutcome, .none)
    }

    func testFinishOnlyProducesNoSemanticExpectation() throws {
        let batch = try ActionBatchPolicy().validate(
            ExamDecision(summary: "finish", expectsVisualChange: false, actions: [.finish()]),
            screenBounds: bounds,
            context: ActionPolicyContext(stateVersion: 4, navigationAllowed: false)
        )

        XCTAssertEqual(batch.expectedOutcome, .none)
    }

    func testRejectsMoreThanTwelveActions() {
        let decision = ExamDecision(
            summary: "too many",
            expectsVisualChange: true,
            actions: (0..<13).map { _ in .wait(milliseconds: 10) }
        )

        XCTAssertThrowsError(try ActionBatchPolicy().validate(decision, screenBounds: bounds)) { error in
            XCTAssertEqual(error as? ActionValidationError, .tooManyActions)
        }
    }

    func testRejectsWaitLongerThanFiveSeconds() {
        let decision = ExamDecision(summary: "wait", expectsVisualChange: false, actions: [.wait(milliseconds: 5001)])
        XCTAssertThrowsError(try ActionBatchPolicy().validate(decision, screenBounds: bounds)) { error in
            XCTAssertEqual(error as? ActionValidationError, .waitOutOfRange)
        }
    }

    func testRejectsScrollBeyondLimit() {
        let decision = ExamDecision(summary: "scroll", expectsVisualChange: true, actions: [.scroll(amount: 1401)])
        XCTAssertThrowsError(try ActionBatchPolicy().validate(decision, screenBounds: bounds)) { error in
            XCTAssertEqual(error as? ActionValidationError, .scrollOutOfRange)
        }
    }

    func testRejectsIntMinScrollWithoutOverflow() {
        let decision = ExamDecision(summary: "malformed scroll", expectsVisualChange: true, actions: [.scroll(amount: Int.min)])
        XCTAssertThrowsError(try ActionBatchPolicy().validate(decision, screenBounds: bounds)) { error in
            XCTAssertEqual(error as? ActionValidationError, .scrollOutOfRange)
        }
    }

    func testRejectsUnsupportedKeyDuringValidation() {
        let decision = ExamDecision(summary: "bad key", expectsVisualChange: true, actions: [.pressKey("cmd+enter")])
        XCTAssertThrowsError(try ActionBatchPolicy().validate(decision, screenBounds: bounds))
    }

    func testRejectsClickOutsideScreenBounds() {
        let decision = ExamDecision(summary: "click", expectsVisualChange: true, actions: [.moveClick(x: 1500, y: 300)])
        XCTAssertThrowsError(try ActionBatchPolicy().validate(decision, screenBounds: bounds)) { error in
            XCTAssertEqual(error as? ActionValidationError, .coordinateOutOfBounds)
        }
    }
}
