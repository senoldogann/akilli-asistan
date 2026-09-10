import Foundation

struct RuntimeBudgetLimits: Sendable, Equatable {
    let maxWallClockSeconds: TimeInterval
    let maxModelCalls: Int
    let maxToolCalls: Int
    let maxRecoveryAttempts: Int
    let maxExternalSpend: Decimal
    let maxParallelTasks: Int
    let deadline: Date?

    init(
        maxWallClockSeconds: TimeInterval,
        maxModelCalls: Int,
        maxToolCalls: Int,
        maxRecoveryAttempts: Int,
        maxExternalSpend: Decimal,
        maxParallelTasks: Int,
        deadline: Date?
    ) {
        self.maxWallClockSeconds = max(0, maxWallClockSeconds)
        self.maxModelCalls = max(0, maxModelCalls)
        self.maxToolCalls = max(0, maxToolCalls)
        self.maxRecoveryAttempts = max(0, maxRecoveryAttempts)
        self.maxExternalSpend = max(0, maxExternalSpend)
        self.maxParallelTasks = max(0, maxParallelTasks)
        self.deadline = deadline
    }
}

enum RuntimeBudgetError: Error, Equatable {
    case wallClockLimitExceeded
    case deadlineExceeded
    case modelCallLimitExceeded
    case toolCallLimitExceeded
    case recoveryAttemptLimitExceeded
    case externalSpendLimitExceeded
    case parallelTaskLimitExceeded
    case duplicateRecoveryStrategy
    case invalidExternalSpend
}

actor RuntimeBudget {
    private let limits: RuntimeBudgetLimits
    private let startedAt: Date

    private var modelCalls = 0
    private var toolCalls = 0
    private var recoveryAttempts = 0
    private var externalSpend: Decimal = 0
    private var activeParallelTasks = 0
    private var recoveryStrategiesByFailure: [String: Set<String>] = [:]

    init(limits: RuntimeBudgetLimits, startedAt: Date = Date()) {
        self.limits = limits
        self.startedAt = startedAt
    }

    func reserveModelCall(now: Date = Date()) throws {
        try validateTime(now: now)
        guard modelCalls < limits.maxModelCalls else {
            throw RuntimeBudgetError.modelCallLimitExceeded
        }
        modelCalls += 1
    }

    func reserveToolCall(now: Date = Date()) throws {
        try validateTime(now: now)
        guard toolCalls < limits.maxToolCalls else {
            throw RuntimeBudgetError.toolCallLimitExceeded
        }
        toolCalls += 1
    }

    func reserveRecoveryAttempt(
        failureFingerprint: String,
        strategyID: String,
        now: Date = Date()
    ) throws {
        try validateTime(now: now)

        let attemptedStrategies = recoveryStrategiesByFailure[failureFingerprint, default: []]
        guard !attemptedStrategies.contains(strategyID) else {
            throw RuntimeBudgetError.duplicateRecoveryStrategy
        }
        guard recoveryAttempts < limits.maxRecoveryAttempts else {
            throw RuntimeBudgetError.recoveryAttemptLimitExceeded
        }

        recoveryAttempts += 1
        recoveryStrategiesByFailure[failureFingerprint, default: []].insert(strategyID)
    }

    func reserveExternalSpend(_ amount: Decimal, now: Date = Date()) throws {
        try validateTime(now: now)
        guard amount >= 0 else {
            throw RuntimeBudgetError.invalidExternalSpend
        }

        let nextSpend = externalSpend + amount
        guard nextSpend <= limits.maxExternalSpend else {
            throw RuntimeBudgetError.externalSpendLimitExceeded
        }
        externalSpend = nextSpend
    }

    func beginParallelWork(now: Date = Date()) throws {
        try validateTime(now: now)
        guard activeParallelTasks < limits.maxParallelTasks else {
            throw RuntimeBudgetError.parallelTaskLimitExceeded
        }
        activeParallelTasks += 1
    }

    func endParallelWork() {
        if activeParallelTasks > 0 {
            activeParallelTasks -= 1
        }
    }

    func snapshot(now: Date = Date()) throws -> RuntimeBudgetSnapshot {
        try validateTime(now: now)

        let remainingSpend = limits.maxExternalSpend - externalSpend
        return RuntimeBudgetSnapshot(
            remainingModelCalls: max(0, limits.maxModelCalls - modelCalls),
            remainingToolCalls: max(0, limits.maxToolCalls - toolCalls),
            remainingRecoveryAttempts: max(0, limits.maxRecoveryAttempts - recoveryAttempts),
            remainingExternalSpend: max(0, remainingSpend),
            deadline: limits.deadline
        )
    }

    private func validateTime(now: Date) throws {
        if let deadline = limits.deadline, now > deadline {
            throw RuntimeBudgetError.deadlineExceeded
        }
        if now.timeIntervalSince(startedAt) > limits.maxWallClockSeconds {
            throw RuntimeBudgetError.wallClockLimitExceeded
        }
    }
}
