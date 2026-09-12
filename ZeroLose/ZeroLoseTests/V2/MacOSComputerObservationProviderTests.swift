import ComputerAgentMacOS
import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class MacOSComputerObservationProviderTests: XCTestCase {
    func testMatchingIdentityReturnsFreshMonotonicMutationStateAndPresentationMetadata() async throws {
        let sourceProvider = SequencedObservationSourceProvider(
            results: [
                .success(sources(processID: 101, windowID: 11)),
                .success(sources(processID: 202, windowID: 22)),
            ]
        )
        let provider = MacOSComputerObservationProvider(
            sourceProvider: sourceProvider,
            observationIDGenerator: { version in "obs-\(version)" }
        )

        let first = try await provider.currentComputerMutationState()
        let firstMetadata = await provider.latestPresentationMetadata()
        let second = try await provider.currentComputerMutationState()
        let secondMetadata = await provider.latestPresentationMetadata()

        XCTAssertEqual(first, ComputerMutationState(stateVersion: 1, observationID: "obs-1"))
        XCTAssertEqual(firstMetadata?.processID, 101)
        XCTAssertEqual(firstMetadata?.windowID, 11)
        XCTAssertEqual(second, ComputerMutationState(stateVersion: 2, observationID: "obs-2"))
        XCTAssertEqual(secondMetadata?.processID, 202)
        XCTAssertEqual(secondMetadata?.windowID, 22)
        XCTAssertNotEqual(first.observationID, second.observationID)
        XCTAssertGreaterThan(second.stateVersion, first.stateVersion)
        let readCount = await sourceProvider.readCount
        XCTAssertEqual(readCount, 2)
    }

    func testMissingIdentityFailsClosedWithoutFabricatingState() async {
        let provider = MacOSComputerObservationProvider(
            sourceProvider: SequencedObservationSourceProvider(
                results: [
                    .success(
                        MacOSComputerObservationSources(
                            screen: source(processID: nil, windowID: nil, provenance: "screen"),
                            accessibility: source(processID: 101, windowID: 11, provenance: "ax")
                        )
                    ),
                ]
            ),
            observationIDGenerator: { version in "obs-\(version)" }
        )

        await assertProviderError(.reobserve(.missingIdentity), provider: provider)
        let metadata = await provider.latestPresentationMetadata()
        XCTAssertNil(metadata)
    }

    func testMismatchedIdentityFailsClosedWithoutFabricatingState() async {
        let provider = MacOSComputerObservationProvider(
            sourceProvider: SequencedObservationSourceProvider(
                results: [
                    .success(
                        MacOSComputerObservationSources(
                            screen: source(processID: 101, windowID: 11, provenance: "screen"),
                            accessibility: source(processID: 101, windowID: 12, provenance: "ax")
                        )
                    ),
                ]
            ),
            observationIDGenerator: { version in "obs-\(version)" }
        )

        await assertProviderError(.reobserve(.identityMismatch), provider: provider)
        let metadata = await provider.latestPresentationMetadata()
        XCTAssertNil(metadata)
    }

    func testSourceUnavailableReturnsExplicitUnavailableAndNoState() async {
        let provider = MacOSComputerObservationProvider(
            sourceProvider: SequencedObservationSourceProvider(
                results: [.failure(TestObservationSourceError.permissionDenied)]
            ),
            observationIDGenerator: { version in "obs-\(version)" }
        )

        await assertProviderError(.unavailable, provider: provider)
        let metadata = await provider.latestPresentationMetadata()
        XCTAssertNil(metadata)
    }

    func testFailedReobserveAfterAcceptedObservationNeverReturnsPriorStateAsCurrent() async throws {
        let sourceProvider = SequencedObservationSourceProvider(
            results: [
                .success(sources(processID: 101, windowID: 11)),
                .success(
                    MacOSComputerObservationSources(
                        screen: source(processID: 202, windowID: 22, provenance: "screen"),
                        accessibility: source(processID: 202, windowID: 23, provenance: "ax")
                    )
                ),
            ]
        )
        let provider = MacOSComputerObservationProvider(
            sourceProvider: sourceProvider,
            observationIDGenerator: { version in "obs-\(version)" }
        )

        let accepted = try await provider.currentComputerMutationState()
        XCTAssertEqual(accepted.stateVersion, 1)

        await assertProviderError(.reobserve(.identityMismatch), provider: provider)

        let metadata = await provider.latestPresentationMetadata()
        XCTAssertNil(
            metadata,
            "After a failed fresh re-observation, prior accepted state must not remain current"
        )
    }

    private func sources(
        processID: Int32,
        windowID: UInt32
    ) -> MacOSComputerObservationSources {
        MacOSComputerObservationSources(
            screen: source(processID: processID, windowID: windowID, provenance: "screen"),
            accessibility: source(processID: processID, windowID: windowID, provenance: "ax")
        )
    }

    private func source(
        processID: Int32?,
        windowID: UInt32?,
        provenance: String
    ) -> ComputerObservationSource {
        ComputerObservationSource(
            processID: processID,
            windowID: windowID,
            provenance: provenance,
            tainted: false,
            confidence: 1.0
        )
    }

    private func assertProviderError(
        _ expected: MacOSComputerObservationProviderError,
        provider: MacOSComputerObservationProvider
    ) async {
        do {
            _ = try await provider.currentComputerMutationState()
            XCTFail("Expected provider error: \(expected)")
        } catch let error as MacOSComputerObservationProviderError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor SequencedObservationSourceProvider: MacOSComputerObservationSourceProviding {
    private var results: [Result<MacOSComputerObservationSources, Error>]
    private(set) var readCount = 0

    init(results: [Result<MacOSComputerObservationSources, Error>]) {
        self.results = results
    }

    func currentObservationSources() async throws -> MacOSComputerObservationSources {
        readCount += 1
        guard !results.isEmpty else {
            throw TestObservationSourceError.exhausted
        }
        return try results.removeFirst().get()
    }
}

private enum TestObservationSourceError: Error {
    case permissionDenied
    case exhausted
}
