public struct ComputerObservationSource: Equatable, Sendable {
    public let processID: Int32?
    public let windowID: UInt32?

    public init(processID: Int32?, windowID: UInt32?) {
        self.processID = processID
        self.windowID = windowID
    }
}

public struct ComputerWindowIdentity: Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32

    public init(processID: Int32, windowID: UInt32) {
        self.processID = processID
        self.windowID = windowID
    }
}

public enum ObservationReobserveReason: Equatable, Sendable {
    case missingIdentity
    case identityMismatch
    case focusMismatch
}

public enum ObservationFusionResult: Equatable, Sendable {
    case fused(ComputerWindowIdentity)
    case reobserve(ObservationReobserveReason)
}

public struct ObservationFusion: Sendable {
    public init() {}

    public func fuse(
        screen: ComputerObservationSource,
        accessibility: ComputerObservationSource
    ) -> ObservationFusionResult {
        guard let screenProcessID = screen.processID,
              let screenWindowID = screen.windowID,
              let accessibilityProcessID = accessibility.processID,
              let accessibilityWindowID = accessibility.windowID else {
            return .reobserve(.missingIdentity)
        }

        guard screenProcessID == accessibilityProcessID,
              screenWindowID == accessibilityWindowID else {
            return .reobserve(.identityMismatch)
        }

        return .fused(
            ComputerWindowIdentity(
                processID: screenProcessID,
                windowID: screenWindowID
            )
        )
    }
}
