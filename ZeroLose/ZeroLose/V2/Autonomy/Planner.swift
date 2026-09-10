import Foundation

struct GoalSnapshot: Sendable, Equatable {
    let id: GoalID
    let objective: String
}

struct RuntimeBudgetSnapshot: Sendable, Equatable {
    let remainingModelCalls: Int
    let remainingToolCalls: Int
    let remainingRecoveryAttempts: Int
    let remainingExternalSpend: Decimal
    let deadline: Date?
}

protocol Planning: Sendable {
    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot
    ) async throws -> PlanningProposal
}
