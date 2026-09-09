import Foundation
import XCTest
@testable import ZeroLose

final class MemoryStoreTests: XCTestCase {
    func testSemanticFactPreservesTaintProvenanceAndScope() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteMemoryStore(databaseURL: databaseURL)
        let memory = SemanticMemoryRecord(
            id: "fact-1",
            scope: .workspace("repo-1"),
            fact: "External documentation describes a capability.",
            confidence: 0.8,
            provenance: .externalDocument,
            tainted: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            confirmedAt: nil,
            invalidatedAt: nil
        )

        try await store.save(.semantic(memory))
        let restored = try await store.semantic(id: memory.id)

        XCTAssertEqual(restored?.tainted, true)
        XCTAssertEqual(restored?.provenance, .externalDocument)
        XCTAssertEqual(restored?.scope, .workspace("repo-1"))
    }

    func testRecordsAreRetrievedOnlyFromRequestedScope() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteMemoryStore(databaseURL: databaseURL)
        let goalScope = MemoryScope.goal(GoalID(rawValue: "goal-1"))
        let goalEpisode = EpisodicMemoryRecord(
            id: "episode-goal",
            scope: goalScope,
            summary: "Goal-local observation summary",
            confidence: 0.9,
            provenance: .runtimeEvidence,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_002),
            invalidatedAt: nil
        )
        let userFact = SemanticMemoryRecord(
            id: "fact-user",
            scope: .user,
            fact: "User-scoped preference",
            confidence: 1.0,
            provenance: .user,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_003),
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_004),
            invalidatedAt: nil
        )

        try await store.save(.episodic(goalEpisode))
        try await store.save(.semantic(userFact))

        let goalRecords = try await store.records(scope: goalScope)

        XCTAssertEqual(goalRecords.map(\.id), [goalEpisode.id])
        XCTAssertEqual(goalRecords.first, .episodic(goalEpisode))
    }

    func testOneSuccessDoesNotPromoteProcedure() {
        let policy = ProceduralPromotionPolicy(minimumSuccesses: 3)

        XCTAssertFalse(policy.shouldPromote(successes: 1, failures: 0))
        XCTAssertTrue(policy.shouldPromote(successes: 3, failures: 0))
    }

    func testProceduralStatisticsRoundTrip() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteMemoryStore(databaseURL: databaseURL)
        let procedure = ProceduralMemoryRecord(
            id: "procedure-1",
            scope: .application("com.example.editor"),
            strategyID: "save-before-close",
            successes: 4,
            failures: 1,
            confidence: 0.75,
            provenance: .runtimeEvidence,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_005),
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_006),
            invalidatedAt: nil
        )

        try await store.save(.procedural(procedure))
        let restored = try await store.record(id: procedure.id)

        XCTAssertEqual(restored, .procedural(procedure))
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zerolose-v2-memory-\(UUID().uuidString).sqlite")
    }
}
