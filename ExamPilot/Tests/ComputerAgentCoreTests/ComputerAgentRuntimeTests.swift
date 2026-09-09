import XCTest
@testable import ComputerAgentCore

final class ComputerAgentRuntimeTests: XCTestCase {
    func testRuntimePreservesExplicitCycleAccountingAndCompletion() async {
        let probe = RuntimeProbe()
        let runtime = ComputerAgentRuntime<String>(
            maxCycles: 5,
            shouldStop: { false },
            step: { context in
                await probe.recordStep()
                context.advanceCycle()
                if context.cycles == 2 {
                    return .complete("finished:\(context.cycles)")
                }
                return .continueRunning
            },
            stoppedResult: { "stopped:\($0)" },
            maxCyclesResult: { "max:\($0)" },
            failureResult: { cycles, _ in "failed:\(cycles)" }
        )

        let result = await runtime.run()

        XCTAssertEqual(result, "finished:2")
        XCTAssertEqual(await probe.stepCount, 2)
    }

    func testRuntimeStopsBeforeExecutingNextStep() async {
        let probe = RuntimeProbe()
        let runtime = ComputerAgentRuntime<String>(
            maxCycles: 5,
            shouldStop: { true },
            step: { _ in
                await probe.recordStep()
                return .continueRunning
            },
            stoppedResult: { "stopped:\($0)" },
            maxCyclesResult: { "max:\($0)" },
            failureResult: { cycles, _ in "failed:\(cycles)" }
        )

        let result = await runtime.run()

        XCTAssertEqual(result, "stopped:0")
        XCTAssertEqual(await probe.stepCount, 0)
    }

    func testRuntimeReportsFailureAtCurrentCycle() async {
        let runtime = ComputerAgentRuntime<String>(
            maxCycles: 5,
            shouldStop: { false },
            step: { context in
                context.advanceCycle()
                throw RuntimeTestError.expected
            },
            stoppedResult: { "stopped:\($0)" },
            maxCyclesResult: { "max:\($0)" },
            failureResult: { cycles, _ in "failed:\(cycles)" }
        )

        let result = await runtime.run()

        XCTAssertEqual(result, "failed:1")
    }
}

private actor RuntimeProbe {
    private(set) var stepCount = 0

    func recordStep() {
        stepCount += 1
    }
}

private enum RuntimeTestError: Error {
    case expected
}
