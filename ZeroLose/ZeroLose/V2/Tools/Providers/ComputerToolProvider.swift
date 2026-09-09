import Foundation

enum ComputerToolProviderError: Error, Equatable {
    case invalidArguments
}

struct ComputerToolProvider: ToolProviding {
    let providerID = "computer"

    private let gateway: ComputerMutationGating

    init(gateway: ComputerMutationGating) {
        self.gateway = gateway
    }

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        guard descriptor.id.rawValue.hasPrefix("computer."),
              descriptor.id == invocation.toolID else {
            throw ComputerToolProviderError.invalidArguments
        }

        struct Metadata: Decodable {
            let stateVersion: UInt64
            let observationID: String
        }

        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: invocation.argumentsJSON),
              !metadata.observationID.isEmpty else {
            throw ComputerToolProviderError.invalidArguments
        }

        let action = String(descriptor.id.rawValue.dropFirst("computer.".count))
        guard !action.isEmpty else {
            throw ComputerToolProviderError.invalidArguments
        }

        let proposal = ComputerPhysicalProposal(
            action: action,
            stateVersion: metadata.stateVersion,
            observationID: metadata.observationID,
            argumentsJSON: invocation.argumentsJSON
        )

        return try await gateway.executePhysicalProposal(
            proposal,
            parentInvocationID: invocation.invocationID
        )
    }
}
