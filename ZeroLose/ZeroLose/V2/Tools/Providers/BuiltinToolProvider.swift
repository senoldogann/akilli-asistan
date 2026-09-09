protocol BuiltinToolExecuting: Sendable {
    func executeBuiltin(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt
}

struct BuiltinToolProvider: ToolProviding {
    let providerID = "builtin"

    private let executor: BuiltinToolExecuting

    init(executor: BuiltinToolExecuting) {
        self.executor = executor
    }

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        try await executor.executeBuiltin(
            descriptor: descriptor,
            invocation: invocation,
            credentialHandles: credentialHandles
        )
    }
}
