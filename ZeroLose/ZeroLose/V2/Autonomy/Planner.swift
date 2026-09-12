import Foundation

struct GoalSnapshot: Sendable, Equatable {
    let id: GoalID
    let objective: String
}

struct RuntimeBudgetSnapshot: Codable, Sendable, Equatable {
    let remainingModelCalls: Int
    let remainingToolCalls: Int
    let remainingRecoveryAttempts: Int
    let remainingExternalSpend: Decimal
    let deadline: Date?
}

struct PlanningContext: Sendable, Equatable {
    let retrievedContext: ContextBundle
    let registry: ToolRegistrySnapshot
}

enum PlanningError: Error, Sendable, Equatable {
    case invalidProposal
}

protocol Planning: Sendable {
    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) async throws -> PlanningProposal
}
