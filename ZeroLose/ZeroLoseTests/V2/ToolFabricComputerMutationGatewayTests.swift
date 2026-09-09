import Foundation
import XCTest
@testable import ZeroLose

final class ToolFabricComputerMutationGatewayTests: XCTestCase {
    func testThreePhysicalActionsUseFreshInvocationRegistryAndState() async throws {
        let registry = ToolRegistry()
        await registry.register(.computerMutationTest(id: "computer.pointer.click"))
        await registry.register(.computerMutationTest(id: "computer.keyboard.type"))

        let stateProvider = SequencedComputerMutationStateProvider(
            states: [
                ComputerMutationState(stateVersion: 10, observationID: "obs-10"),
                ComputerMutationState(stateVersion: 11, observationID: "obs-11"),
                ComputerMutationState(stateVersion: 12, observationID: "obs-12"),
            ]
        )
        let fabric = RecordingComputerToolFabric(registry: registry)
        let gateway = ToolFabricComputerMutationGateway(
            toolFabric: fabric,
            registry: registry,
            stateProvider: stateProvider
        )

        let receipts = try await gateway.execute(
            [
                .click(x: 10, y: 10),
                .type("hello"),
                .click(x: 20, y: 20),
            ],
            parentInvocationID: InvocationID(rawValue: "parent")
        )

        let invocations = await fabric.recordedInvocations
        let stateReadCount = await stateProvider.readCount
        let invocationIDs = Set(invocations.map(\.invocationID))
        let registryRevisions = invocations.map(\.registryRevision)
        let toolIDs = invocations.map { $0.toolID.rawValue }
        let stateMetadata = try invocations.map(Self.decodeStateMetadata)

        XCTAssertEqual(receipts.count, 3)
        XCTAssertEqual(invocations.count, 3)
        XCTAssertEqual(invocationIDs.count, 3, "Every physical action needs a fresh invocation")
        XCTAssertEqual(stateReadCount, 3, "Current computer state must be read before every action")
        XCTAssertEqual(registryRevisions, [2, 3, 4], "Registry must be re-snapshotted before every action")
        XCTAssertEqual(
            toolIDs,
            ["computer.pointer.click", "computer.keyboard.type", "computer.pointer.click"]
        )
        XCTAssertEqual(
            stateMetadata,
            [
                StateMetadata(stateVersion: 10, observationID: "obs-10"),
                StateMetadata(stateVersion: 11, observationID: "obs-11"),
                StateMetadata(stateVersion: 12, observationID: "obs-12"),
            ]
        )
    }

    private static func decodeStateMetadata(_ invocation: ToolInvocation) throws -> StateMetadata {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: invocation.argumentsJSON) as? [String: Any]
        )
        let stateVersion = try XCTUnwrap((object["stateVersion"] as? NSNumber)?.uint64Value)
        let observationID = try XCTUnwrap(object["observationID"] as? String)
        return StateMetadata(stateVersion: stateVersion, observationID: observationID)
    }
}

private struct StateMetadata: Equatable {
    let stateVersion: UInt64
    let observationID: String
}

private actor SequencedComputerMutationStateProvider: ComputerMutationStateProviding {
    private let states: [ComputerMutationState]
    private var index = 0
    private(set) var readCount = 0

    init(states: [ComputerMutationState]) {
        self.states = states
    }

    func currentComputerMutationState() async throws -> ComputerMutationState {
        guard index < states.count else {
            throw TestGatewayError.missingState
        }
        let state = states[index]
        index += 1
        readCount += 1
        return state
    }
}

private actor RecordingComputerToolFabric: ToolFabricExecuting {
    private let registry: ToolRegistry
    private(set) var recordedInvocations: [ToolInvocation] = []

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    func execute(_ invocation: ToolInvocation) async throws -> ToolExecutionReceipt {
        recordedInvocations.append(invocation)

        if recordedInvocations.count < 3 {
            await registry.register(
                .computerMutationTest(
                    id: "builtin.test-revision-\(recordedInvocations.count)",
                    providerID: "builtin",
                    effectClass: .read,
                    declaredRisk: .readOnly
                )
            )
        }

        let now = Date()
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: invocation.toolID,
            startedAt: now,
            completedAt: now,
            providerReference: "recording-tool-fabric"
        )
    }
}

private enum TestGatewayError: Error {
    case missingState
}

private extension ToolDescriptor {
    static func computerMutationTest(
        id: String,
        providerID: String = "computer",
        effectClass: EffectClass = .reversibleLocalMutation,
        declaredRisk: RiskLevel = .reversibleLocalMutation
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
            idempotency: .none,
            concurrencyClass: effectClass == .read ? .read : .mutation,
            verificationContract: VerificationContract(kind: "test"),
            enabled: true
        )
    }
}
