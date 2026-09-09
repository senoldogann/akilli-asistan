import XCTest
@testable import ComputerAgentMacOS

final class FocusValidatorTests: XCTestCase {
    func testRejectsCurrentFocusIdentityMismatch() {
        let expected = ComputerWindowIdentity(processID: 10, windowID: 100)
        let current = ComputerObservationSource(processID: 10, windowID: 101)

        let result = FocusValidator().validate(
            expected: expected,
            current: current
        )

        XCTAssertEqual(result, .reobserve(.focusMismatch))
    }
}
