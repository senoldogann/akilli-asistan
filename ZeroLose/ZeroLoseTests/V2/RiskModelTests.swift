import XCTest
@testable import ZeroLose

final class RiskModelTests: XCTestCase {
    func testRiskScaleMatchesApprovedOrder() {
        XCTAssertLessThan(RiskLevel.readOnly.rawValue, RiskLevel.reversibleLocalMutation.rawValue)
        XCTAssertLessThan(RiskLevel.reversibleLocalMutation.rawValue, RiskLevel.externalCommunication.rawValue)
        XCTAssertLessThan(RiskLevel.externalCommunication.rawValue, RiskLevel.highImpactExternalMutation.rawValue)
        XCTAssertLessThan(RiskLevel.highImpactExternalMutation.rawValue, RiskLevel.irreversible.rawValue)
    }
}
