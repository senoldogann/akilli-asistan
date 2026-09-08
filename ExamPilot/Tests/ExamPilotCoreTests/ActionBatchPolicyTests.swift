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
