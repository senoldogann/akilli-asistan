import Foundation
import XCTest
@testable import ZeroLose

final class V2NativeToolRuntimeTests: XCTestCase {
    func testConfigurationRoutesModelToolCallThroughToolFabric() async throws {
        let registry = ToolRegistry()
        let descriptor = Self.descriptor(id: "builtin.echo")
        await registry.register(descriptor)

        let provider = NativeRuntimeRecordingProvider(resultJSON: Data(#"{"value":"pong"}"#.utf8))
        let fabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: InMemoryCredentialBroker(),
            providers: [provider],
            authorityMode: .auto
        )
        let runtime = V2NativeToolRuntime(registry: registry, toolFabric: fabric)

        let configuration = await runtime.configuration()
        XCTAssertEqual(configuration.tools.count, 1)
        guard let functionName = configuration.tools.first?.function.name else {
            return XCTFail("Expected one model-visible V2 tool")
        }

        let result = await configuration.executor(
            AgentToolCall(
                id: "native-call-1",
                name: functionName,
                argumentsJSON: #"{"value":"ping"}"#
            )
        )

        let executionCount = await provider.executionCount
        XCTAssertEqual(executionCount, 1)
        XCTAssertTrue(result.contains("\"ok\":true"))
        XCTAssertTrue(result.contains("pong"))
    }

    func testOldConfigurationFailsClosedAfterToolDisable() async throws {
        let registry = ToolRegistry()
        let descriptor = Self.descriptor(id: "builtin.echo")
        await registry.register(descriptor)

        let provider = NativeRuntimeRecordingProvider(resultJSON: Data(#"{"value":"pong"}"#.utf8))
        let fabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: InMemoryCredentialBroker(),
            providers: [provider],
            authorityMode: .auto
        )
        let runtime = V2NativeToolRuntime(registry: registry, toolFabric: fabric)
        let oldConfiguration = await runtime.configuration()
        guard let functionName = oldConfiguration.tools.first?.function.name else {
            return XCTFail("Expected one model-visible V2 tool")
        }

        try await runtime.setToolEnabled(descriptor.id, enabled: false)
        let result = await oldConfiguration.executor(
            AgentToolCall(id: "native-call-stale", name: functionName, argumentsJSON: #"{"value":"ping"}"#)
        )

        let executionCount = await provider.executionCount
        XCTAssertEqual(executionCount, 0)
        XCTAssertTrue(result.contains("stale_registry_revision"))
    }

    func testInitialDescriptorsBootstrapBeforeFirstConfiguration() async throws {
        let registry = ToolRegistry()
        let descriptor = Self.descriptor(id: "builtin.echo")
        let provider = NativeRuntimeRecordingProvider(resultJSON: Data("{}".utf8))
        let fabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: InMemoryCredentialBroker(),
            providers: [provider],
            authorityMode: .auto
        )
        let runtime = V2NativeToolRuntime(
            registry: registry,
            toolFabric: fabric,
            initialDescriptors: [descriptor]
        )

        let configuration = await runtime.configuration()
        let snapshot = await registry.snapshot()

        XCTAssertEqual(configuration.tools.count, 1)
        XCTAssertEqual(snapshot.descriptors.count, 1)
        XCTAssertGreaterThan(snapshot.revision, 0)
    }

    func testDisabledToolCanBeReenabled() async throws {
        let registry = ToolRegistry()
        let descriptor = Self.descriptor(id: "builtin.echo")
        await registry.register(descriptor)
        let provider = NativeRuntimeRecordingProvider(resultJSON: Data("{}".utf8))
        let fabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: InMemoryCredentialBroker(),
            providers: [provider],
            authorityMode: .auto
        )
        let runtime = V2NativeToolRuntime(registry: registry, toolFabric: fabric)

        try await runtime.setToolEnabled(descriptor.id, enabled: false)
        try await runtime.setToolEnabled(descriptor.id, enabled: true)
        let configuration = await runtime.configuration()

        XCTAssertEqual(configuration.tools.count, 1)
    }

    private static func descriptor(id: String) -> ToolDescriptor {
        let input = Data(
            #"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}"#.utf8
        )
        return ToolDescriptor(
            id: ToolID(rawValue: id),
            providerID: "builtin",
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: input,
            outputSchemaJSON: nil,
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: [],
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: "read-result"),
            enabled: true
        )
    }
}

private actor NativeRuntimeRecordingProvider: ToolProviding {
    nonisolated let providerID = "builtin"
    private let resultJSON: Data
    private(set) var executionCount = 0

    init(resultJSON: Data) {
        self.resultJSON = resultJSON
    }

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        executionCount += 1
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: Date(),
            completedAt: Date(),
            providerReference: "native-runtime-test",
            resultProvenance: "test",
            resultJSON: resultJSON,
            resultTainted: false
        )
    }
}
