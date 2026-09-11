import Foundation
import XCTest
@testable import ZeroLose

final class ConversationMemoryContextSourceTests: XCTestCase {
    func testConversationSourceReturnsRecentMessagesInRecordedOrderWithProvenance() async throws {
        let store = StubConversationStore(messages: [
            makeMessage(id: "m3", text: "third", recordedAt: 30, source: .legacyVectorStore),
            makeMessage(id: "m1", text: "first", recordedAt: 10, source: .native),
            makeMessage(id: "m2", text: "second", recordedAt: 20, source: .native)
        ])
        let source = ConversationContextSource(store: store, maxMessages: 2)

        let items = try await source.candidates(
            for: ContextQuery(text: "continue", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(items.map(\.content), ["second", "third"])
        XCTAssertEqual(
            items.map(\.provenance.sourceID),
            ["conversation:m2:native", "conversation:m3:legacyVectorStore"]
        )
        XCTAssertTrue(items.allSatisfy { $0.provenance.kind == .conversation })
        XCTAssertTrue(items.allSatisfy { $0.provenance.sensitivity == .privateContent })
        XCTAssertTrue(items.allSatisfy { !$0.mandatory })
    }

    func testConversationSourceDoesNotPromoteVerifiedAssistantMessageIntoSemanticTruth() async throws {
        let store = StubConversationStore(messages: [
            makeMessage(
                id: "assistant-unverified",
                text: "unverified assistant output",
                recordedAt: 10,
                source: .native,
                role: .assistant,
                verifiedSemanticTruth: false
            ),
            makeMessage(
                id: "assistant-verified",
                text: "verified runtime-backed assistant output",
                recordedAt: 20,
                source: .native,
                role: .assistant,
                verifiedSemanticTruth: true
            )
        ])
        let source = ConversationContextSource(store: store, maxMessages: 2)

        let items = try await source.candidates(
            for: ContextQuery(text: "assistant", conversationID: "c1", activeGoalID: nil)
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.sourceScore), [0, 0])
        XCTAssertTrue(items.allSatisfy { !$0.mandatory })
    }

    func testMemorySourceQueriesUserGoalAndConfiguredScopesAndFiltersUnsafeKinds() async throws {
        let confirmedUser = SemanticMemoryRecord(
            id: "confirmed-user",
            scope: .user,
            fact: "Prefer concise build logs",
            confidence: 0.7,
            provenance: .user,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 10),
            confirmedAt: Date(timeIntervalSince1970: 11),
            invalidatedAt: nil
        )
        let derivedUser = SemanticMemoryRecord(
            id: "derived-user",
            scope: .user,
            fact: "Derived preference",
            confidence: 0.95,
            provenance: .derived,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 12),
            confirmedAt: nil,
            invalidatedAt: nil
        )
        let invalidated = SemanticMemoryRecord(
            id: "invalidated",
            scope: .user,
            fact: "Outdated preference",
            confidence: 1,
            provenance: .user,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 13),
            confirmedAt: Date(timeIntervalSince1970: 14),
            invalidatedAt: Date(timeIntervalSince1970: 15)
        )
        let goalID = GoalID(rawValue: "goal-1")
        let episode = EpisodicMemoryRecord(
            id: "goal-episode",
            scope: .goal(goalID),
            summary: "Verified goal-local observation",
            confidence: 0.8,
            provenance: .runtimeEvidence,
            tainted: true,
            createdAt: Date(timeIntervalSince1970: 16),
            confirmedAt: Date(timeIntervalSince1970: 17),
            invalidatedAt: nil
        )
        let applicationFact = SemanticMemoryRecord(
            id: "application-fact",
            scope: .application("com.example.editor"),
            fact: "Editor uses project-local settings",
            confidence: 0.85,
            provenance: .externalDocument,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 18),
            confirmedAt: nil,
            invalidatedAt: nil
        )
        let procedure = ProceduralMemoryRecord(
            id: "procedure",
            scope: .application("com.example.editor"),
            strategyID: "save-before-close",
            successes: 4,
            failures: 0,
            confidence: 0.9,
            provenance: .runtimeEvidence,
            tainted: false,
            createdAt: Date(timeIntervalSince1970: 19),
            confirmedAt: Date(timeIntervalSince1970: 20),
            invalidatedAt: nil
        )
        let store = StubMemoryStore(records: [
            .semantic(confirmedUser),
            .semantic(derivedUser),
            .semantic(invalidated),
            .episodic(episode),
            .semantic(applicationFact),
            .procedural(procedure)
        ])
        let source = MemoryContextSource(
            store: store,
            additionalScopes: [.application("com.example.editor")]
        )

        let items = try await source.candidates(
            for: ContextQuery(text: "project settings", conversationID: "c1", activeGoalID: goalID)
        )

        XCTAssertEqual(
            items.map(\.provenance.sourceID),
            [
                "memory:confirmed-user:user",
                "memory:derived-user:derived",
                "memory:goal-episode:runtimeEvidence",
                "memory:application-fact:externalDocument"
            ]
        )
        XCTAssertFalse(items.contains { $0.provenance.sourceID.contains("invalidated") })
        XCTAssertFalse(items.contains { $0.provenance.sourceID.contains("procedure") })
        XCTAssertEqual(items.first?.sourceScore, 1)
        XCTAssertLessThan(items[1].sourceScore, items[0].sourceScore)
        XCTAssertTrue(items[2].provenance.tainted)
        XCTAssertTrue(items.allSatisfy { $0.provenance.sensitivity == .privateContent })
    }

    private func makeMessage(
        id: String,
        text: String,
        recordedAt: TimeInterval,
        source: ConversationProvenanceSource,
        role: ConversationRole = .user,
        verifiedSemanticTruth: Bool = false
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            conversationID: "c1",
            role: role,
            text: text,
            recordedAt: Date(timeIntervalSince1970: recordedAt),
            provenance: ConversationProvenance(source: source),
            verifiedSemanticTruth: verifiedSemanticTruth
        )
    }
}

private final class StubConversationStore: ConversationStoring, @unchecked Sendable {
    private let storedMessages: [ConversationMessage]

    init(messages: [ConversationMessage]) {
        storedMessages = messages
    }

    func save(_ message: ConversationMessage) async throws {}

    func message(id: String) async throws -> ConversationMessage? {
        storedMessages.first { $0.id == id }
    }

    func messages(conversationID: String) async throws -> [ConversationMessage] {
        storedMessages.filter { $0.conversationID == conversationID }
    }

    func count() async throws -> Int {
        storedMessages.count
    }
}

private final class StubMemoryStore: MemoryStoring, @unchecked Sendable {
    private let storedRecords: [MemoryRecord]

    init(records: [MemoryRecord]) {
        storedRecords = records
    }

    func save(_ record: MemoryRecord) async throws {}

    func record(id: String) async throws -> MemoryRecord? {
        storedRecords.first { $0.id == id }
    }

    func semantic(id: String) async throws -> SemanticMemoryRecord? {
        for record in storedRecords {
            if case .semantic(let semantic) = record, semantic.id == id {
                return semantic
            }
        }
        return nil
    }

    func records(scope: MemoryScope) async throws -> [MemoryRecord] {
        storedRecords.filter { $0.scope == scope }
    }
}
