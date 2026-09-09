public final class ComputerAgentRuntime<Result> {
    public final class Context {
        public private(set) var cycles: Int

        public init(cycles: Int = 0) {
            self.cycles = cycles
        }

        public func advanceCycle() {
            cycles += 1
        }
    }

    public enum StepResult {
        case continueRunning
        case complete(Result)
    }

    private let maxCycles: Int
    private let shouldStop: () -> Bool
    private let step: (Context) async throws -> StepResult
    private let stoppedResult: (Int) -> Result
    private let maxCyclesResult: (Int) -> Result
    private let failureResult: (Int, Error) -> Result

    public init(
        maxCycles: Int,
        shouldStop: @escaping () -> Bool,
        step: @escaping (Context) async throws -> StepResult,
        stoppedResult: @escaping (Int) -> Result,
        maxCyclesResult: @escaping (Int) -> Result,
        failureResult: @escaping (Int, Error) -> Result
    ) {
        self.maxCycles = max(0, maxCycles)
        self.shouldStop = shouldStop
        self.step = step
        self.stoppedResult = stoppedResult
        self.maxCyclesResult = maxCyclesResult
        self.failureResult = failureResult
    }

    public func run() async -> Result {
        let context = Context()

        while context.cycles < maxCycles {
            if shouldStop() {
                return stoppedResult(context.cycles)
            }

            do {
                switch try await step(context) {
                case .continueRunning:
                    continue
                case let .complete(result):
                    return result
                }
            } catch {
                return failureResult(context.cycles, error)
            }
        }

        return maxCyclesResult(context.cycles)
    }
}
