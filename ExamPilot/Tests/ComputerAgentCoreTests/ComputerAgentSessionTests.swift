import XCTest
@testable import ComputerAgentCore

final class ComputerAgentSessionTests: XCTestCase {
    func testProposalMustMatchCurrentObservationAndStateVersion() {
        var session = ComputerAgentSession(
            sessionID: "s1",
            goalID: "g1",
            taskID: "t1",
            goal: "Fill form",
            profileID: "generic"
        )

        let first = session.acceptObservation(id: "o1")
        let second = session.acceptObservation(id: "o2")

        XCTAssertFalse(
            session.isCurrent(
                observationID: first.observationID,
                stateVersion: first.stateVersion
            )
        )
        XCTAssertTrue(
            session.isCurrent(
                observationID: second.observationID,
                stateVersion: second.stateVersion
            )
        )
    }
}
