import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class CoreGraphicsServicesBootstrapTests: XCTestCase {
    func testInitializeIsIdempotentAndReturnsTheMainDisplay() async {
        let first = await CoreGraphicsServicesBootstrap.initialize()
        let second = await CoreGraphicsServicesBootstrap.initialize()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, CGMainDisplayID())
    }
}
