import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ChromeWindowSelectionTests: XCTestCase {
    func testFocusedWindowWinsEvenWhenAnotherChromeWindowIsLarger() {
        let policy = ChromeWindowSelectionPolicy()
        let largerBackground = ChromeWindowCandidate(
            windowID: 1,
            processID: 44,
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )
        let focusedExam = ChromeWindowCandidate(
            windowID: 2,
            processID: 44,
            frame: CGRect(x: 1600, y: 100, width: 800, height: 600)
        )

        let selected = policy.select(
            [largerBackground, focusedExam],
            focusedProcessID: 44,
            focusedFrame: focusedExam.frame
        )

        XCTAssertEqual(selected?.windowID, 2)
    }

    func testFallsBackToLargestVisibleChromeWindowWithoutFocusedFrame() {
        let policy = ChromeWindowSelectionPolicy()
        let smaller = ChromeWindowCandidate(
            windowID: 1,
            processID: 44,
            frame: CGRect(x: 20, y: 20, width: 800, height: 600)
        )
        let larger = ChromeWindowCandidate(
            windowID: 2,
            processID: 55,
            frame: CGRect(x: 900, y: 20, width: 1200, height: 800)
        )

        let selected = policy.select(
            [smaller, larger],
            focusedProcessID: nil,
            focusedFrame: nil
        )

        XCTAssertEqual(selected?.windowID, 2)
    }

    func testFocusedProcessLimitsSelectionBeforeFrameMatching() {
        let policy = ChromeWindowSelectionPolicy()
        let otherProcessExactFrame = ChromeWindowCandidate(
            windowID: 1,
            processID: 55,
            frame: CGRect(x: 100, y: 100, width: 900, height: 700)
        )
        let focusedProcessWindow = ChromeWindowCandidate(
            windowID: 2,
            processID: 44,
            frame: CGRect(x: 120, y: 120, width: 880, height: 680)
        )

        let selected = policy.select(
            [otherProcessExactFrame, focusedProcessWindow],
            focusedProcessID: 44,
            focusedFrame: otherProcessExactFrame.frame
        )

        XCTAssertEqual(selected?.windowID, 2)
    }
}
