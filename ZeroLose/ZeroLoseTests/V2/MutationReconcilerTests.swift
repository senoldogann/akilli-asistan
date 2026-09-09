import Foundation
import XCTest
@testable import ZeroLose

final class MutationReconcilerTests: XCTestCase {
    func testUnknownHighRiskMutationIsNotBlindlyRetried() async {
        let reconciler = MutationReconciler(policy: .failClosedForUnknownHighRisk)
        let record = ExternalMutationRecord(
            logicalOperationID: "operation-1",
            idempotencyKey: "idempotency-1",
            invocationID: InvocationID(rawValue: "invocation-1"),
            attempt: 1,
            risk: .highImpactExternalMutation,
            receipt: nil,
            verification: nil,
            externalReference: nil,
            externalState: .unknown
        )

        let decision = await reconciler.decide(record: record)

        XCTAssertEqual(decision, .requiresManualResolution)
    }

    func testJournalPersistsReconciliationEvidence() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let journal = try ExternalMutationJournal(databaseURL: databaseURL)
        let record = ExternalMutationRecord(
            logicalOperationID: "operation-1",
            idempotencyKey: "idempotency-1",
            invocationID: InvocationID(rawValue: "invocation-1"),
            attempt: 2,
            risk: .externalCommunication,
            receipt: Data("receipt".utf8),
            verification: Data("verified".utf8),
            externalReference: "provider-reference-1",
            externalState: .alreadyApplied
        )

        try await journal.append(record)
        let restored = try await journal.latest(logicalOperationID: "operation-1")

        XCTAssertEqual(restored, record)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zerolose-v2-mutations-\(UUID().uuidString).sqlite")
    }
}
