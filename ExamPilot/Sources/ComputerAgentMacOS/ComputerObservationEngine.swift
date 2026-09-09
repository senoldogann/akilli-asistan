import ComputerAgentCore

public enum ComputerObservationEngineResult: Equatable, Sendable {
    case observation(ComputerObservation)
    case reobserve(ObservationReobserveReason)
}

public struct ComputerObservationEngine: Sendable {
    private let fusion: ObservationFusion

    public init(fusion: ObservationFusion = ObservationFusion()) {
        self.fusion = fusion
    }

    public func makeObservation(
        observationID: String,
        stateVersion: UInt64,
        screen: ComputerObservationSource,
        accessibility: ComputerObservationSource,
        supportingSources: [ComputerObservationSource] = []
    ) -> ComputerObservationEngineResult {
        let identity: ComputerWindowIdentity

        switch fusion.fuse(screen: screen, accessibility: accessibility) {
        case let .fused(fusedIdentity):
            identity = fusedIdentity
        case let .reobserve(reason):
            return .reobserve(reason)
        }

        for source in supportingSources {
            switch (source.processID, source.windowID) {
            case (nil, nil):
                continue
            case (.some, nil), (nil, .some):
                return .reobserve(.missingIdentity)
            case let (.some(processID), .some(windowID)):
                guard processID == identity.processID,
                      windowID == identity.windowID else {
                    return .reobserve(.identityMismatch)
                }
            }
        }

        let allSources = [screen, accessibility] + supportingSources
        let provenance = allSources
            .map(\.provenance)
            .filter { !$0.isEmpty }
        let tainted = allSources.contains { $0.tainted }
        let confidence = allSources.map(\.confidence).min() ?? 1.0

        return .observation(
            ComputerObservation(
                observationID: observationID,
                stateVersion: stateVersion,
                windowIdentity: identity,
                provenance: provenance,
                tainted: tainted,
                confidence: confidence
            )
        )
    }
}
