import Foundation

public struct ActionExecutionResult: Equatable {
    public let executedCount: Int
    public let finished: Bool
    public let cancelled: Bool
    public let interruptedForUIChange: Bool
    public let receipts: [ActionExecutionReceipt]

    public init(
        executedCount: Int,
        finished: Bool,
        cancelled: Bool,
        interruptedForUIChange: Bool = false,
        receipts: [ActionExecutionReceipt] = []
    ) {
        self.executedCount = executedCount
        self.finished = finished
        self.cancelled = cancelled
        self.interruptedForUIChange = interruptedForUIChange
        self.receipts = receipts
    }
}

public final class ActionBatchExecutor {
    private let driver: InputDriving
    private let now: () -> Date

    public init(driver: InputDriving, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.now = now
    }

    public func execute(
        _ batch: ValidatedBatch,
        dryRun: Bool,
        shouldStop: () -> Bool = { false },
        afterAction: (_ action: ExamAction, _ hasRemainingActions: Bool) async throws -> Bool = { _, _ in true }
    ) async throws -> ActionExecutionResult {
        if dryRun {
            return ActionExecutionResult(executedCount: 0, finished: false, cancelled: false)
        }

        var executed = 0
        var receipts: [ActionExecutionReceipt] = []
        receipts.reserveCapacity(batch.actions.count)

        for (index, action) in batch.actions.enumerated() {
            if shouldStop() {
                return ActionExecutionResult(
                    executedCount: executed,
                    finished: false,
                    cancelled: true,
                    receipts: receipts
                )
            }

            if action.kind == .finish {
                return ActionExecutionResult(
                    executedCount: executed,
                    finished: true,
                    cancelled: false,
                    receipts: receipts
                )
            }

            let startedAt = now()
            do {
                try await executePhysical(action)
            } catch InputDriverError.cancelled {
                return ActionExecutionResult(
                    executedCount: executed,
                    finished: false,
                    cancelled: true,
                    receipts: receipts
                )
            }

            let completedAt = now()
            receipts.append(
                ActionExecutionReceipt(
                    actionIndex: index,
                    kind: action.kind,
                    stateVersion: batch.stateVersion,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    status: .completed
                )
            )
            executed += 1

            let hasRemainingActions = index < batch.actions.count - 1
            if hasRemainingActions {
                let shouldContinue = try await afterAction(action, true)
                if !shouldContinue {
                    return ActionExecutionResult(
                        executedCount: executed,
                        finished: false,
                        cancelled: false,
                        interruptedForUIChange: true,
                        receipts: receipts
                    )
                }
            }
        }

        return ActionExecutionResult(
            executedCount: executed,
            finished: false,
            cancelled: false,
            receipts: receipts
        )
    }

    private func executePhysical(_ action: ExamAction) async throws {
        switch action.kind {
        case .moveClick:
            try await driver.moveAndClick(x: action.x!, y: action.y!)
        case .typeText:
            try await driver.typeText(action.text!)
        case .key:
            try await driver.pressKey(action.key!)
        case .scroll:
            try await driver.scroll(amount: action.amount!)
        case .wait:
            try await driver.wait(milliseconds: action.milliseconds!)
        case .finish:
            break
        }
    }
}
