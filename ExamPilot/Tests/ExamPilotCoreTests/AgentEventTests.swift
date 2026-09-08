import XCTest
@testable import ExamPilotCore

final class AgentEventTests: XCTestCase {
    func testPolicyDenialEventContainsSessionAndRuntimeCoordinatesWithoutSecrets() throws {
        let event = AgentEvent(
            sessionID: "session-policy-1",
            kind: .policyDenied,
            cycle: 2,
            stateVersion: 7,
            questionGeneration: 2,
            detail: "protected_boundary_before_answer"
        )

        let data = try JSONEncoder().encode(event)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(event.sessionID, "session-policy-1")
        XCTAssertTrue(text.contains("session-policy-1"))
        XCTAssertTrue(text.contains("policyDenied"))
        XCTAssertTrue(text.contains("protected_boundary_before_answer"))
        XCTAssertFalse(text.lowercased().contains("authorization"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
        XCTAssertFalse(text.contains("private-answer-42"))
    }

    func testRecoveryEventsUseBoundedIdentifiersOnly() throws {
        let planned = AgentEvent(
            sessionID: "session-recovery-1",
            kind: .recoveryPlanned,
            cycle: 3,
            stateVersion: 9,
            questionGeneration: 2,
            detail: "reobserve_and_replan"
        )
        let exhausted = AgentEvent(
            sessionID: "session-recovery-1",
            kind: .recoveryExhausted,
            cycle: 4,
            stateVersion: 10,
            questionGeneration: 2,
            detail: "repeated_intent_loop"
        )

        let encoded = try JSONEncoder().encode([planned, exhausted])
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertTrue(text.contains("session-recovery-1"))
        XCTAssertTrue(text.contains("recoveryPlanned"))
        XCTAssertTrue(text.contains("recoveryExhausted"))
        XCTAssertTrue(text.contains("reobserve_and_replan"))
        XCTAssertTrue(text.contains("repeated_intent_loop"))
        XCTAssertFalse(text.lowercased().contains("authorization"))
        XCTAssertFalse(text.lowercased().contains("api_key"))
        XCTAssertFalse(text.contains("private-answer-42"))
    }

    func testLegacyInitializerGetsDeterministicUnscopedSessionID() {
        let event = AgentEvent(
            kind: .observationAccepted,
            cycle: 1,
            stateVersion: 1,
            questionGeneration: 1,
            detail: "observation_accepted"
        )

        XCTAssertEqual(event.sessionID, "unscoped")
    }
}
