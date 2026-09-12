import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class ComputerInvocationFreshnessBinderTests: XCTestCase {
    func testBinderInjectsRuntimeFreshness() throws {
        let bound = try ComputerInvocationFreshnessBinder().bind(
            argumentsJSON: Data(#"{"amount":400}"#.utf8),
            state: ComputerMutationState(stateVersion: 7, observationID: "obs-7")
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bound) as? [String: Any]
        )
        XCTAssertEqual(object["amount"] as? Int, 400)
        XCTAssertEqual(object["stateVersion"] as? Int, 7)
        XCTAssertEqual(object["observationID"] as? String, "obs-7")
        XCTAssertEqual(object.count, 3)
    }

    func testBinderRejectsPlannerSuppliedStateVersion() throws {
        XCTAssertThrowsError(
            try ComputerInvocationFreshnessBinder().bind(
                argumentsJSON: Data(#"{"amount":400,"stateVersion":99}"#.utf8),
                state: ComputerMutationState(stateVersion: 7, observationID: "obs-7")
            )
        ) { error in
            XCTAssertEqual(
                error as? ComputerInvocationFreshnessBinderError,
                .reservedFreshnessField
            )
        }
    }

    func testBinderRejectsPlannerSuppliedObservationID() throws {
        XCTAssertThrowsError(
            try ComputerInvocationFreshnessBinder().bind(
                argumentsJSON: Data(#"{"amount":400,"observationID":"model"}"#.utf8),
                state: ComputerMutationState(stateVersion: 7, observationID: "obs-7")
            )
        ) { error in
            XCTAssertEqual(
                error as? ComputerInvocationFreshnessBinderError,
                .reservedFreshnessField
            )
        }
    }

    func testBinderRejectsNonObjectArguments() throws {
        XCTAssertThrowsError(
            try ComputerInvocationFreshnessBinder().bind(
                argumentsJSON: Data("[]".utf8),
                state: ComputerMutationState(stateVersion: 7, observationID: "obs-7")
            )
        ) { error in
            XCTAssertEqual(
                error as? ComputerInvocationFreshnessBinderError,
                .invalidArguments
            )
        }
    }
}
