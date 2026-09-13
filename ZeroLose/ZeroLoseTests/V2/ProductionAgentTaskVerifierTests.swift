import CoreGraphics
import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class ProductionAgentTaskVerifierTests: XCTestCase {
    func testBareReceiptIsRejected() async {
        let verifier = ProductionAgentTaskVerifier()
        let result = await verifier.verify(
            task: readTask(),
            executionResult: .toolReceipt(readReceipt())
        )
        assertRejected(result)
    }

    func testValidReadResultProducesBoundedEvidenceWithoutRawText() async {
        let verifier = ProductionAgentTaskVerifier()
        let secret = "raw-result-must-not-be-copied"
        let receipt = readReceipt(resultJSON: Data(#"{"text":"raw-result-must-not-be-copied"}"#.utf8))
        let artifact = ToolVerificationArtifact(
            receipt: receipt,
            descriptor: readDescriptor(),
            expectation: .readResult,
            computer: nil
        )

        let result = await verifier.verify(task: readTask(), executionResult: .toolVerification(artifact))

        guard case .verified(let evidence) = result else {
            XCTFail("Expected verified read result")
            return
        }
        XCTAssertFalse(evidence.summary.contains(secret))
        XCTAssertEqual(evidence.tainted, false)
        XCTAssertTrue(evidence.provenance.contains("read-result"))
    }

    func testUnknownVerificationContractIsRejected() async {
        var descriptor = readDescriptor(contract: "unknown-contract")
        descriptor = ToolDescriptor(
            id: descriptor.id,
            providerID: descriptor.providerID,
            provenance: descriptor.provenance,
            descriptorRevision: descriptor.descriptorRevision,
            schemaDigest: descriptor.schemaDigest,
            inputSchemaJSON: descriptor.inputSchemaJSON,
            outputSchemaJSON: descriptor.outputSchemaJSON,
            effectClass: descriptor.effectClass,
            declaredRisk: descriptor.declaredRisk,
            requiredCredentialScopes: descriptor.requiredCredentialScopes,
            idempotency: descriptor.idempotency,
            concurrencyClass: descriptor.concurrencyClass,
            verificationContract: VerificationContract(kind: "unknown-contract"),
            enabled: descriptor.enabled
        )
        let artifact = ToolVerificationArtifact(
            receipt: readReceipt(),
            descriptor: descriptor,
            expectation: .readResult,
            computer: nil
        )
        let result = await ProductionAgentTaskVerifier().verify(
            task: readTask(),
            executionResult: .toolVerification(artifact)
        )
        assertRejected(result)
    }

    func testComputerVerificationRejectsMissingArtifact() async {
        let artifact = ToolVerificationArtifact(
            receipt: computerReceipt(),
            descriptor: computerDescriptor(),
            expectation: .computerViewportChange,
            computer: nil
        )
        let result = await ProductionAgentTaskVerifier().verify(
            task: computerTask(),
            executionResult: .toolVerification(artifact)
        )
        assertRejected(result)
    }

    func testComputerVerificationRejectsNonMonotonicState() async {
        let image = makeImage(changed: false)
        let artifact = computerArtifact(
            before: frame(version: 2, observationID: "before", image: image),
            after: frame(version: 2, observationID: "after", image: makeImage(changed: true))
        )
        assertRejected(await ProductionAgentTaskVerifier().verify(
            task: computerTask(), executionResult: .toolVerification(artifact)
        ))
    }

    func testComputerVerificationRejectsChangedWindowIdentity() async {
        let artifact = computerArtifact(
            before: frame(version: 1, observationID: "before", windowID: 10, image: makeImage(changed: false)),
            after: frame(version: 2, observationID: "after", windowID: 11, image: makeImage(changed: true))
        )
        assertRejected(await ProductionAgentTaskVerifier().verify(
            task: computerTask(), executionResult: .toolVerification(artifact)
        ))
    }

    func testComputerVerificationRejectsNoVisibleEffect() async {
        let image = makeImage(changed: false)
        let artifact = computerArtifact(
            before: frame(version: 1, observationID: "before", image: image),
            after: frame(version: 2, observationID: "after", image: image)
        )
        assertRejected(await ProductionAgentTaskVerifier().verify(
            task: computerTask(), executionResult: .toolVerification(artifact)
        ))
    }

    func testComputerNavigationRejectsUnstableUI() async {
        let artifact = computerArtifact(
            expectation: .computerNavigation,
            uiStable: false,
            before: frame(version: 1, observationID: "before", image: makeImage(changed: false)),
            after: frame(version: 2, observationID: "after", image: makeImage(changed: true))
        )
        assertRejected(await ProductionAgentTaskVerifier().verify(
            task: computerTask(expectation: .computerNavigation),
            executionResult: .toolVerification(artifact)
        ))
    }

    func testVerifiedAnswerMutationProducesEvidence() async {
        let artifact = computerArtifact(
            expectation: .computerAnswerMutation,
            before: frame(version: 1, observationID: "before", image: makeSolidImage(gray: 0.40)),
            after: frame(version: 2, observationID: "after", image: makeSolidImage(gray: 0.44))
        )
        assertVerified(await ProductionAgentTaskVerifier().verify(
            task: computerTask(expectation: .computerAnswerMutation),
            executionResult: .toolVerification(artifact)
        ))
    }

    func testVerifiedViewportChangeProducesEvidence() async {
        let artifact = computerArtifact(
            before: frame(version: 1, observationID: "before", image: makeImage(changed: false)),
            after: frame(version: 2, observationID: "after", image: makeImage(changed: true))
        )
        assertVerified(await ProductionAgentTaskVerifier().verify(
            task: computerTask(), executionResult: .toolVerification(artifact)
        ))
    }

    func testVerifiedNavigationProducesEvidence() async {
        let artifact = computerArtifact(
            expectation: .computerNavigation,
            before: frame(version: 1, observationID: "before", image: makeSolidImage(gray: 0.10)),
            after: frame(version: 2, observationID: "after", image: makeSolidImage(gray: 0.90))
        )
        assertVerified(await ProductionAgentTaskVerifier().verify(
            task: computerTask(expectation: .computerNavigation),
            executionResult: .toolVerification(artifact)
        ))
    }

    private func readTask() -> TaskNode {
        TaskNode(
            id: TaskID(rawValue: "read-1"),
            title: "Read status",
            lifecycle: .running,
            concurrencyClass: .read,
            plannedInvocation: PlannedToolInvocation(
                toolID: ToolID(rawValue: "builtin.system_status"),
                argumentsJSON: Data("{}".utf8),
                verificationExpectation: .readResult
            )
        )
    }

    private func computerTask(
        expectation: VerificationExpectation = .computerViewportChange
    ) -> TaskNode {
        let toolID = computerToolID(for: expectation)
        return TaskNode(
            id: TaskID(rawValue: "computer-1"),
            title: "Verify computer outcome",
            lifecycle: .running,
            concurrencyClass: .mutation,
            plannedInvocation: PlannedToolInvocation(
                toolID: toolID,
                argumentsJSON: Data("{}".utf8),
                verificationExpectation: expectation
            )
        )
    }

    private func readDescriptor(contract: String = "read-result") -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: "builtin.system_status"),
            providerID: "builtin",
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:read",
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: [],
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: contract),
            enabled: true
        )
    }

    private func computerDescriptor(
        expectation: VerificationExpectation = .computerViewportChange
    ) -> ToolDescriptor {
        ToolDescriptor(
            id: computerToolID(for: expectation),
            providerID: "computer",
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:scroll",
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: nil,
            effectClass: .reversibleLocalMutation,
            declaredRisk: .reversibleLocalMutation,
            requiredCredentialScopes: [],
            idempotency: .logicalOperationKeyRequired,
            concurrencyClass: .mutation,
            verificationContract: VerificationContract(kind: "fresh-computer-observation"),
            enabled: true
        )
    }

    private func readReceipt(resultJSON: Data = Data(#"{"text":"ok"}"#.utf8)) -> ToolExecutionReceipt {
        ToolExecutionReceipt(
            invocationID: InvocationID(rawValue: "read-inv"),
            toolID: ToolID(rawValue: "builtin.system_status"),
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            providerReference: nil,
            resultProvenance: "builtin:system_status",
            resultJSON: resultJSON,
            resultTainted: false
        )
    }

    private func computerReceipt(
        expectation: VerificationExpectation = .computerViewportChange
    ) -> ToolExecutionReceipt {
        ToolExecutionReceipt(
            invocationID: InvocationID(rawValue: "computer-inv"),
            toolID: computerToolID(for: expectation),
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            providerReference: nil,
            resultProvenance: "computer:macos",
            resultJSON: nil,
            resultTainted: false
        )
    }

    private func computerArtifact(
        expectation: VerificationExpectation = .computerViewportChange,
        uiStable: Bool = true,
        before: ComputerVerificationFrame,
        after: ComputerVerificationFrame
    ) -> ToolVerificationArtifact {
        ToolVerificationArtifact(
            receipt: computerReceipt(expectation: expectation),
            descriptor: computerDescriptor(expectation: expectation),
            expectation: expectation,
            computer: ComputerVerificationArtifact(before: before, after: after, uiStable: uiStable)
        )
    }

    private func computerToolID(for expectation: VerificationExpectation) -> ToolID {
        switch expectation {
        case .computerAnswerMutation:
            return ToolID(rawValue: "computer.keyboard.type")
        case .computerNavigation:
            return ToolID(rawValue: "computer.pointer.click")
        case .computerViewportChange:
            return ToolID(rawValue: "computer.scroll")
        case .computerNone:
            return ToolID(rawValue: "computer.wait")
        case .readResult:
            return ToolID(rawValue: "builtin.system_status")
        }
    }

    private func frame(
        version: UInt64,
        observationID: String,
        windowID: UInt32 = 10,
        image: CGImage
    ) -> ComputerVerificationFrame {
        ComputerVerificationFrame(
            state: ComputerMutationState(stateVersion: version, observationID: observationID),
            processID: 42,
            windowID: windowID,
            provenance: ["test:screen", "test:accessibility"],
            tainted: false,
            confidence: 1,
            image: image
        )
    }

    private func makeImage(changed: Bool) -> CGImage {
        let width = 100
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if changed {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 20, y: 0, width: 5, height: 100))
        }
        return context.makeImage()!
    }

    private func makeSolidImage(gray: CGFloat) -> CGImage {
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

    private func assertRejected(
        _ result: TaskVerificationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected = result else {
            XCTFail("Expected rejection, got \(result)", file: file, line: line)
            return
        }
    }

    private func assertVerified(
        _ result: TaskVerificationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .verified(let evidence) = result else {
            XCTFail("Expected verified evidence, got \(result)", file: file, line: line)
            return
        }
        XCTAssertFalse(evidence.summary.isEmpty, file: file, line: line)
        XCTAssertFalse(evidence.provenance.isEmpty, file: file, line: line)
    }
}
