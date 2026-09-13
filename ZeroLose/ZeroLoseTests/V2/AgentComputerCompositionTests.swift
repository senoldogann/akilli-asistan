import ComputerAgentMacOS
import ExamPilotCore
import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class AgentComputerCompositionTests: XCTestCase {
    func testReadyCompositionAddsOnlySupportedComputerMutationToolsAndKeepsBaseCapabilities() {
        let readOnlyProvider = CompositionReadOnlyProvider()
        let readOnlyDescriptor = makeReadOnlyDescriptor()
        let composition = AgentComputerToolComposition.make(
            baseProviders: [readOnlyProvider],
            baseDescriptors: [readOnlyDescriptor],
            observationSourceProvider: CompositionObservationSourceProvider(),
            shouldStop: { false }
        )

        XCTAssertEqual(
            Set(composition.providers.map(\.providerID)),
            Set(["composition-readonly", "computer"])
        )
        XCTAssertEqual(
            Set(composition.descriptors.map { $0.id.rawValue }),
            Set([
                "composition.readonly",
                "computer.pointer.click",
                "computer.keyboard.type",
                "computer.keyboard.press",
                "computer.scroll",
                "computer.wait",
            ])
        )
        XCTAssertNotNil(composition.observationProvider)
    }

    func testUnavailableObservationReadinessOmitsComputerMutationToolsButKeepsReadOnlyCapabilities() {
        let readOnlyProvider = CompositionReadOnlyProvider()
        let readOnlyDescriptor = makeReadOnlyDescriptor()
        let composition = AgentComputerToolComposition.make(
            baseProviders: [readOnlyProvider],
            baseDescriptors: [readOnlyDescriptor],
            observationSourceProvider: nil,
            shouldStop: { false }
        )

        XCTAssertEqual(composition.providers.map(\.providerID), ["composition-readonly"])
        XCTAssertEqual(composition.descriptors.map { $0.id.rawValue }, ["composition.readonly"])
        XCTAssertNil(composition.observationProvider)
    }

    func testProductionCompositionExposesSharedObservationAuthority() async throws {
        let composition = AgentComputerToolComposition.make(
            baseProviders: [CompositionReadOnlyProvider()],
            baseDescriptors: [makeReadOnlyDescriptor()],
            observationSourceProvider: CompositionObservationSourceProvider(),
            shouldStop: { false }
        )

        let provider = try XCTUnwrap(composition.observationProvider)
        let refreshed = try await provider.refreshComputerMutationState()
        let current = try await provider.currentComputerMutationState()

        XCTAssertEqual(current, refreshed)
        let metadata = await provider.latestPresentationMetadata()
        XCTAssertEqual(metadata?.stateVersion, refreshed.stateVersion)
    }

    func testRegistryPolicyComputerProviderAndMutationAdapterExecuteApprovedClick() async throws {
        let harness = try await makeHarness(authorityMode: .autonomous, enabled: true)

        let receipt = try await harness.fabric.execute(harness.invocation)

        let events = await harness.driver.events
        XCTAssertEqual(events, ["click:12.5:24.5"])
        XCTAssertEqual(receipt.toolID.rawValue, "computer.pointer.click")
        XCTAssertEqual(receipt.providerReference, "macos-native-input")
    }

    func testApprovalRequiredPolicyStopsBeforePhysicalInput() async throws {
        let harness = try await makeHarness(authorityMode: .manual, enabled: true)

        do {
            _ = try await harness.fabric.execute(harness.invocation)
            XCTFail("Expected manual authority to require approval")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .policyDenied(.approvalRequired))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await harness.driver.events
        XCTAssertTrue(events.isEmpty)
    }

    func testHardPolicyDenialStopsBeforePhysicalInput() async throws {
        let harness = try await makeHarness(
            authorityMode: .autonomous,
            enabled: true,
            effectClass: .irreversible,
            declaredRisk: .irreversible
        )

        do {
            _ = try await harness.fabric.execute(harness.invocation)
            XCTFail("Expected hard policy denial")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .policyDenied(.hardPolicyDenied))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await harness.driver.events
        XCTAssertTrue(events.isEmpty)
    }

    func testDisabledDescriptorStopsBeforeComputerMutationAdapter() async throws {
        let harness = try await makeHarness(authorityMode: .autonomous, enabled: false)

        do {
            _ = try await harness.fabric.execute(harness.invocation)
            XCTFail("Expected disabled descriptor to fail before provider execution")
        } catch let error as ToolFabricError {
            XCTAssertEqual(error, .unknownTool(ToolID(rawValue: "computer.pointer.click")))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await harness.driver.events
        XCTAssertTrue(events.isEmpty)
    }

    private func makeHarness(
        authorityMode: AuthorityMode,
        enabled: Bool,
        effectClass: EffectClass? = nil,
        declaredRisk: RiskLevel? = nil
    ) async throws -> CompositionHarness {
        let registry = ToolRegistry()
        let descriptor = copy(
            try XCTUnwrap(
                V2ComputerToolCatalog.descriptors.first {
                    $0.id.rawValue == "computer.pointer.click"
                }
            ),
            enabled: enabled,
            effectClass: effectClass,
            declaredRisk: declaredRisk
        )
        await registry.register(descriptor)

        let state = ComputerMutationState(stateVersion: 7, observationID: "obs-7")
        let driver = CompositionRecordingInputDriver()
        let adapter = MacOSComputerMutationAdapter(
            inputDriver: driver,
            stateProvider: CompositionFixedMutationStateProvider(state: state)
        )
        let provider = ComputerToolProvider(gateway: adapter)
        let fabric = ToolFabric(
            registry: registry,
            policy: DefaultPolicyKernel(),
            credentialBroker: InMemoryCredentialBroker(),
            providers: [provider],
            authorityMode: authorityMode
        )
        let mapping = try ComputerActionToolMapper().map(
            .click(x: 12.5, y: 24.5),
            state: state
        )
        let snapshot = await registry.snapshot()
        let registered = try XCTUnwrap(snapshot.descriptors[mapping.toolID])
        let invocation = ToolInvocation(
            invocationID: InvocationID(rawValue: "task7-computer-click"),
            toolID: mapping.toolID,
            registryRevision: snapshot.revision,
            descriptorRevision: registered.descriptorRevision,
            schemaDigest: registered.schemaDigest,
            argumentsJSON: mapping.argumentsJSON,
            logicalOperationKey: "task7-computer-click"
        )

        return CompositionHarness(
            fabric: fabric,
            invocation: invocation,
            driver: driver
        )
    }

    private func copy(
        _ descriptor: ToolDescriptor,
        enabled: Bool,
        effectClass: EffectClass?,
        declaredRisk: RiskLevel?
    ) -> ToolDescriptor {
        ToolDescriptor(
            id: descriptor.id,
            providerID: descriptor.providerID,
            provenance: descriptor.provenance,
            descriptorRevision: descriptor.descriptorRevision,
            schemaDigest: descriptor.schemaDigest,
            inputSchemaJSON: descriptor.inputSchemaJSON,
            outputSchemaJSON: descriptor.outputSchemaJSON,
            effectClass: effectClass ?? descriptor.effectClass,
            declaredRisk: declaredRisk ?? descriptor.declaredRisk,
            requiredCredentialScopes: descriptor.requiredCredentialScopes,
            idempotency: descriptor.idempotency,
            concurrencyClass: descriptor.concurrencyClass,
            verificationContract: descriptor.verificationContract,
            enabled: enabled
        )
    }

    private func makeReadOnlyDescriptor() -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: "composition.readonly"),
            providerID: "composition-readonly",
            provenance: "test:composition-readonly",
            descriptorRevision: 1,
            schemaDigest: "sha256:composition-readonly",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#.utf8
            ),
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

