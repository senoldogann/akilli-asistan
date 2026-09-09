import XCTest
@testable import ComputerAgentCore

final class ComputerAgentSafetyPolicyTests: XCTestCase {
    func testRejectsStaleObservationWithoutTaskProfileKnowledge() {
        let proposal = ComputerSafetyProposal(stateVersion: 1, observationID: "o1")
        let context = ComputerSafetyContext(
            currentStateVersion: 2,
            currentObservationID: "o2"
        )

        XCTAssertEqual(
            ComputerAgentSafetyPolicy().validate(proposal, context: context),
            .denied(.staleObservation)
        )
    }

    func testRejectsFocusMismatch() {
        let proposal = ComputerSafetyProposal(stateVersion: 2, observationID: "o2")
        let context = ComputerSafetyContext(
            currentStateVersion: 2,
            currentObservationID: "o2",
            focusMatches: false
        )

        XCTAssertEqual(
            ComputerAgentSafetyPolicy().validate(proposal, context: context),
            .denied(.focusMismatch)
        )
    }

    func testRejectsCancellation() {
        let proposal = ComputerSafetyProposal(stateVersion: 2, observationID: "o2")
        let context = ComputerSafetyContext(
            currentStateVersion: 2,
            currentObservationID: "o2",
            cancellationRequested: true
        )

        XCTAssertEqual(
            ComputerAgentSafetyPolicy().validate(proposal, context: context),
            .denied(.cancelled)
        )
    }

    func testRejectsOutOfBoundsPointerAction() {
        let bounds = ComputerSafetyBounds(minX: 0, minY: 0, width: 100, height: 100)

        XCTAssertEqual(
            ComputerAgentSafetyPolicy().validate(
                .moveClick(x: 101, y: 50),
                bounds: bounds
            ),
            .denied(.coordinateOutOfBounds)
        )
    }
}
