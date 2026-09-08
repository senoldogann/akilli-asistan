import CoreGraphics

public enum ExpectedOutcomeKind: Codable, Equatable {
    case none
    case answerMutation
    case answerMutationAt(normalizedX: Double, normalizedY: Double)
    case viewportChange
    case navigation

    fileprivate var normalizedInteractionPoint: CGPoint? {
        guard case .answerMutationAt(let normalizedX, let normalizedY) = self else {
            return nil
        }
        return CGPoint(x: normalizedX, y: normalizedY)
    }
}

public enum OutcomeEvidence: Equatable {
    case none
    case answerMutation(score: Double)
    case viewportChange(score: Double)
    case navigation(score: Double)
}

public enum OutcomePendingReason: String, Equatable {
    case uiTransitioning
    case unexpectedStructuralChange
}

public enum OutcomeFailureReason: String, Equatable {
    case noVisibleEffect
    case navigationIdentityUnchanged
}

public enum OutcomeVerificationResult: Equatable {
    case success(OutcomeEvidence)
    case pending(OutcomePendingReason)
    case failure(OutcomeFailureReason)
}

public struct OutcomeVerificationContext: Equatable {
    public let normalizedInteractionPoint: CGPoint?

    public init(normalizedInteractionPoint: CGPoint? = nil) {
        self.normalizedInteractionPoint = normalizedInteractionPoint
    }

    public static let none = OutcomeVerificationContext()
}

public protocol OutcomeVerifying {
    func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult
}

public protocol ContextualOutcomeVerifying: OutcomeVerifying {
    func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool,
        context: OutcomeVerificationContext
    ) -> OutcomeVerificationResult
}

public struct OutcomeVerifier: OutcomeVerifying, ContextualOutcomeVerifying {
    private let progressDetector: VisualChangeDetector
    private let structuralDetector: VisualChangeDetector
    private let localizedDetector: VisualChangeDetector
    private let localizedRadiusFraction: CGFloat

    public init(
        progressDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.035),
        structuralDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.08),
        localizedDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.012),
        localizedRadiusFraction: CGFloat = 0.045
    ) {
        self.progressDetector = progressDetector
        self.structuralDetector = structuralDetector
        self.localizedDetector = localizedDetector
        self.localizedRadiusFraction = max(0.01, min(0.25, localizedRadiusFraction))
    }

    public func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult {
        verify(
            expected: expected,
            before: before,
            after: after,
            uiStable: uiStable,
            context: .none
        )
    }

    public func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool,
        context: OutcomeVerificationContext
    ) -> OutcomeVerificationResult {
        let globalScore = progressDetector.score(before: before, after: after)

        switch expected {
        case .none:
            return .success(.none)

        case .answerMutation, .answerMutationAt:
            let globalChanged = progressDetector.hasMeaningfulChange(before: before, after: after)
            let interactionPoint = context.normalizedInteractionPoint ?? expected.normalizedInteractionPoint
            let localizedScore = interactionPoint.flatMap { point in
                scoreLocalizedChange(before: before, after: after, around: point)
            }
            let localizedChanged = localizedScore.map { $0 >= localizedDetector.threshold } ?? false

            guard globalChanged || localizedChanged else {
                return .failure(.noVisibleEffect)
            }
            guard !structuralDetector.hasMeaningfulChange(before: before, after: after) else {
                return .pending(.unexpectedStructuralChange)
            }
            return .success(.answerMutation(score: max(globalScore, localizedScore ?? 0)))

        case .viewportChange:
            guard progressDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.noVisibleEffect)
            }
            return .success(.viewportChange(score: globalScore))

        case .navigation:
            guard uiStable else {
                return .pending(.uiTransitioning)
            }
            guard structuralDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.navigationIdentityUnchanged)
            }
            return .success(.navigation(score: globalScore))
        }
    }

    private func scoreLocalizedChange(
        before: CGImage,
        after: CGImage,
        around point: CGPoint
    ) -> Double? {
        guard point.x.isFinite,
              point.y.isFinite,
              (0...1).contains(point.x),
              (0...1).contains(point.y) else {
            return nil
        }

        let width = min(before.width, after.width)
        let height = min(before.height, after.height)
        guard width > 0, height > 0 else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let minimumDimension = CGFloat(min(width, height))
        let radius = max(24, minimumDimension * localizedRadiusFraction)
        let center = CGPoint(
            x: point.x * CGFloat(width),
            y: point.y * CGFloat(height)
        )
        let cropRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        .intersection(imageBounds)
        .integral

        guard !cropRect.isNull,
              cropRect.width >= 2,
              cropRect.height >= 2,
              let beforeCrop = before.cropping(to: cropRect),
              let afterCrop = after.cropping(to: cropRect) else {
            return nil
        }

        return localizedDetector.score(before: beforeCrop, after: afterCrop)
    }
}
