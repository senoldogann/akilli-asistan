import XCTest
@testable import ZeroLose

@MainActor
final class AgentLifecycleTests: XCTestCase {
    private func makeSession(_ lifecycle: AgentLifecycle) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: AgentSessionID(rawValue: "a1"),
            goalID: GoalID(rawValue: "g1"),
            lifecycle: lifecycle,
            verificationEvidenceID: nil
        )
    }

    func testAllowedExecutionPathAdvancesThroughVerification() throws {
        var state = makeSession(.created)
        let path: [AgentLifecycle] = [
            .planning,
            .ready,
            .executing,
            .observing,
            .verifying
        ]

        for lifecycle in path {
            try state.transition(to: lifecycle, verificationEvidenceID: nil)
            XCTAssertEqual(state.lifecycle, lifecycle)
        }
    }

    func testVerifierRejectionCanReturnToPlanning() throws {
        var state = makeSession(.verifying)

        try state.transition(to: .planning, verificationEvidenceID: nil)

        XCTAssertEqual(state.lifecycle, .planning)
        XCTAssertNil(state.verificationEvidenceID)
    }

    func testCompletionRequiresVerificationEvidence() throws {
        var state = makeSession(.verifying)

        XCTAssertThrowsError(
            try state.transition(to: .completed, verificationEvidenceID: nil)
        ) { error in
            XCTAssertEqual(error as? AgentLifecycleError, .completionRequiresEvidence)
        }
        XCTAssertEqual(state.lifecycle, .verifying)

        try state.transition(to: .completed, verificationEvidenceID: "evidence-1")
        XCTAssertEqual(state.lifecycle, .completed)
        XCTAssertEqual(state.verificationEvidenceID, "evidence-1")
    }

    func testTerminalStatesRejectFurtherTransitions() throws {
        let terminalStates: [AgentLifecycle] = [
            .cancelled,
            .blocked,
            .failed,
            .manualResolutionRequired
        ]

        for terminal in terminalStates {
            var state: AgentSessionSnapshot
            switch terminal {
            case .cancelled, .blocked, .failed:
                state = makeSession(.planning)
            case .manualResolutionRequired:
                state = makeSession(.executing)
            default:
                XCTFail("Unexpected non-terminal fixture")
                continue
            }

            try state.transition(to: terminal, verificationEvidenceID: nil)
            XCTAssertEqual(state.lifecycle, terminal)
            XCTAssertThrowsError(
                try state.transition(to: .planning, verificationEvidenceID: nil)
            ) { error in
                XCTAssertEqual(
                    error as? AgentLifecycleError,
                    .invalidTransition(from: terminal, to: .planning)
                )
            }
        }
    }

    func testInvalidLifecycleSkipFailsClosedWithoutMutation() {
        var state = makeSession(.created)

        XCTAssertThrowsError(
            try state.transition(to: .executing, verificationEvidenceID: nil)
        ) { error in
            XCTAssertEqual(
                error as? AgentLifecycleError,
                .invalidTransition(from: .created, to: .executing)
            )
        }
        XCTAssertEqual(state.lifecycle, .created)
        XCTAssertNil(state.verificationEvidenceID)
    }
}
