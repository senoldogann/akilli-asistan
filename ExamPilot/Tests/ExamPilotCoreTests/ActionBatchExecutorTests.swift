import XCTest
@testable import ExamPilotCore

final class ActionBatchExecutorTests: XCTestCase {
    func testExecutesActionsInOrder() async throws {
        let driver = RecordingInputDriver()
        let executor = ActionBatchExecutor(driver: driver)
        let batch = ValidatedBatch(
            summary: "do visible work",
            expectsVisualChange: true,
            actions: [
                .moveClick(x: 100, y: 200),
                .typeText("abc"),
                .scroll(amount: -300),
                .wait(milliseconds: 20),
            ]
        )

        let result = try await executor.execute(batch, dryRun: false, shouldStop: { false })

        XCTAssertEqual(driver.calls, ["click:100.0,200.0", "type:abc", "scroll:-300", "wait:20"])
        XCTAssertEqual(result.executedCount, 4)
        XCTAssertFalse(result.finished)
        XCTAssertFalse(result.cancelled)
    }

    func testDryRunNeverCallsInputDriver() async throws {
        let driver = RecordingInputDriver()
        let executor = ActionBatchExecutor(driver: driver)
        let batch = ValidatedBatch(summary: "dry", expectsVisualChange: true, actions: [.moveClick(x: 10, y: 20), .typeText("secret")])

        let result = try await executor.execute(batch, dryRun: true, shouldStop: { false })

        XCTAssertTrue(driver.calls.isEmpty)
        XCTAssertEqual(result.executedCount, 0)
        XCTAssertFalse(result.cancelled)
    }

    func testFinishStopsBatchWithoutPostingInput() async throws {
        let driver = RecordingInputDriver()
        let executor = ActionBatchExecutor(driver: driver)
        let batch = ValidatedBatch(summary: "done", expectsVisualChange: false, actions: [.finish(), .moveClick(x: 10, y: 20)])

        let result = try await executor.execute(batch, dryRun: false, shouldStop: { false })

        XCTAssertTrue(result.finished)
        XCTAssertTrue(driver.calls.isEmpty)
        XCTAssertEqual(result.executedCount, 0)
    }

    func testCancellationIsCheckedBetweenActions() async throws {
        let driver = RecordingInputDriver()
        let executor = ActionBatchExecutor(driver: driver)
        let batch = ValidatedBatch(summary: "cancel", expectsVisualChange: true, actions: [.typeText("a"), .typeText("b"), .typeText("c")])
        var checks = 0

        let result = try await executor.execute(batch, dryRun: false) {
            checks += 1
            return checks >= 2
        }

        XCTAssertEqual(driver.calls, ["type:a"])
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.executedCount, 1)
    }

    func testDriverCancellationBecomesCancelledExecutionResult() async throws {
        let driver = CancellingInputDriver()
        let executor = ActionBatchExecutor(driver: driver)
        let batch = ValidatedBatch(summary: "cancel inside action", expectsVisualChange: true, actions: [.typeText("long answer")])

        let result = try await executor.execute(batch, dryRun: false, shouldStop: { false })

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.executedCount, 0)
        XCTAssertFalse(result.finished)
    }

    func testNativeDriverChecksStopBeforeTypingAnyCharacter() async {
        let driver = NativeInputDriver(shouldStop: { true })

        do {
            try await driver.typeText("must-not-type")
            XCTFail("Expected cancellation before the first character")
        } catch let error as InputDriverError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHumanInputProfileKeepsKeyDelayWithinBounds() {
        let profile = HumanInputProfile(keyDelayRangeMilliseconds: 35...90, mouseDurationRangeMilliseconds: 160...420)
        XCTAssertEqual(profile.keyDelayMilliseconds(randomUnit: 0), 35)
        XCTAssertEqual(profile.keyDelayMilliseconds(randomUnit: 1), 90)
        XCTAssertTrue((35...90).contains(profile.keyDelayMilliseconds(randomUnit: 0.5)))
    }
}

private final class RecordingInputDriver: InputDriving {
    var calls: [String] = []

    func moveAndClick(x: Double, y: Double) async throws { calls.append("click:\(x),\(y)") }
    func typeText(_ text: String) async throws { calls.append("type:\(text)") }
    func pressKey(_ key: String) async throws { calls.append("key:\(key)") }
    func scroll(amount: Int) async throws { calls.append("scroll:\(amount)") }
    func wait(milliseconds: Int) async throws { calls.append("wait:\(milliseconds)") }
}

private final class CancellingInputDriver: InputDriving {
    func moveAndClick(x: Double, y: Double) async throws { throw InputDriverError.cancelled }
    func typeText(_ text: String) async throws { throw InputDriverError.cancelled }
    func pressKey(_ key: String) async throws { throw InputDriverError.cancelled }
    func scroll(amount: Int) async throws { throw InputDriverError.cancelled }
    func wait(milliseconds: Int) async throws { throw InputDriverError.cancelled }
}
