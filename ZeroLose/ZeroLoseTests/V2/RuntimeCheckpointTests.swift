import Foundation
import XCTest
@testable import ZeroLose

final class RuntimeCheckpointTests: XCTestCase {
    func testRestoredCheckpointStartsPausedReconciling() {
        let checkpoint = RuntimeCheckpoint(
            streamID: "goal-1",
            eventSequence: 42,
            taskGraphRevision: 7,
            taskGraphSnapshot: Data("graph".utf8),
            lifecycleSnapshot: Data("running".utf8),
            budgetSnapshot: Data("budget".utf8),
            boundedWorkingMemory: Data("memory".utf8),
            providerContinuationMetadata: Data("continuation".utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let restored = checkpoint.restoredRuntimeState()

        XCTAssertEqual(restored.lifecycle, .paused)
        XCTAssertTrue(restored.requiresReconciliation)
    }

    func testSQLiteCheckpointStoreRoundTripsLatestCheckpoint() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteCheckpointStore(databaseURL: databaseURL)
        let checkpoint = RuntimeCheckpoint(
            streamID: "goal-1",
            eventSequence: 42,
            taskGraphRevision: 7,
            taskGraphSnapshot: Data("graph".utf8),
            lifecycleSnapshot: Data("running".utf8),
            budgetSnapshot: Data("budget".utf8),
            boundedWorkingMemory: Data("memory".utf8),
            providerContinuationMetadata: Data("continuation".utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.save(checkpoint)
        let restored = try await store.latest(streamID: "goal-1")

        XCTAssertEqual(restored, checkpoint)
    }

    func testRuntimeCheckpointSourceContainsNoExecutableAuthorityTypes() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Checkpoint/RuntimeCheckpoint.swift")

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            XCTFail("RuntimeCheckpoint.swift must exist")
            return
        }

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("CredentialHandle"))
        XCTAssertFalse(source.contains("PolicyDecision"))
        XCTAssertFalse(source.contains("ToolInvocation"))
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zerolose-v2-checkpoints-\(UUID().uuidString).sqlite")
    }
}
