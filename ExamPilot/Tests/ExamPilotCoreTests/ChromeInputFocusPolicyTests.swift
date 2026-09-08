import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ChromeInputFocusPolicyTests: XCTestCase {
    func testAcceptsFocusedWindowThatMatchesCapturedGeometry() {
        let policy = ChromeInputFocusPolicy()
        let captured = CGRect(x: 120, y: 80, width: 1180, height: 760)
        let focused = CGRect(x: 122, y: 82, width: 1178, height: 758)

        XCTAssertTrue(policy.matchesCapturedWindow(captured: captured, focused: focused))
    }

    func testRejectsDifferentChromeWindowInSameProcess() {
        let policy = ChromeInputFocusPolicy()
        let captured = CGRect(x: 80, y: 60, width: 1050, height: 720)
        let differentWindow = CGRect(x: 480, y: 180, width: 820, height: 620)

        XCTAssertFalse(policy.matchesCapturedWindow(captured: captured, focused: differentWindow))
    }

    func testRejectsEmptyFocusedGeometry() {
        let policy = ChromeInputFocusPolicy()
        let captured = CGRect(x: 80, y: 60, width: 1050, height: 720)

        XCTAssertFalse(policy.matchesCapturedWindow(captured: captured, focused: .zero))
    }
}
