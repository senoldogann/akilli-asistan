import XCTest
@testable import ExamPilotCore

final class RuntimeDiagnosticsTests: XCTestCase {
    func testFailureReasonsExposeStableDiagnosticIdentifiers() {
        XCTAssertEqual(AgentFailureReason.noVisibleEffect.diagnosticID, "no_visible_effect")
        XCTAssertEqual(AgentFailureReason.transitionStillRunning.diagnosticID, "transition_still_running")
        XCTAssertEqual(AgentFailureReason.stateMismatch.diagnosticID, "state_mismatch")
        XCTAssertEqual(AgentFailureReason.invalidModelPlan.diagnosticID, "invalid_model_plan")
        XCTAssertEqual(AgentFailureReason.repeatedIntentLoop.diagnosticID, "repeated_intent_loop")
    }

    func testFormatterProducesCompactRuntimeLine() {
        let event = AgentEvent(
            sessionID: "session-private-value",
            kind: .verificationFailed,
            cycle: 13,
            stateVersion: 27,
            questionGeneration: 7,
            detail: "no_visible_effect"
        )

        let line = AgentEventDiagnosticFormatter().format(event)

        XCTAssertEqual(line, "[cycle 13] q=7 state=27 verificationFailed no_visible_effect")
        XCTAssertFalse(line.contains("session-private-value"))
    }

    func testFormatterRedactsUnboundedDetailContent() {
        let event = AgentEvent(
            sessionID: "session-1",
            kind: .verificationFailed,
            cycle: 4,
            stateVersion: 9,
            questionGeneration: 2,
            detail: "sk-sensitive raw answer text"
        )

        let line = AgentEventDiagnosticFormatter().format(event)

        XCTAssertEqual(line, "[cycle 4] q=2 state=9 verificationFailed redacted_detail")
        XCTAssertFalse(line.contains("sk-sensitive"))
        XCTAssertFalse(line.contains("raw answer"))
    }

    func testDiagnosticSinkWritesFormattedLine() {
        var lines: [String] = []
        let sink = DiagnosticAgentEventSink(writeLine: { lines.append($0) })

        sink.record(
            AgentEvent(
                kind: .recoveryPlanned,
                cycle: 8,
                stateVersion: 16,
                questionGeneration: 4,
                detail: "reobserve_and_replan"
            )
        )

        XCTAssertEqual(lines, ["[cycle 8] q=4 state=16 recoveryPlanned reobserve_and_replan"])
    }
}
