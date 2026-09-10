import Foundation
import XCTest
@testable import ZeroLose

final class TaskRuntimeTests: XCTestCase {
    func testModelFinalTextDoesNotCompleteTaskWithoutVerifierEvidence() async throws {
        let executor = StubTaskInvocationExecutor(result: .modelFinalText("done"))
        let runtime = TaskRuntime(
            executor: executor,
            verifier: RejectingTaskVerifier(),
            budget: generousBudget()
        )

        let result = try await runtime.run(readyTask())

        XCTAssertNotEqual(result.lifecycle, .succeeded)
        XCTAssertTrue(result.verificationEvidence.isEmpty)
    }

    func testMutationReceiptAloneDoesNotCompleteTask() async throws {
        let receipt = ToolExecutionReceipt(
            invocationID: InvocationID(rawValue: "inv-1"),
            toolID: ToolID(rawValue: "tool-1"),
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            providerReference: "provider-ref"
        )
        let executor = StubTaskInvocationExecutor(result: .toolReceipt(receipt))
        let runtime = TaskRuntime(
            executor: executor,
            verifier: RejectingTaskVerifier(),
            budget: generousBudget()
        )

        let result = try await runtime.run(readyTask())

        XCTAssertNotEqual(result.lifecycle, .succeeded)
        XCTAssertTrue(result.verificationEvidence.isEmpty)
    }

    func testVerifierEvidenceIsRequiredForTaskSuccess() async throws {
        let verifiedEvidence = VerificationEvidence(
            evidenceID: "verified-1",
            summary: "Observed expected post-condition",
            provenance: "task-verifier",
            recordedAt: Date(timeIntervalSince1970: 20)
        )
        let executor = StubTaskInvocationExecutor(result: .modelFinalText("done"))
        let runtime = TaskRuntime(
            executor: executor,
            verifier: AcceptingTaskVerifier(evidence: verifiedEvidence),
            budget: generousBudget()
        )

        let result = try await runtime.run(readyTask())

        XCTAssertEqual(result.lifecycle, .succeeded)
        XCTAssertEqual(result.verificationEvidence, [verifiedEvidence])
    }

    func testCancellationCancelsActiveChildInvocation() async throws {
        let executor = BlockingTaskInvocationExecutor()
        let runtime = TaskRuntime(
            executor: executor,
            verifier: RejectingTaskVerifier(),
            budget: generousBudget()
        )

        let running = Task { try await runtime.run(readyTask()) }
        for _ in 0..<100 {
            if await executor.didStart {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let didStart = await executor.didStart
        XCTAssertTrue(didStart)

        await runtime.cancel()
        _ = try? await running.value

        let wasCancellationRequested = await executor.wasCancellationRequested
        XCTAssertTrue(wasCancellationRequested)
    }

    func testRuntimeBudgetBoundsModelToolRecoverySpendAndParallelWork() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let budget = RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 60,
                maxModelCalls: 1,
                maxToolCalls: 1,
                maxRecoveryAttempts: 1,
                maxExternalSpend: 5,
                maxParallelTasks: 1,
                deadline: Date(timeIntervalSince1970: 200)
            ),
            startedAt: start
        )

        try await budget.reserveModelCall(now: start)
        await assertBudgetError(.modelCallLimitExceeded) {
            try await budget.reserveModelCall(now: start)
        }

        try await budget.reserveToolCall(now: start)
        await assertBudgetError(.toolCallLimitExceeded) {
            try await budget.reserveToolCall(now: start)
        }

        try await budget.reserveExternalSpend(5, now: start)
        await assertBudgetError(.externalSpendLimitExceeded) {
            try await budget.reserveExternalSpend(0.01, now: start)
        }

        try await budget.beginParallelWork(now: start)
        await assertBudgetError(.parallelTaskLimitExceeded) {
            try await budget.beginParallelWork(now: start)
        }
        await budget.endParallelWork()

