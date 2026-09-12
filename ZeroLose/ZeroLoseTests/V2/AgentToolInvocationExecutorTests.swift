import CoreGraphics
import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class AgentToolInvocationExecutorTests: XCTestCase {
    func testReadToolReturnsRichVerificationArtifact() async throws {
        let registry = ToolRegistry()
        let descriptor = makeDescriptor(
            id: "builtin.system_status",
            contract: "read-result",
            concurrencyClass: .read,
            effectClass: .read,
            risk: .readOnly
        )
        await registry.register(descriptor)
        let fabric = RecordingAgentToolFabric(
            resultProvenance: "builtin:system_status",
            resultJSON: Data(#"{"status":"ok"}"#.utf8)
        )
        let executor = AgentToolInvocationExecutor(
            registry: registry,
            toolFabric: fabric,
            mutationExecutionState: AgentMutationExecutionState(),
            settle: {}
        )

        let result = try await executor.execute(
            task: makeTask(
                toolID: descriptor.id.rawValue,
                argumentsJSON: Data("{}".utf8),
                expectation: .readResult,
                concurrencyClass: .read
            ),
            budget: generousBudget()
        )

        guard case .toolVerification(let artifact) = result else {
            return XCTFail("Expected rich verification artifact")
        }
        XCTAssertEqual(artifact.receipt.toolID, descriptor.id)
        XCTAssertEqual(artifact.descriptor.id, descriptor.id)
        XCTAssertEqual(artifact.expectation, .readResult)
        XCTAssertNil(artifact.computer)
        let executionCount = await fabric.executionCount
        XCTAssertEqual(executionCount, 1)
    }

    func testComputerToolRefreshesBeforeExecutionAndAfterExecution() async throws {
        let setup = try await makeComputerSetup()

        let result = try await setup.executor.execute(
            task: makeTask(
                toolID: "computer.scroll",
                argumentsJSON: Data(#"{"amount":400}"#.utf8),
                expectation: .computerViewportChange,
                concurrencyClass: .mutation
            ),
            budget: generousBudget()
        )

        let refreshCount = await setup.stateProvider.refreshCount
        let capturedStateVersions = await setup.capturer.capturedStateVersions
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(capturedStateVersions, [1, 2])
        guard case .toolVerification(let artifact) = result,
              let computer = artifact.computer else {
            return XCTFail("Expected computer verification artifact")
        }
        XCTAssertEqual(computer.before.state.stateVersion, 1)
        XCTAssertEqual(computer.after.state.stateVersion, 2)
    }

    func testComputerToolBindsExactPreActionStateIntoToolFabricInvocation() async throws {
        let setup = try await makeComputerSetup()

        _ = try await setup.executor.execute(
            task: makeTask(
                toolID: "computer.scroll",
                argumentsJSON: Data(#"{"amount":250}"#.utf8),
                expectation: .computerViewportChange,
                concurrencyClass: .mutation
            ),
            budget: generousBudget()
        )

        let invocations = await setup.fabric.invocations
        let invocation = try XCTUnwrap(invocations.first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocation.argumentsJSON) as? [String: Any]
        )
        XCTAssertEqual(object["amount"] as? Int, 250)
        XCTAssertEqual(object["stateVersion"] as? Int, 1)
        XCTAssertEqual(object["observationID"] as? String, "obs-1")
    }

    func testComputerToolCapturesExactPreAndPostMetadata() async throws {
        let setup = try await makeComputerSetup()

        _ = try await setup.executor.execute(
            task: makeTask(
                toolID: "computer.scroll",
                argumentsJSON: Data(#"{"amount":100}"#.utf8),
                expectation: .computerViewportChange,
                concurrencyClass: .mutation
            ),
            budget: generousBudget()
        )

        let metadata = await setup.capturer.capturedMetadata
        XCTAssertEqual(metadata.map(\.observationID), ["obs-1", "obs-2"])
        XCTAssertEqual(metadata.map(\.stateVersion), [1, 2])
        XCTAssertEqual(metadata.map(\.processID), [42, 42])
        XCTAssertEqual(metadata.map(\.windowID), [9, 9])
    }

    func testComputerToolFailsClosedWhenObservationOrCaptureUnavailable() async {
        let registry = ToolRegistry()
        let descriptor = makeDescriptor(
            id: "computer.scroll",
            contract: "fresh-computer-observation",
            concurrencyClass: .mutation,
            effectClass: .reversibleLocalMutation,
            risk: .reversibleLocalMutation
        )
        await registry.register(descriptor)
        let fabric = RecordingAgentToolFabric()
        let executor = AgentToolInvocationExecutor(
            registry: registry,
            toolFabric: fabric,
            mutationExecutionState: AgentMutationExecutionState(),
            computerStateProvider: nil,
            computerCapturer: nil,
            settle: {}
        )

        do {
            _ = try await executor.execute(
                task: makeTask(
                    toolID: "computer.scroll",
                    argumentsJSON: Data(#"{"amount":100}"#.utf8),
                    expectation: .computerViewportChange,
                    concurrencyClass: .mutation
                ),
                budget: generousBudget()
            )
            XCTFail("Expected fail-closed computer verification error")
        } catch {
            let executionCount = await fabric.executionCount
            XCTAssertEqual(executionCount, 0)
        }
    }

    func testComputerToolDoesNotPromotePostStopReceiptToVerificationArtifact() async throws {
        let stop = StopFlag()
        let setup = try await makeComputerSetup(
            onExecute: { stop.stop() },
            shouldStop: { stop.isStopped }
        )

        do {
            _ = try await setup.executor.execute(
                task: makeTask(
                    toolID: "computer.scroll",
                    argumentsJSON: Data(#"{"amount":100}"#.utf8),
                    expectation: .computerViewportChange,
                    concurrencyClass: .mutation
                ),
                budget: generousBudget()
            )
            XCTFail("Expected cancellation after Emergency Stop")
        } catch is CancellationError {
            let executionCount = await setup.fabric.executionCount
            let refreshCount = await setup.stateProvider.refreshCount
            let capturedStateVersions = await setup.capturer.capturedStateVersions
            XCTAssertEqual(executionCount, 1)
            XCTAssertEqual(refreshCount, 1)
            XCTAssertEqual(capturedStateVersions, [1])
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testUnknownVerificationContractFailsBeforeExecution() async {
        let registry = ToolRegistry()
        let descriptor = makeDescriptor(
            id: "builtin.unknown",
            contract: "unknown-contract",
            concurrencyClass: .read,
            effectClass: .read,
            risk: .readOnly
        )
        await registry.register(descriptor)
        let fabric = RecordingAgentToolFabric()
        let executor = AgentToolInvocationExecutor(
            registry: registry,
            toolFabric: fabric,
            mutationExecutionState: AgentMutationExecutionState(),
            settle: {}
        )

        do {
            _ = try await executor.execute(
                task: makeTask(
                    toolID: "builtin.unknown",
                    argumentsJSON: Data("{}".utf8),
                    expectation: .readResult,
                    concurrencyClass: .read
                ),
                budget: generousBudget()
            )
            XCTFail("Expected unsupported verification contract")
        } catch {
            let executionCount = await fabric.executionCount
            XCTAssertEqual(executionCount, 0)
        }
    }

    private func makeComputerSetup(
        onExecute: @escaping @Sendable () -> Void = {},
        shouldStop: @escaping @Sendable () -> Bool = { false }
    ) async throws -> ComputerSetup {
        let registry = ToolRegistry()
        let descriptor = makeDescriptor(
            id: "computer.scroll",
            contract: "fresh-computer-observation",
            concurrencyClass: .mutation,
            effectClass: .reversibleLocalMutation,
            risk: .reversibleLocalMutation
        )
        await registry.register(descriptor)
        let states = [
            ComputerMutationState(stateVersion: 1, observationID: "obs-1"),
            ComputerMutationState(stateVersion: 2, observationID: "obs-2"),
        ]
        let metadata = [
            MacOSComputerObservationPresentationMetadata(
                observationID: "obs-1",
                stateVersion: 1,
                processID: 42,
                windowID: 9,
                provenance: ["test:pre"],
                tainted: false,
                confidence: 1
            ),
            MacOSComputerObservationPresentationMetadata(
                observationID: "obs-2",
                stateVersion: 2,
                processID: 42,
                windowID: 9,
                provenance: ["test:post"],
                tainted: false,
                confidence: 1
            ),
        ]
        let stateProvider = SequencedComputerVerificationStateProvider(
            states: states,
            metadata: metadata
        )
        let capturer = RecordingComputerVerificationCapturer()
        let fabric = RecordingAgentToolFabric(onExecute: onExecute)
        let executor = AgentToolInvocationExecutor(
            registry: registry,
            toolFabric: fabric,
            mutationExecutionState: AgentMutationExecutionState(),
            computerStateProvider: stateProvider,
            computerCapturer: capturer,
            shouldStop: shouldStop,
            settle: {}
        )
        return ComputerSetup(
            executor: executor,
            stateProvider: stateProvider,
            capturer: capturer,
            fabric: fabric
        )
    }

    private func makeTask(
        toolID: String,
        argumentsJSON: Data,
        expectation: VerificationExpectation,
        concurrencyClass: ConcurrencyClass
    ) -> TaskNode {
        TaskNode(
            id: TaskID(rawValue: "task-1"),
            title: "Execute verified tool",
            lifecycle: .ready,
            concurrencyClass: concurrencyClass,
            plannedInvocation: PlannedToolInvocation(
                toolID: ToolID(rawValue: toolID),
                argumentsJSON: argumentsJSON,
                verificationExpectation: expectation
            )
        )
    }

    private func makeDescriptor(
        id: String,
        contract: String,
        concurrencyClass: ToolConcurrencyClass,
        effectClass: EffectClass,
        risk: RiskLevel
    ) -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: id),
            providerID: id.hasPrefix("computer.") ? "computer" : "builtin",
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            outputSchemaJSON: nil,
            effectClass: effectClass,
            declaredRisk: risk,
            requiredCredentialScopes: [],
            idempotency: id.hasPrefix("computer.") ? .logicalOperationKeyRequired : .none,
            concurrencyClass: concurrencyClass,
            verificationContract: VerificationContract(kind: contract),
            enabled: true
        )
    }

    private func generousBudget() -> RuntimeBudget {
        RuntimeBudget(
            limits: RuntimeBudgetLimits(
                maxWallClockSeconds: 300,
                maxModelCalls: 100,
                maxToolCalls: 100,
                maxRecoveryAttempts: 10,
                maxExternalSpend: 1_000,
                maxParallelTasks: 8,
                deadline: nil
            )
        )
    }
}

private struct ComputerSetup {
    let executor: AgentToolInvocationExecutor
    let stateProvider: SequencedComputerVerificationStateProvider
    let capturer: RecordingComputerVerificationCapturer
    let fabric: RecordingAgentToolFabric
}

private actor RecordingAgentToolFabric: ToolFabricExecuting {
    private let resultProvenance: String?
    private let resultJSON: Data?
    private let onExecute: @Sendable () -> Void
    private(set) var invocations: [ToolInvocation] = []

    init(
        resultProvenance: String? = "test:tool",
        resultJSON: Data? = Data(#"{"ok":true}"#.utf8),
        onExecute: @escaping @Sendable () -> Void = {}
    ) {
        self.resultProvenance = resultProvenance
        self.resultJSON = resultJSON
        self.onExecute = onExecute
    }

    var executionCount: Int { invocations.count }

    func execute(_ invocation: ToolInvocation) async throws -> ToolExecutionReceipt {
        invocations.append(invocation)
        onExecute()
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: invocation.toolID,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            providerReference: nil,
            resultProvenance: resultProvenance,
            resultJSON: resultJSON,
            resultTainted: false
        )
    }
}

private actor SequencedComputerVerificationStateProvider: ComputerVerificationStateRefreshing {
    private let states: [ComputerMutationState]
    private let metadataValues: [MacOSComputerObservationPresentationMetadata]
    private var index = 0
    private var currentState: ComputerMutationState?
    private var currentMetadata: MacOSComputerObservationPresentationMetadata?
    private(set) var refreshCount = 0

    init(
        states: [ComputerMutationState],
        metadata: [MacOSComputerObservationPresentationMetadata]
    ) {
        self.states = states
        self.metadataValues = metadata
    }

    func currentComputerMutationState() async throws -> ComputerMutationState {
        guard let currentState else { throw TestExecutorError.unavailable }
        return currentState
    }

    func refreshComputerMutationState() async throws -> ComputerMutationState {
        guard index < states.count, index < metadataValues.count else {
            throw TestExecutorError.unavailable
        }
        let state = states[index]
        currentState = state
        currentMetadata = metadataValues[index]
        index += 1
        refreshCount += 1
        return state
    }

    func latestPresentationMetadata() async -> MacOSComputerObservationPresentationMetadata? {
        currentMetadata
    }
}

private actor RecordingComputerVerificationCapturer: ComputerVerificationCapturing {
    private(set) var capturedMetadata: [MacOSComputerObservationPresentationMetadata] = []

    var capturedStateVersions: [UInt64] {
        capturedMetadata.map(\.stateVersion)
    }

    func capture(
        metadata: MacOSComputerObservationPresentationMetadata
    ) async throws -> ComputerVerificationFrame {
        capturedMetadata.append(metadata)
        return ComputerVerificationFrame(
            state: ComputerMutationState(
                stateVersion: metadata.stateVersion,
                observationID: metadata.observationID
            ),
            processID: metadata.processID,
            windowID: metadata.windowID,
            provenance: metadata.provenance,
            tainted: metadata.tainted,
            confidence: metadata.confidence,
            image: makeImage(gray: metadata.stateVersion == 1 ? 0.1 : 0.9)
        )
    }

    private func makeImage(gray: CGFloat) -> CGImage {
        let width = 16
        let height = 16
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private enum TestExecutorError: Error {
    case unavailable
}
