import XCTest
@testable import ExamPilotCore

final class ComputerAgentProviderTests: XCTestCase {
    func testProviderStateCarriesSessionRuntimeMemoryAndContinuationMetadata() throws {
        let state = ComputerAgentProviderState(
            sessionID: "session-5",
            goal: "Complete authorized task",
            stateVersion: 9,
            questionGeneration: 4,
            answerVerified: true,
            uiPhase: .stable,
            workingMemory: AgentWorkingMemorySnapshot(),
            previousResponseID: "resp_previous",
            pendingComputerCallID: "call_previous"
        )

        XCTAssertEqual(state.sessionID, "session-5")
        XCTAssertEqual(state.stateVersion, 9)
        XCTAssertEqual(state.questionGeneration, 4)
        XCTAssertTrue(state.answerVerified)
        XCTAssertEqual(state.previousResponseID, "resp_previous")
        XCTAssertEqual(state.pendingComputerCallID, "call_previous")
    }

    func testNativeComputerActionRoundTripsWithoutSecrets() throws {
        let actions = [
            NativeComputerAction(kind: .click, x: 410, y: 220, button: "left"),
            NativeComputerAction(kind: .type, text: "bounded text"),
            NativeComputerAction(kind: .scroll, x: 600, y: 500, scrollX: 0, scrollY: 420),
            NativeComputerAction(kind: .keypress, keys: ["TAB", "ENTER"]),
            NativeComputerAction(kind: .wait),
            NativeComputerAction(kind: .screenshot)
        ]
        let turn = ComputerAgentProviderTurn(
            responseID: "resp_123",
            computerCallID: "call_123",
            actions: actions,
            finalText: nil
        )

        let data = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(ComputerAgentProviderTurn.self, from: data)
        let text = String(decoding: data, as: UTF8.self).lowercased()

        XCTAssertEqual(decoded, turn)
        XCTAssertFalse(text.contains("authorization"))
        XCTAssertFalse(text.contains("api_key"))
        XCTAssertFalse(text.contains("bearer "))
    }

    func testProviderTurnCanRepresentTerminalHandoffWithoutComputerCall() {
        let turn = ComputerAgentProviderTurn(
            responseID: "resp_done",
            computerCallID: nil,
            actions: [],
            finalText: "Task complete"
        )

        XCTAssertTrue(turn.isTerminal)
        XCTAssertEqual(turn.finalText, "Task complete")
    }
}
