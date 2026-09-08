import Foundation

public struct ActionIntentToken: Hashable, Codable {
    public let kind: String
    public let xBucket: Int?
    public let yBucket: Int?
    public let boundary: Bool

    public init(kind: String, xBucket: Int?, yBucket: Int?, boundary: Bool) {
        self.kind = kind
        self.xBucket = xBucket
        self.yBucket = yBucket
        self.boundary = boundary
    }
}

public struct AgentIntentFingerprint: Hashable, Codable {
    public let questionGeneration: UInt64
    public let actions: [ActionIntentToken]

    public init(
        decision: ExamDecision,
        questionGeneration: UInt64,
        coordinateBucketSize: Int = 8
    ) {
        let bucketSize = max(1, coordinateBucketSize)
        self.questionGeneration = questionGeneration
        self.actions = decision.actions.map { action in
            ActionIntentToken(
                kind: action.kind.rawValue,
                xBucket: Self.bucket(action.x, size: bucketSize),
                yBucket: Self.bucket(action.y, size: bucketSize),
                boundary: action.boundary
            )
        }
    }

    private static func bucket(_ value: Double?, size: Int) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int((value / Double(size)).rounded(.down))
    }
}

public enum AgentFailureReason: String, Codable, Equatable {
    case targetMiss
    case noVisibleEffect
    case staleObservation
    case transitionStillRunning
    case focusDrift
    case stateMismatch
    case invalidModelPlan
    case repeatedIntentLoop
    case targetNotVisible
    case unknown
}

public enum RecoveryStrategy: String, Codable, Equatable {
    case reobserveAndReplan
    case waitForStability
}

public enum RecoveryDecision: Equatable {
    case recover(strategy: RecoveryStrategy, attempt: Int)
    case exhausted(reason: AgentFailureReason)
}

public final class RecoveryEngine {
    private let maxRepeatedIntentAttempts: Int
    private var attempts: [AgentIntentFingerprint: Int] = [:]

    public init(maxRepeatedIntentAttempts: Int = 3) {
        self.maxRepeatedIntentAttempts = max(1, maxRepeatedIntentAttempts)
    }

    public func handle(
        failure: AgentFailureReason,
        intent: AgentIntentFingerprint
    ) -> RecoveryDecision {
        let current = attempts[intent] ?? 0
        let next = current == Int.max ? Int.max : current + 1
        attempts[intent] = next

        if next >= maxRepeatedIntentAttempts {
            return .exhausted(reason: .repeatedIntentLoop)
        }

        return .recover(strategy: strategy(for: failure), attempt: next)
    }

    public func recordSuccess(intent: AgentIntentFingerprint) {
        attempts.removeValue(forKey: intent)
    }

    private func strategy(for failure: AgentFailureReason) -> RecoveryStrategy {
        switch failure {
        case .transitionStillRunning:
            return .waitForStability
        case .targetMiss,
             .noVisibleEffect,
             .staleObservation,
             .focusDrift,
             .stateMismatch,
             .invalidModelPlan,
             .repeatedIntentLoop,
             .targetNotVisible,
             .unknown:
            return .reobserveAndReplan
        }
    }
}
