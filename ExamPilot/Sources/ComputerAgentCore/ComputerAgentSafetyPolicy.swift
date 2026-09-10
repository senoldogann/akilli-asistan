public struct ComputerSafetyProposal: Equatable, Sendable {
    public let stateVersion: UInt64
    public let observationID: String

    public init(stateVersion: UInt64, observationID: String) {
        self.stateVersion = stateVersion
        self.observationID = observationID
    }
}

public struct ComputerSafetyContext: Equatable, Sendable {
    public let currentStateVersion: UInt64
    public let currentObservationID: String?
    public let focusMatches: Bool
    public let cancellationRequested: Bool

    public init(
        currentStateVersion: UInt64,
        currentObservationID: String?,
        focusMatches: Bool = true,
        cancellationRequested: Bool = false
    ) {
        self.currentStateVersion = currentStateVersion
        self.currentObservationID = currentObservationID
        self.focusMatches = focusMatches
        self.cancellationRequested = cancellationRequested
    }
}

public struct ComputerSafetyBounds: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

public enum ComputerSafetyAction: Equatable, Sendable {
    case moveClick(x: Double?, y: Double?)
    case typeText(String?)
    case key(String?)
    case scroll(amount: Int?)
    case wait(milliseconds: Int?)
    case finish
}

public enum ComputerSafetyDenialReason: Equatable, Sendable {
    case staleState
    case staleObservation
    case focusMismatch
    case cancelled
    case tooManyActions
    case invalidActionShape
    case coordinateOutOfBounds
    case waitOutOfRange
    case scrollOutOfRange
}

public enum ComputerSafetyDecision: Equatable, Sendable {
    case allowed
    case denied(ComputerSafetyDenialReason)
}

public struct ComputerAgentSafetyPolicy: Sendable {
    public init() {}

    public func validate(
        _ proposal: ComputerSafetyProposal,
        context: ComputerSafetyContext
    ) -> ComputerSafetyDecision {
        guard !context.cancellationRequested else {
            return .denied(.cancelled)
        }
        guard context.focusMatches else {
            return .denied(.focusMismatch)
        }
        guard proposal.observationID == context.currentObservationID else {
            return .denied(.staleObservation)
        }
        guard proposal.stateVersion == context.currentStateVersion else {
            return .denied(.staleState)
        }
        return .allowed
    }

    public func validate(
        actionCount: Int,
        profile: ComputerTaskProfile = ComputerTaskProfile()
    ) -> ComputerSafetyDecision {
        guard actionCount >= 0, profile.maxActions >= 0, actionCount <= profile.maxActions else {
            return .denied(.tooManyActions)
        }
        return .allowed
    }

    public func validate(
        _ action: ComputerSafetyAction,
        bounds: ComputerSafetyBounds?,
        profile: ComputerTaskProfile = ComputerTaskProfile()
    ) -> ComputerSafetyDecision {
        switch action {
        case .moveClick(let x, let y):
            guard let x, let y else {
                return .denied(.invalidActionShape)
            }
            guard contains(x: x, y: y, in: bounds) else {
                return .denied(.coordinateOutOfBounds)
            }
            return .allowed

        case .typeText(let text):
            return text == nil ? .denied(.invalidActionShape) : .allowed

        case .key(let key):
            guard let key, !key.isEmpty else {
                return .denied(.invalidActionShape)
            }
            return .allowed

        case .scroll(let amount):
            guard let amount else {
                return .denied(.invalidActionShape)
            }
            guard profile.maxAbsoluteScroll >= 0,
                  amount >= -profile.maxAbsoluteScroll,
                  amount <= profile.maxAbsoluteScroll else {
                return .denied(.scrollOutOfRange)
            }
            return .allowed

        case .wait(let milliseconds):
            guard let milliseconds else {
                return .denied(.invalidActionShape)
            }
            guard profile.maxWaitMilliseconds >= 0,
                  milliseconds >= 0,
                  milliseconds <= profile.maxWaitMilliseconds else {
                return .denied(.waitOutOfRange)
            }
            return .allowed

        case .finish:
            return .allowed
        }
    }

    private func contains(x: Double, y: Double, in bounds: ComputerSafetyBounds?) -> Bool {
        guard let bounds,
              x.isFinite,
              y.isFinite,
              bounds.minX.isFinite,
              bounds.minY.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return false
        }

        let maxX = bounds.minX + bounds.width
        let maxY = bounds.minY + bounds.height
        guard maxX.isFinite, maxY.isFinite else {
            return false
        }

        return x >= bounds.minX && x < maxX && y >= bounds.minY && y < maxY
    }
}
