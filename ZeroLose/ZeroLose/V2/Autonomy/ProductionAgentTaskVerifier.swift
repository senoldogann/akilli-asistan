import Foundation

struct ProductionAgentTaskVerifier: TaskVerifying, @unchecked Sendable {
    private let outcomeVerifier: any AgentComputerOutcomeVerifying

    init(outcomeVerifier: any AgentComputerOutcomeVerifying = ExamPilotAgentComputerOutcomeVerifier()) {
        self.outcomeVerifier = outcomeVerifier
    }

    func verify(
        task: TaskNode,
        executionResult: TaskExecutionResult
    ) async -> TaskVerificationResult {
        switch executionResult {
        case .toolVerification(let artifact):
            return verifyToolArtifact(task: task, artifact: artifact)
        case .modelFinalText, .toolReceipt, .evidence:
            return .rejected(reason: "unsupported verification artifact")
        }
    }

    private func verifyToolArtifact(
        task: TaskNode,
        artifact: ToolVerificationArtifact
    ) -> TaskVerificationResult {
        guard artifact.descriptor.enabled,
              artifact.receipt.toolID == artifact.descriptor.id,
              let planned = task.plannedInvocation,
              planned.toolID == artifact.descriptor.id,
              planned.verificationExpectation == artifact.expectation,
              artifact.expectation.isCompatible(
                toolID: artifact.descriptor.id,
                verificationContract: artifact.descriptor.verificationContract
              ) else {
            return .rejected(reason: "verification artifact does not match planned invocation")
        }

        switch artifact.descriptor.verificationContract.kind {
        case "read-result":
            return verifyReadResult(artifact)
        case "fresh-computer-observation":
            return verifyComputerResult(artifact)
        default:
            return .rejected(reason: "unsupported verification contract")
        }
    }

    private func verifyReadResult(
        _ artifact: ToolVerificationArtifact
    ) -> TaskVerificationResult {
        guard artifact.expectation == .readResult,
              let provenance = artifact.receipt.resultProvenance?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !provenance.isEmpty,
              let resultJSON = artifact.receipt.resultJSON,
              (try? JSONSerialization.jsonObject(with: resultJSON)) is [String: Any] else {
            return .rejected(reason: "invalid read-result receipt")
        }

        return .verified(
            VerificationEvidence(
                summary: "Verified read result for \(artifact.descriptor.id.rawValue)",
                provenance: "agent-task-verifier:read-result:\(String(provenance.prefix(160)))",
                tainted: artifact.receipt.resultTainted
            )
        )
    }

    private func verifyComputerResult(
        _ artifact: ToolVerificationArtifact
    ) -> TaskVerificationResult {
        guard let computer = artifact.computer else {
            return .rejected(reason: "computer verification artifact unavailable")
        }

        let before = computer.before
        let after = computer.after
        guard before.state.stateVersion < after.state.stateVersion,
              before.state.observationID != after.state.observationID,
              !before.state.observationID.isEmpty,
              !after.state.observationID.isEmpty,
              before.processID == after.processID,
              before.windowID == after.windowID,
              before.confidence.isFinite,
              after.confidence.isFinite,
              before.confidence > 0,
              after.confidence > 0 else {
            return .rejected(reason: "computer verification state is stale or ambiguous")
        }

        guard artifact.expectation != .readResult,
              outcomeVerifier.verify(
                expectation: artifact.expectation,
                before: before.image,
                after: after.image,
                uiStable: computer.uiStable
              ) else {
            return .rejected(reason: "semantic computer outcome not verified")
        }

        let isTainted = artifact.receipt.resultTainted || before.tainted || after.tainted
        return .verified(
            VerificationEvidence(
                summary: "Verified computer outcome: \(artifact.expectation.rawValue)",
                provenance: "agent-task-verifier:computer:\(artifact.expectation.rawValue)",
                tainted: isTainted
            )
        )
    }
}
