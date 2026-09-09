public enum FocusValidationResult: Equatable, Sendable {
    case valid
    case reobserve(ObservationReobserveReason)
}

public struct FocusValidator: Sendable {
    public init() {}

    public func validate(
        expected: ComputerWindowIdentity,
        current: ComputerObservationSource
    ) -> FocusValidationResult {
        guard let currentProcessID = current.processID,
              let currentWindowID = current.windowID else {
            return .reobserve(.missingIdentity)
        }

        guard currentProcessID == expected.processID,
              currentWindowID == expected.windowID else {
            return .reobserve(.focusMismatch)
        }

        return .valid
    }
}
