import Foundation
import XCTest
@testable import ZeroLose

final class ReplayRuntimeTests: XCTestCase {
    func testReplayReconstructsToolReceiptsInSequenceOrder() async throws {
        let later = try toolEvent(sequence: 2, invocationID: "inv-2")
        let earlier = try toolEvent(sequence: 1, invocationID: "inv-1")
        let replay = ReplayRuntime(
            events: [later, earlier],
            executor: ReplayToolExecutor()
        )

        let state = try await replay.run()

        XCTAssertEqual(state.eventSequences, [1, 2])
        XCTAssertEqual(
            state.toolReceipts.map { $0.invocationID.rawValue },
            ["inv-1", "inv-2"]
        )
    }

    func testReplayRuntimeSourceContainsNoLiveMutationDependencies() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let zeroLoseDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let replayDirectory = zeroLoseDirectory
            .appendingPathComponent("ZeroLose/V2/Replay")
        let requiredSources = [
            "ReplayArtifact.swift",
            "ReplayToolExecutor.swift",
            "ReplayRuntime.swift"
        ]
        let forbiddenDependencies = [
            "ToolFabric",
            "ToolProvider",
            "URLSession",
            "CoreGraphics",
            "InputDriving"
        ]

        for filename in requiredSources {
            let sourceURL = replayDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                XCTFail("\(filename) must exist")
                continue
            }

            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for dependency in forbiddenDependencies {
                XCTAssertFalse(
                    source.contains(dependency),
                    "Replay source must not depend on \(dependency)"
                )
            }
        }
    }

    private func toolEvent(sequence: UInt64, invocationID: String) throws -> RuntimeEvent {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(sequence))
        let artifact = ReplayArtifact(
            invocationID: InvocationID(rawValue: invocationID),
            toolID: ToolID(rawValue: "builtin.test"),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            providerReference: "recorded-reference-\(sequence)",
            resultProvenance: "recorded",
            resultTainted: false
        )

        return RuntimeEvent(
            eventID: RuntimeEventID(rawValue: "event-\(sequence)"),
            streamID: "goal-1",
            sequence: sequence,
            schemaVersion: 1,
            goalID: GoalID(rawValue: "goal-1"),
            taskID: nil,
            sessionID: nil,
            eventKind: .tool,
            causationID: nil,
            correlationID: nil,
            taskGraphRevision: nil,
            toolRegistryRevision: 1,
            policyRevision: 1,
            payload: try JSONEncoder().encode(artifact),
            redactionClass: .normal,
            provenance: "recorded-runtime",
            tainted: false,
            recordedAt: startedAt
        )
    }
}
