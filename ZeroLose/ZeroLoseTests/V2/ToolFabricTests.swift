import Foundation
import XCTest
@testable import ZeroLose

final class ToolFabricTests: XCTestCase {
    func testUnknownToolNeverReachesProvider() async {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        let fabric = makeFabric(registry: registry, provider: provider)

        do {
            _ = try await fabric.execute(.test(toolID: "builtin.missing", registryRevision: 0))
            XCTFail("Expected unknown tool to fail closed")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .unknownTool(ToolID(rawValue: "builtin.missing")))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let executionCount = await provider.executionCount
        XCTAssertEqual(executionCount, 0)
    }

    func testStaleRegistryRevisionNeverReachesProvider() async {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        await registry.register(.test(id: "builtin.echo"))
        let fabric = makeFabric(registry: registry, provider: provider)

        do {
            _ = try await fabric.execute(.test(toolID: "builtin.echo", registryRevision: 0))
            XCTFail("Expected stale registry revision to fail closed")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .staleRegistryRevision(expected: 1, actual: 0))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let executionCount = await provider.executionCount
        XCTAssertEqual(executionCount, 0)
    }

    func testMissingCredentialScopeIsDeniedBeforeHandleIssuanceAndProviderExecution() async {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        let broker = RecordingCredentialBroker(availableScopes: [])
        await registry.register(.test(id: "builtin.secure", requiredCredentialScopes: ["scope.secure"]))
        let fabric = makeFabric(registry: registry, provider: provider, broker: broker)

        do {
            _ = try await fabric.execute(.test(toolID: "builtin.secure", registryRevision: 1))
            XCTFail("Expected missing credential scope to fail closed")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .policyDenied(.credentialScopeMissing))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let issueCount = await broker.issueCount
        let executionCount = await provider.executionCount
        XCTAssertEqual(issueCount, 0)
        XCTAssertEqual(executionCount, 0)
    }

    func testProviderReceivesOpaqueHandleForEveryRequiredCredentialScope() async throws {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        let broker = RecordingCredentialBroker(availableScopes: ["scope.a", "scope.b"])
        await registry.register(
            .test(
                id: "builtin.multi-scope",
                requiredCredentialScopes: ["scope.a", "scope.b"]
            )
        )
        let fabric = makeFabric(registry: registry, provider: provider, broker: broker)

        _ = try await fabric.execute(.test(toolID: "builtin.multi-scope", registryRevision: 1))

        let issueCount = await broker.issueCount
        let receivedScopes = await provider.receivedCredentialScopes
        let executionCount = await provider.executionCount
        XCTAssertEqual(issueCount, 2)
        XCTAssertEqual(receivedScopes, Set(["scope.a", "scope.b"]))
        XCTAssertEqual(executionCount, 1)
    }

    private func makeFabric(
        registry: ToolRegistry,
        provider: RecordingToolProvider,
        broker: RecordingCredentialBroker = RecordingCredentialBroker(availableScopes: [])
    ) -> ToolFabric {
        ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: broker,
            providers: [provider],
            authorityMode: .auto
        )
    }
}

private actor RecordingToolProvider: ToolProviding {
    nonisolated let providerID: String
    private(set) var executionCount = 0
    private(set) var receivedCredentialScopes: Set<String> = []

    init(providerID: String) {
        self.providerID = providerID
    }

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        executionCount += 1
        receivedCredentialScopes = Set(credentialHandles.map(\.scope.rawValue))
        let now = Date()
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: now,
            completedAt: now,
            providerReference: nil
        )
    }
}

private actor RecordingCredentialBroker: CredentialBrokering {
    private let availableScopes: Set<CredentialScope>
    private(set) var issueCount = 0

    init(availableScopes: Set<String>) {
        self.availableScopes = Set(availableScopes.map(CredentialScope.init(rawValue:)))
    }

    func availability(for scope: CredentialScope) -> CredentialAvailability {
        CredentialAvailability(scope: scope, available: availableScopes.contains(scope))
    }

    func issueHandle(for scope: CredentialScope) throws -> CredentialHandle {
        guard availableScopes.contains(scope) else {
            throw CredentialBrokerError.scopeUnavailable(scope)
        }
        issueCount += 1
        return CredentialHandle(scope: scope)
    }

    func revoke(scope: CredentialScope) {}
}

private extension ToolDescriptor {
    static func test(
        id: String,
        providerID: String = "builtin",
        requiredCredentialScopes: Set<String> = []
    ) -> Self {
        Self(
            id: ToolID(rawValue: id),
            providerID: providerID,
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: nil,
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: requiredCredentialScopes,
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: "none"),
            enabled: true
        )
    }
}

private extension ToolInvocation {
    static func test(
        toolID: String,
        registryRevision: UInt64,
        descriptorRevision: UInt64 = 1,
        schemaDigest: String = "sha256:test",
        argumentsJSON: Data = Data("{}".utf8)
    ) -> Self {
        Self(
            invocationID: InvocationID(rawValue: "invocation-1"),
            toolID: ToolID(rawValue: toolID),
            registryRevision: registryRevision,
            descriptorRevision: descriptorRevision,
            schemaDigest: schemaDigest,
            argumentsJSON: argumentsJSON
        )
    }
}
