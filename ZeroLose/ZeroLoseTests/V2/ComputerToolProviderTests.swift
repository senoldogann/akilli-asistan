import Foundation
import XCTest
@testable import ZeroLose

final class ComputerToolProviderTests: XCTestCase {
    func testComputerProviderRoutesMutationThroughGateway() async throws {
        let gateway = RecordingComputerMutationGateway()
        let provider = ComputerToolProvider(gateway: gateway)
        let argumentsJSON = Data(#"{"stateVersion":42,"observationID":"obs-42","x":100,"y":200}"#.utf8)
        let descriptor = ToolDescriptor.providerTest(
            id: "computer.pointer.click",
            providerID: "computer",
            effectClass: .reversibleLocalMutation,
            declaredRisk: .reversibleLocalMutation
        )
        let invocation = ToolInvocation.providerTest(
            toolID: descriptor.id.rawValue,
            argumentsJSON: argumentsJSON
        )

        let receipt = try await provider.execute(
            descriptor: descriptor,
            invocation: invocation,
            credentialHandles: []
        )

        let proposal = await gateway.lastProposal
        let parentInvocationID = await gateway.lastParentInvocationID
        let proposalCount = await gateway.proposalCount

        XCTAssertEqual(proposalCount, 1)
        XCTAssertEqual(proposal?.action, "pointer.click")
        XCTAssertEqual(proposal?.stateVersion, 42)
        XCTAssertEqual(proposal?.observationID, "obs-42")
        XCTAssertEqual(proposal?.argumentsJSON, argumentsJSON)
        XCTAssertEqual(parentInvocationID, invocation.invocationID)
        XCTAssertEqual(receipt.invocationID, invocation.invocationID)
        XCTAssertEqual(receipt.toolID, descriptor.id)
    }

    func testComputerProviderRejectsMissingStateMetadataBeforeGateway() async {
        let gateway = RecordingComputerMutationGateway()
        let provider = ComputerToolProvider(gateway: gateway)
        let descriptor = ToolDescriptor.providerTest(
            id: "computer.pointer.click",
            providerID: "computer",
            effectClass: .reversibleLocalMutation,
            declaredRisk: .reversibleLocalMutation
        )
        let invocation = ToolInvocation.providerTest(
            toolID: descriptor.id.rawValue,
            argumentsJSON: Data(#"{"x":100,"y":200}"#.utf8)
        )

        do {
            _ = try await provider.execute(
                descriptor: descriptor,
                invocation: invocation,
                credentialHandles: []
            )
            XCTFail("Expected missing state metadata to fail closed")
        } catch let error as ComputerToolProviderError {
            XCTAssertEqual(error, .invalidArguments)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let proposalCount = await gateway.proposalCount
        XCTAssertEqual(proposalCount, 0)
    }

    func testBuiltinProviderDelegatesToInjectedExecutor() async throws {
        let executor = RecordingBuiltinExecutor()
        let provider = BuiltinToolProvider(executor: executor)
        let descriptor = ToolDescriptor.providerTest(
            id: "builtin.echo",
            providerID: "builtin",
            effectClass: .read,
            declaredRisk: .readOnly
        )
        let invocation = ToolInvocation.providerTest(toolID: descriptor.id.rawValue)

        let receipt = try await provider.execute(
            descriptor: descriptor,
            invocation: invocation,
            credentialHandles: []
        )

        let executionCount = await executor.executionCount
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(receipt.invocationID, invocation.invocationID)
        XCTAssertEqual(receipt.toolID, descriptor.id)
    }
}

private actor RecordingComputerMutationGateway: ComputerMutationGating {
    private(set) var proposalCount = 0
    private(set) var lastProposal: ComputerPhysicalProposal?
    private(set) var lastParentInvocationID: InvocationID?

    func executePhysicalProposal(
        _ proposal: ComputerPhysicalProposal,
        parentInvocationID: InvocationID
    ) async throws -> ToolExecutionReceipt {
        proposalCount += 1
        lastProposal = proposal
        lastParentInvocationID = parentInvocationID
        let now = Date()
        return ToolExecutionReceipt(
            invocationID: parentInvocationID,
            toolID: ToolID(rawValue: "computer.\(proposal.action)"),
            startedAt: now,
            completedAt: now,
            providerReference: "recording-computer-gateway"
        )
    }
}

private actor RecordingBuiltinExecutor: BuiltinToolExecuting {
    private(set) var executionCount = 0

    func executeBuiltin(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        executionCount += 1
        let now = Date()
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: now,
            completedAt: now,
            providerReference: "recording-builtin"
        )
    }
}

private extension ToolDescriptor {
    static func providerTest(
        id: String,
        providerID: String,
        effectClass: EffectClass,
        declaredRisk: RiskLevel
    ) -> Self {
        Self(
            id: ToolID(rawValue: id),
            providerID: providerID,
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: nil,
            effectClass: effectClass,
            declaredRisk: declaredRisk,
            requiredCredentialScopes: [],
            idempotency: effectClass == .read ? .none : .logicalOperationKeyRequired,
            concurrencyClass: effectClass == .read ? .read : .mutation,
            verificationContract: VerificationContract(kind: "test"),
            enabled: true
        )
    }
}

private extension ToolInvocation {
    static func providerTest(
        toolID: String,
        argumentsJSON: Data = Data("{}".utf8)
    ) -> Self {
        Self(
            invocationID: InvocationID(rawValue: "invocation-provider-test"),
            toolID: ToolID(rawValue: toolID),
            registryRevision: 1,
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            argumentsJSON: argumentsJSON
        )
    }
}
