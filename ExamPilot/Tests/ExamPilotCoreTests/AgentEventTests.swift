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

    func testRecoveryEventsUseBoundedIdentifiersOnly() throws {
        let planned = AgentEvent(
            kind: .recoveryPlanned,
            cycle: 3,
            stateVersion: 9,
            questionGeneration: 2,
            detail: "reobserve_and_replan"
        )
        let exhausted = AgentEvent(
            kind: .recoveryExhausted,
            cycle: 4,
            stateVersion: 10,
            questionGeneration: 2,
            detail: "repeated_intent_loop"
        )

        let encoded = try JSONEncoder().encode([planned, exhausted])
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertTrue(text.contains("recoveryPlanned"))
        XCTAssertTrue(text.contains("recoveryExhausted"))
        XCTAssertTrue(text.contains("reobserve_and_replan"))
        XCTAssertTrue(text.contains("repeated_intent_loop"))
        XCTAssertFalse(text.lowercased().contains("authorization"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
    }
}
