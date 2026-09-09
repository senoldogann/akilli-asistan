import XCTest
@testable import ZeroLose

final class RuntimeIDsTests: XCTestCase {
    func testGoalIDHasValueSemantics() {
        XCTAssertEqual(GoalID(rawValue: "g1"), GoalID(rawValue: "g1"))
    }
}
