import CoreGraphics

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
        guard decision.actions.count <= maxActions else {
            throw ActionValidationError.tooManyActions
        }

        var accepted: [ExamAction] = []
        accepted.reserveCapacity(decision.actions.count)

        for action in decision.actions {
            try validate(action, screenBounds: screenBounds)
            accepted.append(action)

            if action.boundary || action.kind == .finish {
                break
            }
        }

        return ValidatedBatch(
            summary: decision.summary,
            expectsVisualChange: decision.expectsVisualChange,
            actions: accepted
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

        case .scroll:
            guard let amount = action.amount else {
                throw ActionValidationError.missingRequiredField(.scroll)
            }
            guard abs(amount) <= maxAbsoluteScroll else {
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
