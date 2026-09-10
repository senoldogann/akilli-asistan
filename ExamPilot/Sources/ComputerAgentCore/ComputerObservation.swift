import CoreGraphics

public struct ComputerWindowIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32

    public init(processID: Int32, windowID: UInt32) {
        self.processID = processID
        self.windowID = windowID
    }
}

public struct ComputerObservation: Codable, Equatable, Sendable {
    public let observationID: String
    public let stateVersion: UInt64
    public let windowIdentity: ComputerWindowIdentity?
    public let provenance: [String]
    public let tainted: Bool
    public let confidence: Double
    public let appName: String?
    public let windowTitle: String?
    public let bounds: CGRect?

    public init(
        observationID: String,
        stateVersion: UInt64,
        windowIdentity: ComputerWindowIdentity? = nil,
        provenance: [String] = [],
        tainted: Bool = false,
        confidence: Double = 1.0,
        appName: String? = nil,
        windowTitle: String? = nil,
        bounds: CGRect? = nil
    ) {
        self.observationID = observationID
        self.stateVersion = stateVersion
        self.windowIdentity = windowIdentity
        self.provenance = provenance
        self.tainted = tainted
        self.confidence = confidence
        self.appName = appName
        self.windowTitle = windowTitle
        self.bounds = bounds
    }
}
