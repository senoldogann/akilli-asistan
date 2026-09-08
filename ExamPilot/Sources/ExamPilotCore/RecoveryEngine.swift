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
