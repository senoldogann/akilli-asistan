import Foundation

enum AgentToolInvocationExecutorError: Error, Sendable, Equatable {
    case missingPlannedInvocation
    case missingVerificationExpectation
    case descriptorUnavailable
    case unsupportedVerificationContract(String)
    case computerVerificationUnavailable
    case observationMetadataUnavailable
    case observationMetadataMismatch
}

struct AgentToolInvocationExecutor: TaskInvocationExecuting, Sendable {
    private let registry: ToolRegistry
    private let toolFabric: any ToolFabricExecuting
    private let mutationExecutionState: AgentMutationExecutionState
    private let computerStateProvider: (any ComputerVerificationStateRefreshing)?
    private let computerCapturer: (any ComputerVerificationCapturing)?
    private let binder: ComputerInvocationFreshnessBinder
    private let shouldStop: @Sendable () -> Bool
    private let settle: @Sendable () async throws -> Void

    init(
        registry: ToolRegistry,
        toolFabric: any ToolFabricExecuting,
        mutationExecutionState: AgentMutationExecutionState,
        computerStateProvider: (any ComputerVerificationStateRefreshing)? = nil,
        computerCapturer: (any ComputerVerificationCapturing)? = nil,
        binder: ComputerInvocationFreshnessBinder = ComputerInvocationFreshnessBinder(),
        shouldStop: @escaping @Sendable () -> Bool = { false },
        settle: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    ) {
        self.registry = registry
        self.toolFabric = toolFabric
        self.mutationExecutionState = mutationExecutionState
        self.computerStateProvider = computerStateProvider
        self.computerCapturer = computerCapturer
        self.binder = binder
        self.shouldStop = shouldStop
        self.settle = settle
    }

    func execute(
        task: TaskNode,
        budget: RuntimeBudget
    ) async throws -> TaskExecutionResult {
        try Task.checkCancellation()
        guard !shouldStop() else { throw CancellationError() }
        guard let planned = task.plannedInvocation else {
            throw AgentToolInvocationExecutorError.missingPlannedInvocation
        }
        guard let expectation = planned.verificationExpectation else {
            throw AgentToolInvocationExecutorError.missingVerificationExpectation
        }

        let snapshot = await registry.snapshot()
        guard let descriptor = snapshot.descriptors[planned.toolID], descriptor.enabled else {
            throw AgentToolInvocationExecutorError.descriptorUnavailable
        }
        guard expectation.isCompatible(
            toolID: descriptor.id,
            verificationContract: descriptor.verificationContract
        ) else {
            throw AgentToolInvocationExecutorError.unsupportedVerificationContract(
                descriptor.verificationContract.kind
            )
        }

        switch descriptor.verificationContract.kind {
        case "read-result":
            let receipt = try await executeThroughFabric(
                task: task,
                planned: planned,
                descriptor: descriptor,
                snapshot: snapshot,
                argumentsJSON: planned.argumentsJSON
            )
            try Task.checkCancellation()
            guard !shouldStop() else { throw CancellationError() }
            return .toolVerification(
                ToolVerificationArtifact(
                    receipt: receipt,
                    descriptor: descriptor,
                    expectation: expectation,
                    computer: nil
                )
            )

        case "fresh-computer-observation":
            guard let computerStateProvider, let computerCapturer else {
                throw AgentToolInvocationExecutorError.computerVerificationUnavailable
            }

            let preState = try await computerStateProvider.refreshComputerMutationState()
            let preMetadata = try await requireMetadata(
                from: computerStateProvider,
                matching: preState
            )
            let before = try await computerCapturer.capture(metadata: preMetadata)
            try Task.checkCancellation()
            guard !shouldStop() else { throw CancellationError() }

            let boundArguments = try binder.bind(
                argumentsJSON: planned.argumentsJSON,
                state: preState
            )
            let receipt = try await executeThroughFabric(
                task: task,
                planned: planned,
                descriptor: descriptor,
                snapshot: snapshot,
                argumentsJSON: boundArguments
            )
            try Task.checkCancellation()
            guard !shouldStop() else { throw CancellationError() }

            try await settle()
            try Task.checkCancellation()
            guard !shouldStop() else { throw CancellationError() }

            let postState = try await computerStateProvider.refreshComputerMutationState()
            let postMetadata = try await requireMetadata(
                from: computerStateProvider,
                matching: postState
            )
            let after = try await computerCapturer.capture(metadata: postMetadata)
            try Task.checkCancellation()
            guard !shouldStop() else { throw CancellationError() }

            return .toolVerification(
                ToolVerificationArtifact(
                    receipt: receipt,
                    descriptor: descriptor,
                    expectation: expectation,
                    computer: ComputerVerificationArtifact(
                        before: before,
                        after: after,
                        uiStable: true
                    )
                )
            )

        default:
            throw AgentToolInvocationExecutorError.unsupportedVerificationContract(
                descriptor.verificationContract.kind
            )
        }
    }

    func cancelActiveInvocation() async {}

    private func executeThroughFabric(
        task: TaskNode,
        planned: PlannedToolInvocation,
        descriptor: ToolDescriptor,
        snapshot: ToolRegistrySnapshot,
        argumentsJSON: Data
    ) async throws -> ToolExecutionReceipt {
        let invocation = ToolInvocation(
            invocationID: InvocationID(rawValue: UUID().uuidString),
            toolID: planned.toolID,
            registryRevision: snapshot.revision,
            descriptorRevision: descriptor.descriptorRevision,
            schemaDigest: descriptor.schemaDigest,
            argumentsJSON: argumentsJSON,
            logicalOperationKey: descriptor.idempotency == .logicalOperationKeyRequired
                ? "agent-task:\(task.id.rawValue)"
                : nil
        )

        let tracksMutation = task.concurrencyClass == .mutation
        if tracksMutation {
            mutationExecutionState.begin()
        }
        defer {
            if tracksMutation {
                mutationExecutionState.end()
            }
        }
        return try await toolFabric.execute(invocation)
    }

    private func requireMetadata(
        from provider: any ComputerObservationMetadataProviding,
        matching state: ComputerMutationState
    ) async throws -> MacOSComputerObservationPresentationMetadata {
        guard let metadata = await provider.latestPresentationMetadata() else {
            throw AgentToolInvocationExecutorError.observationMetadataUnavailable
        }
        guard metadata.stateVersion == state.stateVersion,
              metadata.observationID == state.observationID else {
            throw AgentToolInvocationExecutorError.observationMetadataMismatch
        }
        return metadata
    }
}