private struct CompositionHarness {
    let fabric: ToolFabric
    let invocation: ToolInvocation
    let driver: CompositionRecordingInputDriver
}

private struct CompositionReadOnlyProvider: ToolProviding {
    let providerID = "composition-readonly"

    func execute(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        let now = Date()
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: now,
            completedAt: now,
            providerReference: "composition-readonly"
        )
    }
}

private struct CompositionObservationSourceProvider: MacOSComputerObservationSourceProviding {
    func currentObservationSources() async throws -> MacOSComputerObservationSources {
        MacOSComputerObservationSources(
            screen: ComputerObservationSource(
                processID: 100,
                windowID: 200,
                provenance: "screen"
            ),
            accessibility: ComputerObservationSource(
                processID: 100,
                windowID: 200,
                provenance: "accessibility"
            )
        )
    }
}

private final class CompositionRecordingInputDriver: InputDriving, @unchecked Sendable {
    private let log = CompositionInputLog()

    var events: [String] {
        get async { await log.events }
    }

    func moveAndClick(x: Double, y: Double) async throws {
        await log.append("click:\(x):\(y)")
    }

    func typeText(_ text: String) async throws {
        await log.append("type:\(text)")
    }

    func pressKey(_ key: String) async throws {
        await log.append("key:\(key)")
    }

    func scroll(amount: Int) async throws {
        await log.append("scroll:\(amount)")
    }

    func wait(milliseconds: Int) async throws {
        await log.append("wait:\(milliseconds)")
    }
}

private actor CompositionInputLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor CompositionFixedMutationStateProvider: ComputerMutationStateProviding {
    private let state: ComputerMutationState

    init(state: ComputerMutationState) {
        self.state = state
    }

    func currentComputerMutationState() async throws -> ComputerMutationState {
        state
    }
}
