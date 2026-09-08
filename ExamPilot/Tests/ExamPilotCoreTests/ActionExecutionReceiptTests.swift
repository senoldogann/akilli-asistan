import XCTest
@testable import ExamPilotCore

final class ActionExecutionReceiptTests: XCTestCase {
    func testReceiptCarriesPhysicalCompletionOnly() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 101)
        let receipt = ActionExecutionReceipt(
            actionIndex: 2,
            kind: .moveClick,
            stateVersion: 7,
            startedAt: start,
            completedAt: end,
            status: .completed
        )

        XCTAssertEqual(receipt.actionIndex, 2)
        XCTAssertEqual(receipt.kind, .moveClick)
        XCTAssertEqual(receipt.stateVersion, 7)
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertEqual(receipt.startedAt, start)
        XCTAssertEqual(receipt.completedAt, end)
    }
}
