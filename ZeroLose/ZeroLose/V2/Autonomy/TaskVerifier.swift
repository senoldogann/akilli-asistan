import Foundation

enum TaskVerificationResult: Sendable, Equatable {
    case verified(VerificationEvidence)
    case rejected(reason: String)
}

protocol TaskVerifying: Sendable {
    func verify(
        task: TaskNode,
        evidence: [VerificationEvidence]
    ) async -> TaskVerificationResult
}
