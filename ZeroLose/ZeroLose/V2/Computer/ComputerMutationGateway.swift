import Foundation

struct ComputerPhysicalProposal: Sendable, Equatable {
    let action: String
    let stateVersion: UInt64
    let observationID: String
    let argumentsJSON: Data
}

protocol ComputerMutationGating: Sendable {
    func executePhysicalProposal(
        _ proposal: ComputerPhysicalProposal,
        parentInvocationID: InvocationID
    ) async throws -> ToolExecutionReceipt
}
