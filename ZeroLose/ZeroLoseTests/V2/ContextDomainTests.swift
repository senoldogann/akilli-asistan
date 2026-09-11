import Foundation
import XCTest
@testable import ZeroLose

final class ContextDomainTests: XCTestCase {
    func testCredentialMaterialCannotBecomeContextItem() {
        let provenance = ContextProvenance(
            sourceID: "runtime:credential",
            kind: .runtimeEvidence,
            timestamp: nil,
            tainted: false,
            sensitivity: .credentialMaterial
        )

        XCTAssertThrowsError(
            try ContextItem.validated(
                content: "opaque-secret-material",
                provenance: provenance,
                mandatory: false
            )
        ) { error in
            XCTAssertEqual(error as? ContextValidationError, .credentialMaterialRejected)
        }
    }

    func testPrivateContentMayRemainContextWithoutBecomingCredentialMaterial() throws {
        let item = try ContextItem.validated(
            content: "User-provided project note",
            provenance: .init(
                sourceID: "attachment:a1",
                kind: .attachment,
                timestamp: Date(timeIntervalSince1970: 10),
                tainted: false,
                sensitivity: .privateContent
            ),
            mandatory: false
        )

        XCTAssertEqual(item.provenance.sensitivity, .privateContent)
        XCTAssertEqual(item.content, "User-provided project note")
    }

    func testEmptyOrWhitespaceContentIsRejected() {
        let provenance = ContextProvenance(
            sourceID: "conversation:m1",
            kind: .conversation,
            timestamp: nil,
            tainted: false,
            sensitivity: .normal
        )

        XCTAssertThrowsError(
            try ContextItem.validated(
                content: "  \n\t ",
                provenance: provenance,
                mandatory: false
            )
        ) { error in
            XCTAssertEqual(error as? ContextValidationError, .emptyContent)
        }
    }

    func testSourceScoreIsClampedAndIdentifierIsStable() throws {
        let provenance = ContextProvenance(
            sourceID: "memory:m1",
            kind: .memory,
            timestamp: Date(timeIntervalSince1970: 20),
            tainted: true,
            sensitivity: .normal
        )
        let first = try ContextItem.validated(
            content: "  Prefer Swift concurrency.  ",
            provenance: provenance,
            mandatory: false,
            sourceScore: 3
        )
        let second = try ContextItem.validated(
            content: "Prefer Swift concurrency.",
            provenance: provenance,
            mandatory: false,
            sourceScore: 3
        )

        XCTAssertEqual(first.sourceScore, 1)
        XCTAssertEqual(first.content, "Prefer Swift concurrency.")
        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(first.provenance.tainted)
    }

    func testTokenizerNormalizesCasePunctuationAndDuplicateTokens() {
        XCTAssertEqual(ContextScorer.tokens("SwiftUI, swift-ui SWIFTUI"), ["swiftui"])
    }

    func testTokenizerOrderIsDeterministicAndScoringUsesQueryOverlap() {
        XCTAssertEqual(ContextScorer.tokens("Beta alpha beta Gamma"), ["beta", "alpha", "gamma"])

        let scorer = ContextScorer()
        XCTAssertEqual(
            scorer.lexicalOverlap(query: "open project now", candidate: "Project open details"),
            2.0 / 3.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(scorer.lexicalOverlap(query: "", candidate: "anything"), 0)
    }
}
