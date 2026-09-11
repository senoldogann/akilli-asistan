import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class RequestCoordinatorTests: XCTestCase {
    func testContextBuildPrecedesProviderAndCompletedAssistantIsPersisted() async throws {
        let order = CoordinatorOrderRecorder()
        let contextItem = try ContextItem.validated(
            content: "active project constraint",
            provenance: ContextProvenance(
                sourceID: "goal:goal-1",
                kind: .activeTask,
                timestamp: Date(timeIntervalSince1970: 3),
                tainted: false,
                sensitivity: .normal
            ),
            mandatory: true,
            sourceScore: 1
        )
        let source = CoordinatorContextSource(
            kind: .activeTask,
            output: [contextItem],
            order: order
        )
        let orchestrator = ContextOrchestrator(
            sources: [source],
            policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
        )
        let store = CoordinatorConversationStore(initial: [
            ConversationMessage(
                id: "previous-user",
                conversationID: "c1",
                role: .user,
                text: "previous question",
                recordedAt: Date(timeIntervalSince1970: 1),
                provenance: ConversationProvenance(source: .native)
            ),
            ConversationMessage(
                id: "previous-assistant",
                conversationID: "c1",
                role: .assistant,
                text: "previous answer",
                recordedAt: Date(timeIntervalSince1970: 2),
                provenance: ConversationProvenance(source: .native)
            )
        ])
        let providerID = ModelProviderID(rawValue: "recording")
        let provider = CoordinatorRecordingProvider(
            id: providerID,
            events: [.started, .textDelta("final "), .textDelta("answer"), .completed],
            order: order
        )
        let fabric = ModelProviderFabric(
            providers: [provider],
            selectedProviderID: providerID
        )
        let coordinator = RequestCoordinator(
            contextOrchestrator: orchestrator,
            providerFabric: fabric,
            conversationStore: store
        )

        let stream = await coordinator.stream(
            AskRequest(
                sessionID: ModelSessionID(rawValue: "s1"),
                conversationID: "c1",
                text: "latest question",
                modelID: "model-1",
                activeGoalID: GoalID(rawValue: "goal-1")
            )
        )
        var received: [ModelEvent] = []
        for try await event in stream {
            received.append(event)
        }

        XCTAssertEqual(received, [.started, .textDelta("final "), .textDelta("answer"), .completed])
        let orderSnapshot = await order.snapshot()
        XCTAssertEqual(orderSnapshot, ["context", "provider"])

        let requests = await provider.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.modelID, "model-1")
        XCTAssertEqual(request.conversation.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertTrue(request.conversation[0].content.contains("[activeTask]"))
        XCTAssertTrue(request.conversation[0].content.contains("active project constraint"))
        XCTAssertEqual(request.conversation[1].content, "previous question")
        XCTAssertEqual(request.conversation[2].content, "previous answer")
        XCTAssertEqual(request.conversation[3].content, "latest question")

        let saved = try await store.messages(conversationID: "c1")
        let finalAssistant = try XCTUnwrap(saved.last { $0.role == .assistant && $0.text == "final answer" })
        XCTAssertEqual(finalAssistant.provenance.source, .native)
        XCTAssertFalse(finalAssistant.verifiedSemanticTruth)
    }

    func testAskModeFiltersMutationToolSchemas() async throws {
        let providerID = ModelProviderID(rawValue: "recording")
        let provider = CoordinatorRecordingProvider(
            id: providerID,
            events: [.completed]
        )
        let coordinator = RequestCoordinator(
            contextOrchestrator: ContextOrchestrator(
                sources: [],
                policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
            ),
            providerFabric: ModelProviderFabric(
                providers: [provider],
                selectedProviderID: providerID
            ),
            conversationStore: CoordinatorConversationStore(),
            readOnlyToolSchemas: [
                toolSchema(name: "read.fs"),
                toolSchema(name: "computer.click"),
                toolSchema(name: "browser.mutate.navigate"),
                toolSchema(name: "shell.exec"),
                toolSchema(name: "physical.mutate")
            ]
        )

        let stream = await coordinator.stream(.fixture())
        for try await _ in stream {}

        let requests = await provider.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.tools.map(\.name), ["read.fs"])
    }

    func testCancellationRoutesToSelectedProvider() async {
        let providerID = ModelProviderID(rawValue: "recording")
        let provider = CoordinatorRecordingProvider(id: providerID)
        let coordinator = RequestCoordinator(
            contextOrchestrator: ContextOrchestrator(
                sources: [],
                policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
            ),
            providerFabric: ModelProviderFabric(
                providers: [provider],
                selectedProviderID: providerID
            ),
            conversationStore: CoordinatorConversationStore()
        )
        let sessionID = ModelSessionID(rawValue: "cancel-me")

        await coordinator.cancel(sessionID: sessionID)

        let cancelledSessions = await provider.cancelledSessions
        XCTAssertEqual(cancelledSessions, [sessionID])
    }

    func testProviderErrorIsSurfacedWithoutFallbackOrFinalAssistantPersistence() async throws {
        let selectedID = ModelProviderID(rawValue: "selected")
        let fallbackID = ModelProviderID(rawValue: "fallback")
        let expected = ProviderError.loginRequired(providerID: selectedID)
        let selected = CoordinatorRecordingProvider(
            id: selectedID,
            events: [],
            terminalError: expected
        )
        let fallback = CoordinatorRecordingProvider(
            id: fallbackID,
            events: [.textDelta("wrong provider"), .completed]
        )
        let store = CoordinatorConversationStore()
        let coordinator = RequestCoordinator(
            contextOrchestrator: ContextOrchestrator(
                sources: [],
                policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
            ),
            providerFabric: ModelProviderFabric(
                providers: [selected, fallback],
                selectedProviderID: selectedID
            ),
            conversationStore: store
        )

        var thrown: ProviderError?
        do {
            let stream = await coordinator.stream(.fixture())
            for try await _ in stream {}
        } catch let error as ProviderError {
            thrown = error
        }

        XCTAssertEqual(thrown, expected)
        let selectedRequestCount = await selected.requests.count
        let fallbackRequestCount = await fallback.requests.count
        XCTAssertEqual(selectedRequestCount, 1)
        XCTAssertEqual(fallbackRequestCount, 0)
        let saved = try await store.messages(conversationID: "c1")
        XCTAssertTrue(saved.filter { $0.role == .assistant }.isEmpty)
    }

    func testPartialAssistantTextIsNotPersistedWhenProviderCancels() async throws {
        let providerID = ModelProviderID(rawValue: "recording")
        let provider = CoordinatorRecordingProvider(
            id: providerID,
            events: [.textDelta("partial")],
            terminalError: .cancelled(providerID: providerID)
        )
        let store = CoordinatorConversationStore()
        let coordinator = RequestCoordinator(
            contextOrchestrator: ContextOrchestrator(
                sources: [],
                policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
            ),
            providerFabric: ModelProviderFabric(
                providers: [provider],
                selectedProviderID: providerID
            ),
            conversationStore: store
        )

        do {
            let stream = await coordinator.stream(.fixture())
            for try await _ in stream {}
            XCTFail("Expected cancellation error")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .cancelled(providerID: providerID))
        }

        let saved = try await store.messages(conversationID: "c1")
        XCTAssertTrue(saved.filter { $0.role == .assistant }.isEmpty)
    }

    func testEmptyUserTextFailsBeforePersistenceAndProviderInvocation() async throws {
        let providerID = ModelProviderID(rawValue: "recording")
        let provider = CoordinatorRecordingProvider(id: providerID)
        let store = CoordinatorConversationStore()
        let coordinator = RequestCoordinator(
            contextOrchestrator: ContextOrchestrator(
                sources: [],
                policy: ContextPolicy(maxCharacters: 4_000, minimumRelevance: 0)
            ),
            providerFabric: ModelProviderFabric(
                providers: [provider],
                selectedProviderID: providerID
            ),
            conversationStore: store
        )

        var thrown: RequestCoordinatorError?
        do {
            let stream = await coordinator.stream(
                AskRequest(
                    sessionID: ModelSessionID(rawValue: "s-empty"),
                    conversationID: "c1",
                    text: "  \n\t ",
                    modelID: "model-1",
                    activeGoalID: nil
                )
            )
            for try await _ in stream {}
        } catch let error as RequestCoordinatorError {
            thrown = error
        }

        XCTAssertEqual(thrown, .emptyUserText)
        let providerRequestCount = await provider.requests.count
        XCTAssertEqual(providerRequestCount, 0)
        let storedCount = try await store.count()
        XCTAssertEqual(storedCount, 0)
    }

    private func toolSchema(name: String) -> ModelToolSchema {
        ModelToolSchema(
            name: name,
            description: "test schema",
            inputSchemaJSON: Data("{}".utf8)
        )
    }
}

