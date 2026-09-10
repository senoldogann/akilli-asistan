import Foundation

protocol ToolFabricExecuting: Sendable {
    func execute(_ invocation: ToolInvocation) async throws -> ToolExecutionReceipt
}

extension ToolFabric: ToolFabricExecuting {}

protocol ComputerMutationStateProviding: Sendable {
    func currentComputerMutationState() async throws -> ComputerMutationState
}

enum ToolFabricComputerMutationGatewayError: Error, Equatable {
    case unavailableTool(ToolID)
}

struct ToolFabricComputerMutationGateway: Sendable {
    private let toolFabric: any ToolFabricExecuting
    private let registry: ToolRegistry
    private let stateProvider: any ComputerMutationStateProviding
    private let mapper: ComputerActionToolMapper

    init(
        toolFabric: any ToolFabricExecuting,
        registry: ToolRegistry,
        stateProvider: any ComputerMutationStateProviding,
        mapper: ComputerActionToolMapper = ComputerActionToolMapper()
    ) {
        self.toolFabric = toolFabric
        self.registry = registry
        self.stateProvider = stateProvider
        self.mapper = mapper
    }

    func execute(
        _ actions: [ToolFabricComputerAction],
        parentInvocationID: InvocationID
    ) async throws -> [ToolExecutionReceipt] {
        var receipts: [ToolExecutionReceipt] = []
        receipts.reserveCapacity(actions.count)

        for (index, action) in actions.enumerated() {
            let state = try await stateProvider.currentComputerMutationState()
            let mapping = try mapper.map(action, state: state)
            let snapshot = await registry.snapshot()

            guard let descriptor = snapshot.descriptors[mapping.toolID], descriptor.enabled else {
                throw ToolFabricComputerMutationGatewayError.unavailableTool(mapping.toolID)
            }

            let invocation = ToolInvocation(
                invocationID: InvocationID(
                    rawValue: "\(parentInvocationID.rawValue):computer:\(UUID().uuidString)"
                ),
                toolID: mapping.toolID,
                registryRevision: snapshot.revision,
                descriptorRevision: descriptor.descriptorRevision,
                schemaDigest: descriptor.schemaDigest,
                argumentsJSON: mapping.argumentsJSON,
                logicalOperationKey: logicalOperationKey(
                    descriptor: descriptor,
                    parentInvocationID: parentInvocationID,
                    actionIndex: index
                )
            )

            receipts.append(try await toolFabric.execute(invocation))
        }

        return receipts
    }

    private func logicalOperationKey(
        descriptor: ToolDescriptor,
        parentInvocationID: InvocationID,
        actionIndex: Int
    ) -> String? {
        guard descriptor.idempotency == .logicalOperationKeyRequired else {
            return nil
        }
        return "computer:\(parentInvocationID.rawValue):\(actionIndex):\(descriptor.id.rawValue)"
    }
}
