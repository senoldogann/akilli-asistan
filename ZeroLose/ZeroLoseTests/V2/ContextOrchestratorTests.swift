import Foundation
import XCTest
@testable import ZeroLose

final class ContextOrchestratorTests: XCTestCase {
    func testEveryRequestQueriesEveryConfiguredSourceEvenWhenOneFails() async throws {
        let memory = RecordingContextSource(kind: .memory, output: [], error: StubContextError.failed)
        let attachment = RecordingContextSource(kind: .attachment, output: [])
        let orchestrator = ContextOrchestrator(
            sources: [memory, attachment],
            policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0.25)
        )

        let bundle = try await orchestrator.buildContext(
            for: ContextQuery(text: "open the project", conversationID: "c1", activeGoalID: nil)
        )

        let memoryCount = await memory.queryCount
        let attachmentCount = await attachment.queryCount
        XCTAssertEqual(memoryCount, 1)
        XCTAssertEqual(attachmentCount, 1)
        XCTAssertTrue(bundle.excluded.contains {
            $0.sourceID == "source:memory" && $0.reason == .sourceFailure
        })
    }

    func testRelevanceThresholdExcludesUnrelatedMemoryAndIncludesRelevantMemory() async throws {
        let relevant = try makeItem(
            sourceID: "memory:relevant",
            kind: .memory,
            content: "Project build details",
            sourceScore: 0
        )
        let unrelated = try makeItem(
            sourceID: "memory:unrelated",
            kind: .memory,
            content: "Favorite lunch recipe",
            sourceScore: 0
        )
        let source = RecordingContextSource(kind: .memory, output: [unrelated, relevant])
        let orchestrator = ContextOrchestrator(
            sources: [source],
            policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0.5)
        )

        let bundle = try await orchestrator.buildContext(
            for: ContextQuery(text: "project build", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(bundle.items.map(\.provenance.sourceID), ["memory:relevant"])
        XCTAssertTrue(bundle.excluded.contains {
            $0.sourceID == "memory:unrelated" && $0.reason == .belowThreshold
        })
    }

    func testMandatoryActiveTaskSurvivesLowLexicalOverlap() async throws {
        let mandatory = try makeItem(
            sourceID: "active-task:g1",
            kind: .activeTask,
            content: "Preserve the verified runtime boundary",
            mandatory: true,
            sourceScore: 0
        )
        let source = RecordingContextSource(kind: .activeTask, output: [mandatory])
        let orchestrator = ContextOrchestrator(
            sources: [source],
            policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0.95)
        )

        let bundle = try await orchestrator.buildContext(
            for: ContextQuery(text: "unrelated", conversationID: "c1", activeGoalID: GoalID(rawValue: "g1"))
        )

        XCTAssertEqual(bundle.items.map(\.provenance.sourceID), ["active-task:g1"])
    }

    func testDuplicateNormalizedContentKeepsHigherPriorityProvenance() async throws {
        let memory = try makeItem(
            sourceID: "memory:duplicate",
            kind: .memory,
            content: "Same content!",
            sourceScore: 0.5
        )
        let evidence = try makeItem(
            sourceID: "runtime:duplicate",
            kind: .runtimeEvidence,
            content: " same content ",
            sourceScore: 0.5
        )
        let orchestrator = ContextOrchestrator(
            sources: [
                RecordingContextSource(kind: .memory, output: [memory]),
                RecordingContextSource(kind: .runtimeEvidence, output: [evidence])
            ],
            policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
        )

        let bundle = try await orchestrator.buildContext(
            for: ContextQuery(text: "same content", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(bundle.items.map(\.provenance.sourceID), ["runtime:duplicate"])
        XCTAssertTrue(bundle.excluded.contains {
            $0.sourceID == "memory:duplicate" && $0.reason == .duplicate
        })
    }

    func testOrderingAndTaintAreStableAcrossRepeatedBuilds() async throws {
        let olderAttachment = try makeItem(
            sourceID: "attachment:older",
            kind: .attachment,
            content: "attachment context",
            timestamp: 10,
            tainted: true,
            sourceScore: 0.4
        )
        let evidence = try makeItem(
            sourceID: "runtime:evidence",
            kind: .runtimeEvidence,
            content: "runtime context",
            timestamp: 5,
            tainted: true,
            sourceScore: 0.4
        )
        let memory = try makeItem(
            sourceID: "memory:item",
            kind: .memory,
            content: "memory context",
            timestamp: 30,
            sourceScore: 0.4
        )
        let sources: [any ContextSource] = [
            RecordingContextSource(kind: .memory, output: [memory]),
            RecordingContextSource(kind: .attachment, output: [olderAttachment]),
            RecordingContextSource(kind: .runtimeEvidence, output: [evidence])
        ]
        let orchestrator = ContextOrchestrator(
            sources: sources,
            policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
        )
        let query = ContextQuery(text: "different query", conversationID: "c1", activeGoalID: nil)

        let first = try await orchestrator.buildContext(for: query)
        let second = try await orchestrator.buildContext(for: query)

        let expected = ["runtime:evidence", "attachment:older", "memory:item"]
        XCTAssertEqual(first.items.map(\.provenance.sourceID), expected)
        XCTAssertEqual(second.items.map(\.provenance.sourceID), expected)
        XCTAssertTrue(first.items[0].provenance.tainted)
        XCTAssertTrue(first.items[1].provenance.tainted)
    }

    func testBudgetTruncatesOversizedMandatoryItemAndRecordsExclusion() async throws {
        let mandatory = try makeItem(
            sourceID: "active-task:large",
            kind: .activeTask,
            content: "abcdefghij",
            mandatory: true,
            sourceScore: 0
        )
        let orchestrator = ContextOrchestrator(
            sources: [RecordingContextSource(kind: .activeTask, output: [mandatory])],
            policy: ContextPolicy(maxCharacters: 5, minimumRelevance: 1)
        )

        let bundle = try await orchestrator.buildContext(
            for: ContextQuery(text: "none", conversationID: "c1", activeGoalID: GoalID(rawValue: "large"))
        )

        XCTAssertEqual(bundle.items.count, 1)
        XCTAssertEqual(bundle.items[0].content, "abcde")
        XCTAssertEqual(bundle.usedCharacters, 5)
        XCTAssertLessThanOrEqual(bundle.items.reduce(0) { $0 + $1.content.count }, 5)
        XCTAssertTrue(bundle.excluded.contains {
            $0.sourceID == "active-task:large" && $0.reason == .budgetExceeded
        })
    }

    private func makeItem(
        sourceID: String,
        kind: ContextSourceKind,
        content: String,
        timestamp: TimeInterval? = nil,
        tainted: Bool = false,
        mandatory: Bool = false,
        sourceScore: Double
    ) throws -> ContextItem {
        try ContextItem.validated(
            content: content,
            provenance: ContextProvenance(
                sourceID: sourceID,
                kind: kind,
                timestamp: timestamp.map(Date.init(timeIntervalSince1970:)),
                tainted: tainted,
                sensitivity: .privateContent
            ),
            mandatory: mandatory,
            sourceScore: sourceScore
        )
    }
}

private enum StubContextError: Error {
    case failed
}

private actor RecordingContextSource: ContextSource {
    let kind: ContextSourceKind
    let output: [ContextItem]
    let error: Error?
    private(set) var queryCount = 0

    init(kind: ContextSourceKind, output: [ContextItem], error: Error? = nil) {
        self.kind = kind
        self.output = output
        self.error = error
    }

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        queryCount += 1
        if let error {
            throw error
        }
        return output
    }
}