private nonisolated struct CoordinatorContextSource: ContextSource {
    let kind: ContextSourceKind
    let output: [ContextItem]
    let order: CoordinatorOrderRecorder

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        await order.append("context")
        return output
    }
}

private actor CoordinatorOrderRecorder {
    private var entries: [String] = []

    func append(_ value: String) {
        entries.append(value)
    }

    func snapshot() -> [String] {
        entries
    }
}

private actor CoordinatorConversationStore: ConversationStoring {
    private var stored: [ConversationMessage]

    init(initial: [ConversationMessage] = []) {
        stored = initial
    }

    func save(_ message: ConversationMessage) async throws {
        stored.append(message)
    }

    func message(id: String) async throws -> ConversationMessage? {
        stored.first { $0.id == id }
    }

    func messages(conversationID: String) async throws -> [ConversationMessage] {
        stored
            .filter { $0.conversationID == conversationID }
            .sorted {
                if $0.recordedAt != $1.recordedAt {
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.id < $1.id
            }
    }

    func count() async throws -> Int {
        stored.count
    }
}

private actor CoordinatorRecordingProvider: ModelProvider {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities = [.textStreaming]

    private let emittedEvents: [ModelEvent]
    private let terminalError: ProviderError?
    private let order: CoordinatorOrderRecorder?
    private(set) var requests: [ModelRequest] = []
    private(set) var cancelledSessions: [ModelSessionID] = []

    init(
        id: ModelProviderID,
        events: [ModelEvent] = [.completed],
        terminalError: ProviderError? = nil,
        order: CoordinatorOrderRecorder? = nil
    ) {
        self.id = id
        displayName = id.rawValue.capitalized
        emittedEvents = events
        self.terminalError = terminalError
        self.order = order
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: .ready
        )
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        [
            ModelDescriptor(
                id: "model-1",
                displayName: "Model 1",
                providerID: id,
                capabilities: capabilities
            )
        ]
    }

    nonisolated func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                if let order = await self.orderValue() {
                    await order.append("provider")
                }
                for event in await self.eventsValue() {
                    continuation.yield(event)
                }
                if let terminalError = await self.terminalErrorValue() {
                    continuation.finish(throwing: terminalError)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        cancelledSessions.append(sessionID)
    }

    private func record(_ request: ModelRequest) {
        requests.append(request)
    }

    private func eventsValue() -> [ModelEvent] {
        emittedEvents
    }

    private func terminalErrorValue() -> ProviderError? {
        terminalError
    }

    private func orderValue() -> CoordinatorOrderRecorder? {
        order
    }
}

private extension AskRequest {
    static func fixture() -> AskRequest {
        AskRequest(
            sessionID: ModelSessionID(rawValue: "s1"),
            conversationID: "c1",
            text: "hello",
            modelID: "model-1",
            activeGoalID: nil
        )
    }
}
