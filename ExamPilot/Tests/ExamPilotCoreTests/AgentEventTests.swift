import XCTest
@testable import ExamPilotCore

final class AgentEventTests: XCTestCase {
    func testPolicyDenialEventContainsRuntimeCoordinatesWithoutSecrets() throws {
        let event = AgentEvent(
            kind: .policyDenied,
            cycle: 2,
            stateVersion: 7,
            questionGeneration: 2,
            detail: "protected_boundary_before_answer"
        )

        let data = try JSONEncoder().encode(event)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("policyDenied"))
        XCTAssertTrue(text.contains("protected_boundary_before_answer"))
        XCTAssertFalse(text.lowercased().contains("authorization"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
    }
}
