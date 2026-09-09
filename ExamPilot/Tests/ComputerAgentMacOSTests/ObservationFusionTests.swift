import XCTest
@testable import ComputerAgentMacOS

final class ObservationFusionTests: XCTestCase {
    func testFusionRejectsMismatchedWindowIdentity() {
        let screen = ComputerObservationSource(
            processID: 10,
            windowID: 100
        )
        let accessibility = ComputerObservationSource(
            processID: 11,
            windowID: 200
        )

        let result = ObservationFusion().fuse(
            screen: screen,
            accessibility: accessibility
        )

        XCTAssertEqual(result, .reobserve(.identityMismatch))
    }
}
