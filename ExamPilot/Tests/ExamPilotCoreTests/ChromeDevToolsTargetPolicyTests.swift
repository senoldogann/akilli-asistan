import XCTest
@testable import ExamPilotCore

final class ChromeDevToolsTargetPolicyTests: XCTestCase {
    func testPageTargetCountIsBoundedFailClosed() {
        XCTAssertFalse(ChromeDevToolsBrowserSemanticObserver.acceptsPageTargetCount(0))
        XCTAssertTrue(ChromeDevToolsBrowserSemanticObserver.acceptsPageTargetCount(1))
        XCTAssertTrue(ChromeDevToolsBrowserSemanticObserver.acceptsPageTargetCount(32))
        XCTAssertFalse(ChromeDevToolsBrowserSemanticObserver.acceptsPageTargetCount(33))
        XCTAssertFalse(ChromeDevToolsBrowserSemanticObserver.acceptsPageTargetCount(Int.max))
    }
}
