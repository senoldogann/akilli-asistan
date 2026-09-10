import XCTest
@testable import ExamPilotCore

final class ExamTaskProfileTests: XCTestCase {
    func testRejectsNavigationUntilAnswerVerified() {
        XCTAssertFalse(ExamTaskProfile(state: ExamRuntimeState()).navigationAllowed)
    }

    func testAllowsNavigationAfterAnswerVerified() {
        var state = ExamRuntimeState()
        state.recordAnswerVerified()

        XCTAssertTrue(ExamTaskProfile(state: state).navigationAllowed)
    }

    func testRejectsNavigationWhileTransitioning() {
        var state = ExamRuntimeState()
        state.recordAnswerVerified()
        state.beginBoundaryTransition()

        XCTAssertFalse(ExamTaskProfile(state: state).navigationAllowed)
    }
}
