import CoreGraphics

public struct ActionPolicyContext: Equatable {
    public let stateVersion: UInt64
    public let navigationAllowed: Bool

    public init(stateVersion: UInt64, navigationAllowed: Bool) {
        self.stateVersion = stateVersion
        self.navigationAllowed = navigationAllowed
    }
}

public struct ActionBatchPolicy {
    public let maxActions: Int
    public let maxWaitMilliseconds: Int
    public let maxAbsoluteScroll: Int

    public init(maxActions: Int = 12, maxWaitMilliseconds: Int = 5_000, maxAbsoluteScroll: Int = 1_400) {
        self.maxActions = maxActions
        self.maxWaitMilliseconds = maxWaitMilliseconds
        self.maxAbsoluteScroll = maxAbsoluteScroll
    }

    public func validate(_ decision: ExamDecision, screenBounds: CGRect) throws -> ValidatedBatch {
        try validate(
            decision,
            screenBounds: screenBounds,
            context: ActionPolicyContext(stateVersion: 0, navigationAllowed: true)
        )
    }

    public func validate(
        _ decision: ExamDecision,
        screenBounds: CGRect,
        context: ActionPolicyContext
    ) throws -> ValidatedBatch {
        guard decision.actions.count <= maxActions else {
            throw ActionValidationError.tooManyActions
        }

        var accepted: [ExamAction] = []
        accepted.reserveCapacity(decision.actions.count)
        var deferredProtectedBoundary = false

        for action in decision.actions {
            if action.boundary, action.kind != .finish, !context.navigationAllowed {
                guard !accepted.isEmpty else {
                    throw ActionValidationError.protectedBoundaryBeforeAnswer
                }
                deferredProtectedBoundary = true
                break
            }

            try validate(action, screenBounds: screenBounds)
            accepted.append(action)

            if action.boundary || action.kind == .finish {
                break
            }
        }

        let boundaryRequiresVerification = accepted.contains {
            $0.boundary && $0.kind != .finish
        }

        return ValidatedBatch(
            summary: decision.summary,
            expectsVisualChange: decision.expectsVisualChange || boundaryRequiresVerification || deferredProtectedBoundary,
            actions: accepted,
            stateVersion: context.stateVersion,
            deferredProtectedBoundary: deferredProtectedBoundary
        )
    }

    private func validate(_ action: ExamAction, screenBounds: CGRect) throws {
        switch action.kind {
        case .moveClick:
            guard let x = action.x, let y = action.y else {
                throw ActionValidationError.missingRequiredField(.moveClick)
            }
            guard screenBounds.contains(CGPoint(x: x, y: y)) else {
                throw ActionValidationError.coordinateOutOfBounds
            }

        case .typeText:
            guard action.text != nil else {
                throw ActionValidationError.missingRequiredField(.typeText)
            }

        case .key:
            guard let key = action.key, !key.isEmpty else {
                throw ActionValidationError.missingRequiredField(.key)
            }
            guard SupportedInputKey(rawValue: key.lowercased()) != nil else {
                throw ActionValidationError.unsupportedKey(key)
            }

        case .scroll:
            guard let amount = action.amount else {
                throw ActionValidationError.missingRequiredField(.scroll)
            }
            guard (-maxAbsoluteScroll...maxAbsoluteScroll).contains(amount) else {
                throw ActionValidationError.scrollOutOfRange
            }

        case .wait:
            guard let milliseconds = action.milliseconds else {
                throw ActionValidationError.missingRequiredField(.wait)
            }
            guard milliseconds >= 0, milliseconds <= maxWaitMilliseconds else {
                throw ActionValidationError.waitOutOfRange
            }

        case .finish:
            break
        }
    }
}