        try await budget.reserveRecoveryAttempt(
            failureFingerprint: "f1",
            strategyID: "s1",
            now: start
        )
        await assertBudgetError(.recoveryAttemptLimitExceeded) {
            try await budget.reserveRecoveryAttempt(
                failureFingerprint: "f2",
                strategyID: "s2",
                now: start
            )
        }
    }

    func testRuntimeBudgetRejectsBlindRepeatOfSameFailureAndStrategy() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let budget = RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 60,
                maxModelCalls: 10,
                maxToolCalls: 10,
                maxRecoveryAttempts: 3,
                maxExternalSpend: 100,
                maxParallelTasks: 2,
                deadline: nil
            ),
            startedAt: start
        )

        try await budget.reserveRecoveryAttempt(
            failureFingerprint: "same-failure",
            strategyID: "same-strategy",
            now: start
        )

        await assertBudgetError(.duplicateRecoveryStrategy) {
            try await budget.reserveRecoveryAttempt(
                failureFingerprint: "same-failure",
                strategyID: "same-strategy",
                now: start
            )
        }
    }

    func testRuntimeBudgetEnforcesWallClockAndDeadline() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let budget = RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 5,
                maxModelCalls: 10,
                maxToolCalls: 10,
                maxRecoveryAttempts: 3,
                maxExternalSpend: 100,
                maxParallelTasks: 2,
                deadline: Date(timeIntervalSince1970: 120)
            ),
            startedAt: start
        )

        await assertBudgetError(.wallClockLimitExceeded) {
            try await budget.reserveModelCall(now: Date(timeIntervalSince1970: 106))
        }

        let deadlineBudget = RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 60,
                maxModelCalls: 10,
                maxToolCalls: 10,
                maxRecoveryAttempts: 3,
                maxExternalSpend: 100,
                maxParallelTasks: 2,
                deadline: Date(timeIntervalSince1970: 105)
            ),
            startedAt: start
        )
        await assertBudgetError(.deadlineExceeded) {
            try await deadlineBudget.reserveToolCall(now: Date(timeIntervalSince1970: 106))
        }
    }

    func testTaskRuntimeDoesNotOwnParallelPolicyEngine() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeURL = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Autonomy/TaskRuntime.swift")

        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            XCTFail("TaskRuntime.swift must exist")
            return
        }

        let source = try String(contentsOf: runtimeURL, encoding: .utf8)
        XCTAssertFalse(source.contains("PolicyKernel"))
        XCTAssertFalse(source.contains("PolicyEvaluating"))
    }

    private func readyTask() -> TaskNode {
        TaskNode(
            id: TaskID(rawValue: "task-1"),
            title: "Run task",
            lifecycle: .ready
        )
    }

    private func generousBudget() -> RuntimeBudget {
        RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 300,
                maxModelCalls: 100,
                maxToolCalls: 100,
                maxRecoveryAttempts: 10,
                maxExternalSpend: 1_000,
                maxParallelTasks: 8,
                deadline: nil
            )
        )
    }

    private func assertBudgetError(
        _ expected: RuntimeBudgetError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected budget error: \(expected)")
        } catch {
            XCTAssertEqual(error as? RuntimeBudgetError, expected)
        }
    }
}

private actor StubTaskInvocationExecutor: TaskInvocationExecuting {
    private let result: TaskExecutionResult

    init(result: TaskExecutionResult) {
        self.result = result
    }

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        result
    }

    func cancelActiveInvocation() async {}
}

private actor BlockingTaskInvocationExecutor: TaskInvocationExecuting {
    private(set) var didStart = false
    private(set) var wasCancellationRequested = false

    func execute(task: TaskNode, budget: RuntimeBudget) async throws -> TaskExecutionResult {
        didStart = true
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }

    func cancelActiveInvocation() async {
        wasCancellationRequested = true
    }
}

private struct RejectingTaskVerifier: TaskVerifying {
    func verify(task: TaskNode, evidence: [VerificationEvidence]) async -> TaskVerificationResult {
        .rejected(reason: "No independent verification evidence")
    }
}

private struct AcceptingTaskVerifier: TaskVerifying {
    let evidence: VerificationEvidence

    func verify(task: TaskNode, evidence: [VerificationEvidence]) async -> TaskVerificationResult {
        .verified(self.evidence)
    }
}
