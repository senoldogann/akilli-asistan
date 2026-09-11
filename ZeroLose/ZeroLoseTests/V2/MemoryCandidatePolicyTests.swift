import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class MemoryCandidatePolicyTests: XCTestCase {
    func testAssistantOutputIsNotAutomaticallyMemorable() {
        let policy = MemoryCandidatePolicy()

        let candidate = policy.candidate(
            source: .assistantOutput,
            content: "User likes Rust",
            provenance: .derived
        )

        XCTAssertNil(candidate)
    }

    func testExplicitUserFactCanBecomeCandidate() throws {
        let candidate = try XCTUnwrap(
            MemoryCandidatePolicy().candidate(
                source: .explicitUserFact,
                content: "Prefer concise build logs",
                provenance: .user,
                scope: .user,
                confidence: 0.9,
                tainted: false
            )
        )

        XCTAssertEqual(candidate.content, "Prefer concise build logs")
        XCTAssertEqual(candidate.scope, .user)
        XCTAssertEqual(candidate.provenance, .user)
        XCTAssertEqual(candidate.confidence, 0.9)
        XCTAssertFalse(candidate.tainted)
        XCTAssertNil(candidate.sourceEvidenceID)
    }

    func testExplicitPinCanBecomeCandidateWithoutInference() throws {
        let candidate = try XCTUnwrap(
            MemoryCandidatePolicy().candidate(
                source: .explicitPin,
                content: "Pin this project constraint",
                provenance: .user,
                scope: .workspace("repo-1")
            )
        )

        XCTAssertEqual(candidate.scope, .workspace("repo-1"))
        XCTAssertEqual(candidate.content, "Pin this project constraint")
    }

    func testCredentialSensitivityAndSensitiveStructuredMetadataAreRejected() {
        let policy = MemoryCandidatePolicy()

        XCTAssertNil(
            policy.candidate(
                source: .explicitUserFact,
                content: "opaque secret",
                provenance: .user,
                sensitivity: .credentialMaterial
            )
        )
        XCTAssertNil(
            policy.candidate(
                source: .explicitPin,
                content: "request metadata",
                provenance: .user,
                structuredMetadata: ["Authorization": "Bearer secret"]
            )
        )
        XCTAssertNil(
            policy.candidate(
                source: .explicitPin,
                content: "browser metadata",
                provenance: .user,
                structuredMetadata: ["cookie": "session=secret"]
            )
        )
        XCTAssertNil(
            policy.candidate(
                source: .explicitPin,
                content: "provider metadata",
                provenance: .user,
                structuredMetadata: ["session_id": "provider-session"]
            )
        )
    }

    func testEmptyContentAndTransientToolOutputAreRejected() {
        let policy = MemoryCandidatePolicy()

        XCTAssertNil(
            policy.candidate(
                source: .explicitUserFact,
                content: "  \n\t ",
                provenance: .user
            )
        )
        XCTAssertNil(
            policy.candidate(
                source: .transientToolOutput,
                content: "temporary tool result",
                provenance: .toolResult
            )
        )
    }

    func testVerifiedTaskFactRequiresRuntimeEvidenceAndEvidenceID() throws {
        let policy = MemoryCandidatePolicy()

        XCTAssertNil(
            policy.candidate(
                source: .verifiedTaskFact,
                content: "Build passed",
                provenance: .derived,
                sourceEvidenceID: "evidence-1"
            )
        )
        XCTAssertNil(
            policy.candidate(
                source: .verifiedTaskFact,
                content: "Build passed",
                provenance: .runtimeEvidence,
                sourceEvidenceID: nil
            )
        )

        let candidate = try XCTUnwrap(
            policy.candidate(
                source: .verifiedTaskFact,
                content: "Build passed",
                provenance: .runtimeEvidence,
                scope: .goal(GoalID(rawValue: "goal-1")),
                confidence: 2,
                tainted: true,
                sourceEvidenceID: "evidence-1"
            )
        )

        XCTAssertEqual(candidate.provenance, .runtimeEvidence)
        XCTAssertEqual(candidate.sourceEvidenceID, "evidence-1")
        XCTAssertEqual(candidate.confidence, 1)
        XCTAssertTrue(candidate.tainted)
    }
}
