import Foundation
import XCTest
@testable import ZeroLose

final class OperationalContextSourceTests: XCTestCase {
    func testAttachmentSourceReturnsPrivatePresentationSafeContext() async throws {
        let snapshot = AttachmentContextSnapshot(
            id: "a1",
            displayName: "requirements.txt",
            extractedText: "Use Swift concurrency for request orchestration.",
            recordedAt: Date(timeIntervalSince1970: 10)
        )
        let source = AttachmentContextSource(provider: StubAttachmentContextProvider(snapshots: [snapshot]))

        let items = try await source.candidates(
            for: ContextQuery(text: "Swift concurrency", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].content, snapshot.extractedText)
        XCTAssertEqual(items[0].provenance.sourceID, "attachment:a1")
        XCTAssertEqual(items[0].provenance.kind, .attachment)
        XCTAssertEqual(items[0].provenance.sensitivity, .privateContent)
        XCTAssertFalse(items[0].mandatory)
    }

    func testMatchingActiveTaskContextIsMandatory() async throws {
        let goalID = GoalID(rawValue: "goal-1")
        let snapshot = ActiveTaskContextSnapshot(
            goalID: goalID,
            summary: "Finish the context pipeline without bypassing verification.",
            lifecycle: "running",
            mandatoryForActiveGoal: true
        )
        let source = ActiveTaskContextSource(provider: StubActiveTaskContextProvider(snapshot: snapshot))

        let items = try await source.candidates(
            for: ContextQuery(text: "continue", conversationID: "c1", activeGoalID: goalID)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].provenance.kind, .activeTask)
        XCTAssertEqual(items[0].provenance.sourceID, "active-task:goal-1")
        XCTAssertTrue(items[0].mandatory)
    }

    func testNonmatchingActiveTaskIsNotReturned() async throws {
        let snapshot = ActiveTaskContextSnapshot(
            goalID: GoalID(rawValue: "goal-other"),
            summary: "Different goal",
            lifecycle: "running",
            mandatoryForActiveGoal: true
        )
        let source = ActiveTaskContextSource(provider: StubActiveTaskContextProvider(snapshot: snapshot))

        let items = try await source.candidates(
            for: ContextQuery(
                text: "continue",
                conversationID: "c1",
                activeGoalID: GoalID(rawValue: "goal-current")
            )
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testVerifiedRuntimeEvidencePreservesTaintAndSensitivity() async throws {
        let snapshot = VerifiedRuntimeEvidenceSnapshot(
            evidenceID: "e1",
            summary: "Repository verification completed successfully.",
            recordedAt: Date(timeIntervalSince1970: 20),
            tainted: true,
            sensitivity: .privateContent
        )
        let source = RuntimeEvidenceContextSource(
            provider: StubVerifiedRuntimeEvidenceProvider(snapshots: [snapshot])
        )

        let items = try await source.candidates(
            for: ContextQuery(text: "verification", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].provenance.sourceID, "runtime-evidence:e1")
        XCTAssertEqual(items[0].provenance.kind, .runtimeEvidence)
        XCTAssertEqual(items[0].provenance.sensitivity, .privateContent)
        XCTAssertTrue(items[0].provenance.tainted)
        XCTAssertFalse(items[0].mandatory)
    }

    func testCredentialRuntimeEvidenceIsRejectedBeforeReturningCandidates() async throws {
        let safe = VerifiedRuntimeEvidenceSnapshot(
            evidenceID: "safe",
            summary: "Build verified",
            recordedAt: Date(timeIntervalSince1970: 30),
            tainted: false,
            sensitivity: .normal
        )
        let credential = VerifiedRuntimeEvidenceSnapshot(
            evidenceID: "credential",
            summary: "opaque-secret-material",
            recordedAt: Date(timeIntervalSince1970: 31),
            tainted: false,
            sensitivity: .credentialMaterial
        )
        let source = RuntimeEvidenceContextSource(
            provider: StubVerifiedRuntimeEvidenceProvider(snapshots: [safe, credential])
        )

        let items = try await source.candidates(
            for: ContextQuery(text: "build", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(items.map(\.provenance.sourceID), ["runtime-evidence:safe"])
        XCTAssertFalse(items.contains { $0.content.contains("opaque-secret-material") })
    }

    func testOperationalContextSourcesContainNoExecutionOrCredentialDependencies() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "ZeroLose/V2/Context/AttachmentContextSource.swift",
            "ZeroLose/V2/Context/ActiveTaskContextSource.swift",
            "ZeroLose/V2/Context/RuntimeEvidenceContextSource.swift"
        ]
        let forbidden = [
            "ToolInvocation",
            "CredentialHandle",
            "Authorization",
            "cookie",
            "provider stdout"
        ]

        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.localizedCaseInsensitiveContains(token), "\(path) must not depend on \(token)")
            }
        }
    }
}

private struct StubAttachmentContextProvider: AttachmentContextProviding {
    let snapshots: [AttachmentContextSnapshot]

    func attachments(conversationID: String) async -> [AttachmentContextSnapshot] {
        snapshots
    }
}

private struct StubActiveTaskContextProvider: ActiveTaskContextProviding {
    let snapshot: ActiveTaskContextSnapshot?

    func activeTask(goalID: GoalID?) async -> ActiveTaskContextSnapshot? {
        snapshot
    }
}

private struct StubVerifiedRuntimeEvidenceProvider: VerifiedRuntimeEvidenceProviding {
    let snapshots: [VerifiedRuntimeEvidenceSnapshot]

    func verifiedEvidence(
        conversationID: String,
        activeGoalID: GoalID?
    ) async -> [VerifiedRuntimeEvidenceSnapshot] {
        snapshots
    }
}
