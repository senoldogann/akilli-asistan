public struct ActionExecutionResult: Equatable {
    public let executedCount: Int
    public let finished: Bool
    public let cancelled: Bool

    public init(executedCount: Int, finished: Bool, cancelled: Bool) {
        self.executedCount = executedCount
        self.finished = finished
        self.cancelled = cancelled
    }
}

public final class ActionBatchExecutor {
    private let driver: InputDriving

    public init(driver: InputDriving) {
        self.driver = driver
    }

    public func execute(
        _ batch: ValidatedBatch,
        dryRun: Bool,
        shouldStop: () -> Bool = { false }
    ) async throws -> ActionExecutionResult {
        if dryRun {
            return ActionExecutionResult(executedCount: 0, finished: false, cancelled: false)
        }

        var executed = 0
        for action in batch.actions {
            if shouldStop() {
                return ActionExecutionResult(executedCount: executed, finished: false, cancelled: true)
            }

            if action.kind == .finish {
                return ActionExecutionResult(executedCount: executed, finished: true, cancelled: false)
            }

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
            executed += 1
        }

        return ActionExecutionResult(executedCount: executed, finished: false, cancelled: false)
    }
}
