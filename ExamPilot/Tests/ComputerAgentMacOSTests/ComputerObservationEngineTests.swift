import XCTest
@testable import ComputerAgentCore
@testable import ComputerAgentMacOS

final class ComputerObservationEngineTests: XCTestCase {
    func testEngineRejectsConflictingSupportingIdentity() {
        let engine = ComputerObservationEngine()

        let result = engine.makeObservation(
            observationID: "obs-1",
            stateVersion: 7,
            screen: ComputerObservationSource(
                processID: 10,
                windowID: 100,
                provenance: "screen",
                tainted: false,
                confidence: 0.98
            ),
            accessibility: ComputerObservationSource(
                processID: 10,
                windowID: 100,
                provenance: "accessibility",
                tainted: false,
                confidence: 0.99
            ),
            supportingSources: [
                ComputerObservationSource(
                    processID: 11,
                    windowID: 200,
                    provenance: "browser",
                    tainted: true,
                    confidence: 0.90
                )
            ]
        )

        XCTAssertEqual(result, .reobserve(.identityMismatch))
    }

    func testEnginePreservesIdentityProvenanceTaintAndConfidence() {
        let engine = ComputerObservationEngine()

        let result = engine.makeObservation(
            observationID: "obs-2",
            stateVersion: 8,
            screen: ComputerObservationSource(
                processID: 10,
                windowID: 100,
                provenance: "screen",
                tainted: false,
                confidence: 0.98
            ),
            accessibility: ComputerObservationSource(
                processID: 10,
                windowID: 100,
                provenance: "accessibility",
                tainted: false,
                confidence: 0.99
            ),
            supportingSources: [
                ComputerObservationSource(
                    processID: nil,
                    windowID: nil,
                    provenance: "vision-ocr",
                    tainted: true,
                    confidence: 0.82
                )
            ]
        )

        XCTAssertEqual(
            result,
            .observation(
                ComputerObservation(
                    observationID: "obs-2",
                    stateVersion: 8,
                    windowIdentity: ComputerWindowIdentity(processID: 10, windowID: 100),
                    provenance: ["screen", "accessibility", "vision-ocr"],
                    tainted: true,
                    confidence: 0.82
                )
            )
        )
    }

    func testEngineRejectsPartialSupportingIdentity() {
        let engine = ComputerObservationEngine()

        let result = engine.makeObservation(
            observationID: "obs-3",
            stateVersion: 9,
            screen: ComputerObservationSource(processID: 10, windowID: 100),
            accessibility: ComputerObservationSource(processID: 10, windowID: 100),
            supportingSources: [
                ComputerObservationSource(processID: 10, windowID: nil)
            ]
        )

        XCTAssertEqual(result, .reobserve(.missingIdentity))
    }
}
