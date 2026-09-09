public struct ComputerObservation: Codable, Equatable, Sendable {
    public let observationID: String
    public let stateVersion: UInt64

    public init(observationID: String, stateVersion: UInt64) {
        self.observationID = observationID
        self.stateVersion = stateVersion
    }
}
