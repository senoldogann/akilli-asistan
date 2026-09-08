import CoreGraphics

public enum ExpectedOutcomeKind: String, Codable, Equatable {
    case none
    case answerMutation
    case viewportChange
    case navigation
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

public protocol OutcomeVerifying {
    func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult
}

public struct OutcomeVerifier: OutcomeVerifying {
    private let progressDetector: VisualChangeDetector
    private let structuralDetector: VisualChangeDetector

    public init(
        progressDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.035),
        structuralDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.08)
    ) {
        self.progressDetector = progressDetector
        self.structuralDetector = structuralDetector
    }

    public func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult {
        let score = progressDetector.score(before: before, after: after)

        switch expected {
        case .none:
            return .success(.none)
        case .answerMutation:
            guard progressDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.noVisibleEffect)
            }
            guard !structuralDetector.hasMeaningfulChange(before: before, after: after) else {
                return .pending(.unexpectedStructuralChange)
            }
            return .success(.answerMutation(score: score))
        case .viewportChange:
            guard progressDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.noVisibleEffect)
            }
            return .success(.viewportChange(score: score))
        case .navigation:
            guard uiStable else {
                return .pending(.uiTransitioning)
            }
            guard structuralDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.navigationIdentityUnchanged)
            }
            return .success(.navigation(score: score))
        }
    }
}
