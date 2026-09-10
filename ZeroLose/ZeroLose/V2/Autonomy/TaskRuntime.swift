import Foundation

enum TaskExecutionResult: Sendable, Equatable {
    case modelFinalText(String)
    case toolReceipt(ToolExecutionReceipt)
    case evidence([VerificationEvidence])

    var verificationEvidence: [VerificationEvidence] {
        switch self {
        case .modelFinalText, .toolReceipt:
            return []
        case .evidence(let evidence):
            return evidence
        }
    }
}

protocol TaskInvocationExecuting: Sendable {
    func execute(
        task: TaskNode,
        budget: RuntimeBudget
    ) async throws -> TaskExecutionResult

    func cancelActiveInvocation() async
}

actor TaskRuntime {
    private let executor: any TaskInvocationExecuting
    private let verifier: any TaskVerifying
    private let budget: RuntimeBudget

    private var activeExecution: Task<TaskExecutionResult, Error>?
    private var cancellationRequested = false

    init(
        executor: any TaskInvocationExecuting,
        verifier: any TaskVerifying,
        budget: RuntimeBudget
    ) {
        self.executor = executor
        self.verifier = verifier
        self.budget = budget
    }

    func run(_ task: TaskNode) async throws -> TaskNode {
        var current = task
        cancellationRequested = false

        try await budget.beginParallelWork()
        current.lifecycle = .running

        let executor = self.executor
        let budget = self.budget
        let child = Task {
            try await executor.execute(task: current, budget: budget)
        }
        activeExecution = child

        do {
            let executionResult = try await child.value
            activeExecution = nil
            await budget.endParallelWork()

            if cancellationRequested || Task.isCancelled {
                current.lifecycle = .cancelled
                return current
            }

            current.lifecycle = .verifying
            let verification = await verifier.verify(
                task: current,
                evidence: executionResult.verificationEvidence
            )

            if cancellationRequested || Task.isCancelled {
                current.lifecycle = .cancelled
                return current
            }

            switch verification {
            case .verified(let evidence):
                current.verificationEvidence.append(evidence)
                current.lifecycle = .succeeded
            case .rejected:
                current.lifecycle = .failed
            }

            return current
        } catch is CancellationError {
            activeExecution = nil
            await budget.endParallelWork()
            current.lifecycle = .cancelled
            return current
        } catch {
            activeExecution = nil
            await budget.endParallelWork()
            current.lifecycle = .failed
            throw error
        }
    }

    func cancel() async {
        cancellationRequested = true
        activeExecution?.cancel()
        await executor.cancelActiveInvocation()
    }
}
