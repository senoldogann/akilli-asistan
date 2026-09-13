import CoreGraphics
import Foundation

struct ComputerVerificationFrame: @unchecked Sendable {
    let state: ComputerMutationState
    let processID: Int32
    let windowID: UInt32
    let provenance: [String]
    let tainted: Bool
    let confidence: Double
    let image: CGImage
}

struct ComputerVerificationArtifact: @unchecked Sendable {
    let before: ComputerVerificationFrame
    let after: ComputerVerificationFrame
    let uiStable: Bool
}

protocol AgentComputerOutcomeVerifying: Sendable {
    func verify(
        expectation: VerificationExpectation,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> Bool
}

struct ToolVerificationArtifact: @unchecked Sendable {
    let receipt: ToolExecutionReceipt
    let descriptor: ToolDescriptor
    let expectation: VerificationExpectation
    let computer: ComputerVerificationArtifact?
}
