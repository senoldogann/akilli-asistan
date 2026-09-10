import Foundation

struct GoalVerificationResult: Sendable, Equatable {
    let completed: Bool
    let evidence: VerificationEvidence?
}

protocol GoalVerifying: Sendable {
    func verify(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot
    ) async throws -> GoalVerificationResult
}
