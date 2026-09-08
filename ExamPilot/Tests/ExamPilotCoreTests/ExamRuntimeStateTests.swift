import XCTest
@testable import ExamPilotCore

final class ExamRuntimeStateTests: XCTestCase {
    func testNavigationIsDeniedUntilAnswerIsVerified() {
        var state = ExamRuntimeState()
        XCTAssertFalse(state.navigationAllowed)

        state.recordAnswerVerified()

        XCTAssertTrue(state.navigationAllowed)
    }

    func testBoundaryCompletionStartsFreshUnansweredQuestion() {
        var state = ExamRuntimeState()
        state.recordAnswerVerified()
        let previousQuestion = state.questionGeneration

        state.beginBoundaryTransition()
        XCTAssertEqual(state.uiPhase, .transitioning)
        XCTAssertFalse(state.navigationAllowed)

        state.completeBoundaryTransition()

        XCTAssertEqual(state.questionGeneration, previousQuestion + 1)
        XCTAssertEqual(state.answerState, .unanswered)
        XCTAssertEqual(state.uiPhase, .stable)
        XCTAssertFalse(state.navigationAllowed)
    }

    func testAcceptedObservationsAdvanceStateVersionMonotonically() {
        var state = ExamRuntimeState()
        let initial = state.stateVersion

        state.acceptObservation()
        let first = state.stateVersion
        state.acceptObservation()

        XCTAssertGreaterThan(first, initial)
        XCTAssertGreaterThan(state.stateVersion, first)
    }
}
