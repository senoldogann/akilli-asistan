import ComputerAgentCore
import ComputerAgentMacOS
import Foundation

struct MacOSComputerObservationSources: Sendable, Equatable {
    let screen: ComputerObservationSource
    let accessibility: ComputerObservationSource
    let supportingSources: [ComputerObservationSource]

    init(
        screen: ComputerObservationSource,
        accessibility: ComputerObservationSource,
        supportingSources: [ComputerObservationSource] = []
    ) {
        self.screen = screen
        self.accessibility = accessibility
        self.supportingSources = supportingSources
    }
}

protocol MacOSComputerObservationSourceProviding: Sendable {
    func currentObservationSources() async throws -> MacOSComputerObservationSources
}

struct MacOSComputerObservationPresentationMetadata: Sendable, Equatable {
    let observationID: String
    let stateVersion: UInt64
    let processID: Int32
    let windowID: UInt32
    let provenance: [String]
    let tainted: Bool
    let confidence: Double
}

enum MacOSComputerObservationProviderError: Error, Sendable, Equatable {
    case unavailable
    case reobserve(ObservationReobserveReason)
    case invalidObservation
}

actor MacOSComputerObservationProvider: ComputerMutationStateProviding {
    private let sourceProvider: any MacOSComputerObservationSourceProviding
    private let engine: ComputerObservationEngine
    private let observationIDGenerator: @Sendable (UInt64) -> String

    private var acceptedStateVersion: UInt64 = 0
    private var presentationMetadata: MacOSComputerObservationPresentationMetadata?

    init(
        sourceProvider: any MacOSComputerObservationSourceProviding,
        engine: ComputerObservationEngine = ComputerObservationEngine(),
        observationIDGenerator: @escaping @Sendable (UInt64) -> String = { version in
            "macos-observation-\(version)-\(UUID().uuidString)"
        }
    ) {
        self.sourceProvider = sourceProvider
        self.engine = engine
        self.observationIDGenerator = observationIDGenerator
    }

    func currentComputerMutationState() async throws -> ComputerMutationState {
        presentationMetadata = nil

        let sources: MacOSComputerObservationSources
        do {
            sources = try await sourceProvider.currentObservationSources()
        } catch {
            throw MacOSComputerObservationProviderError.unavailable
        }

        let nextVersion = acceptedStateVersion + 1
        let observationID = observationIDGenerator(nextVersion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observationID.isEmpty else {
            throw MacOSComputerObservationProviderError.invalidObservation
        }

        switch engine.makeObservation(
            observationID: observationID,
            stateVersion: nextVersion,
            screen: sources.screen,
            accessibility: sources.accessibility,
            supportingSources: sources.supportingSources
        ) {
        case .reobserve(let reason):
            throw MacOSComputerObservationProviderError.reobserve(reason)

        case .observation(let observation):
            guard observation.observationID == observationID,
                  observation.stateVersion == nextVersion,
                  let identity = observation.windowIdentity else {
                throw MacOSComputerObservationProviderError.invalidObservation
            }

            acceptedStateVersion = nextVersion
            presentationMetadata = MacOSComputerObservationPresentationMetadata(
                observationID: observation.observationID,
                stateVersion: observation.stateVersion,
                processID: identity.processID,
                windowID: identity.windowID,
                provenance: observation.provenance,
                tainted: observation.tainted,
                confidence: observation.confidence
            )

            return ComputerMutationState(
                stateVersion: observation.stateVersion,
                observationID: observation.observationID
            )
        }
    }

    func latestPresentationMetadata() -> MacOSComputerObservationPresentationMetadata? {
        presentationMetadata
    }
}
