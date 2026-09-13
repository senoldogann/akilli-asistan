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

    func testStaleDescriptorRevisionNeverReachesProvider() async {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        await registry.register(.test(id: "builtin.echo"))
        let fabric = makeFabric(registry: registry, provider: provider)
        var didThrow = false

        do {
            _ = try await fabric.execute(
                .test(
                    toolID: "builtin.echo",
                    registryRevision: 1,
                    descriptorRevision: 0
                )
            )
        } catch {
            didThrow = true
        }

        let executionCount = await provider.executionCount
        XCTAssertTrue(didThrow, "Expected stale descriptor revision to fail closed")
        XCTAssertEqual(executionCount, 0)
    }

    func testSchemaDigestMismatchNeverReachesProvider() async {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        await registry.register(.test(id: "builtin.echo"))
        let fabric = makeFabric(registry: registry, provider: provider)
        var didThrow = false

        do {
            _ = try await fabric.execute(
                .test(
                    toolID: "builtin.echo",
                    registryRevision: 1,
                    schemaDigest: "sha256:stale"
                )
            )
        } catch {
            didThrow = true
        }

        let executionCount = await provider.executionCount
        XCTAssertTrue(didThrow, "Expected schema digest mismatch to fail closed")
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

    func testLogicalOperationKeyRequiredFailsClosedBeforeProviderExecution() async {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        await registry.register(
            .test(
                id: "builtin.send",
                effectClass: .externalCommunication,
                declaredRisk: .externalCommunication,
                idempotency: .logicalOperationKeyRequired
            )
        )
        let fabric = makeFabric(
            registry: registry,
            provider: provider,
            authorityMode: .autonomous
        )

        do {
            _ = try await fabric.execute(.test(toolID: "builtin.send", registryRevision: 1))
            XCTFail("Expected missing logical operation key to fail closed")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .missingLogicalOperationKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let executionCount = await provider.executionCount
        XCTAssertEqual(executionCount, 0)
    }

    func testLogicalOperationKeyRequiredReachesProviderWhenPresent() async throws {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        await registry.register(
            .test(
                id: "builtin.send",
                effectClass: .externalCommunication,
                declaredRisk: .externalCommunication,
                idempotency: .logicalOperationKeyRequired
            )
        )
        let fabric = makeFabric(
            registry: registry,
            provider: provider,
            authorityMode: .autonomous
        )

        _ = try await fabric.execute(
            .test(
                toolID: "builtin.send",
                registryRevision: 1,
                logicalOperationKey: "operation-123"
            )
        )

        let executionCount = await provider.executionCount
        let receivedKey = await provider.receivedLogicalOperationKey
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(receivedKey, "operation-123")
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

    func testIssuedCredentialHandleDoesNotOutliveSuccessfulInvocation() async throws {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        let broker = RecordingCredentialBroker(availableScopes: ["scope.secure"])
        await registry.register(
            .test(id: "builtin.secure", requiredCredentialScopes: ["scope.secure"])
        )
        let fabric = makeFabric(registry: registry, provider: provider, broker: broker)

        _ = try await fabric.execute(.test(toolID: "builtin.secure", registryRevision: 1))

        let issueCount = await broker.issueCount
        let discardedCount = await broker.discardedHandleCount
        let validCount = await broker.validHandleCount
        let availability = await broker.availability(
            for: CredentialScope(rawValue: "scope.secure")
        )

        XCTAssertEqual(issueCount, 1)
        XCTAssertEqual(
            discardedCount,
            1,
            "A credential handle must be invalidated when the invocation that received it completes"
        )
        XCTAssertEqual(validCount, 0, "No credential handle may stay valid after its invocation ends")
        XCTAssertTrue(
            availability.available,
            "Discarding an invocation handle must not revoke the underlying scope"
        )
    }

    func testIssuedCredentialHandleIsDiscardedWhenInvocationFails() async throws {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        await provider.setExecutionError(ToolFabricTestError.executionFailed)
        let broker = RecordingCredentialBroker(availableScopes: ["scope.secure"])
        await registry.register(
            .test(id: "builtin.secure", requiredCredentialScopes: ["scope.secure"])
        )
        let fabric = makeFabric(registry: registry, provider: provider, broker: broker)
        var didThrow = false

        do {
            _ = try await fabric.execute(.test(toolID: "builtin.secure", registryRevision: 1))
        } catch {
            didThrow = true
        }

        let discardedCount = await broker.discardedHandleCount
        let validCount = await broker.validHandleCount
        XCTAssertTrue(didThrow, "Expected the provider failure to propagate")
        XCTAssertEqual(
            discardedCount,
            1,
            "Credential handles must be discarded even when the invocation throws"
        )
        XCTAssertEqual(validCount, 0)
    }

    func testCredentialHandleInventoryStaysBoundedAcrossInvocations() async throws {
        let registry = ToolRegistry()
        let provider = RecordingToolProvider(providerID: "builtin")
        let broker = InMemoryCredentialBroker(scopes: ["scope.secure"])
        await registry.register(
            .test(id: "builtin.secure", requiredCredentialScopes: ["scope.secure"])
        )
        let fabric = makeFabric(registry: registry, provider: provider, broker: broker)

        for _ in 0..<5 {
            _ = try await fabric.execute(.test(toolID: "builtin.secure", registryRevision: 1))
        }

        let outstanding = await broker.outstandingHandleCount
        let availability = await broker.availability(
            for: CredentialScope(rawValue: "scope.secure")
        )
        XCTAssertEqual(
            outstanding,
            0,
            "Completed invocations must not accumulate live credential handles"
        )
        XCTAssertTrue(availability.available, "Repeated invocations must keep working")
    }

    private func makeFabric(
        registry: ToolRegistry,
        provider: RecordingToolProvider,
        broker: any CredentialBrokering = RecordingCredentialBroker(availableScopes: []),
        authorityMode: AuthorityMode = .auto
    ) -> ToolFabric {
        ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: broker,
            providers: [provider],
            authorityMode: authorityMode
        )
    }
}

private enum ToolFabricTestError: Error {
    case executionFailed
}

private actor RecordingToolProvider: ToolProviding {
    nonisolated let providerID: String
    private(set) var executionCount = 0
    private(set) var receivedCredentialScopes: Set<String> = []
    private(set) var receivedLogicalOperationKey: String?
    private var executionError: Error?

    init(providerID: String) {
        self.providerID = providerID
    }

    func setExecutionError(_ error: Error?) {
        executionError = error
    }

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        executionCount += 1
        if let executionError {
            throw executionError
        }
        receivedCredentialScopes = Set(credentialHandles.map(\.scope.rawValue))
        receivedLogicalOperationKey = invocation.logicalOperationKey
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
    private var availableScopes: Set<CredentialScope>
    private(set) var issueCount = 0
    private(set) var discardedHandleCount = 0
    private var liveHandles: Set<CredentialHandle> = []

    var validHandleCount: Int { liveHandles.count }

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
        let handle = CredentialHandle(scope: scope)
        liveHandles.insert(handle)
        return handle
    }

    func revoke(scope: CredentialScope) {
        availableScopes.remove(scope)
        liveHandles = Set(liveHandles.filter { $0.scope != scope })
    }

    func discardHandles(_ handles: [CredentialHandle]) {
        discardedHandleCount += handles.count
        liveHandles.subtract(handles)
    }
}

private extension ToolDescriptor {
    static func test(
        id: String,
        providerID: String = "builtin",
        effectClass: EffectClass = .read,
        declaredRisk: RiskLevel = .readOnly,
        requiredCredentialScopes: Set<String> = [],
        idempotency: IdempotencySemantics = .none
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
            requiredCredentialScopes: requiredCredentialScopes,
            idempotency: idempotency,
            concurrencyClass: effectClass == .read ? .read : .mutation,
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
        argumentsJSON: Data = Data("{}".utf8),
        logicalOperationKey: String? = nil
    ) -> Self {
        Self(
            invocationID: InvocationID(rawValue: "invocation-1"),
            toolID: ToolID(rawValue: toolID),
            registryRevision: registryRevision,
            descriptorRevision: descriptorRevision,
            schemaDigest: schemaDigest,
            argumentsJSON: argumentsJSON,
            logicalOperationKey: logicalOperationKey
        )
    }
}
