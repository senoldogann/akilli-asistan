import Foundation
import XCTest
@testable import ZeroLose

@MainActor
final class LatestInstructionBoundaryTests: XCTestCase {
    func testLatestDirectInstructionStaysOutsideRetrievedSystemContext() async throws {
        let conversationID = "latest-boundary"
        let latestInstruction = "LATEST_DIRECT_INSTRUCTION_MARKER"
        let store = LatestInstructionConversationStore(
            initial: [
                ConversationMessage(
                    id: "previous-user",
                    conversationID: conversationID,
                    role: .user,
                    text: "previous user message",
                    recordedAt: Date(timeIntervalSince1970: 1),
                    provenance: ConversationProvenance(source: .native)
                ),
                ConversationMessage(
                    id: "previous-assistant",
                    conversationID: conversationID,
                    role: .assistant,
                    text: "previous assistant message",
                    recordedAt: Date(timeIntervalSince1970: 2),
                    provenance: ConversationProvenance(source: .native)
                )
            ]
        )
        let providerID = ModelProviderID(rawValue: "latest-boundary-provider")
        let provider = LatestInstructionRecordingProvider(id: providerID)
        let coordinator = RequestCoordinator(
            contextOrchestrator: ContextOrchestrator(
                sources: [ConversationContextSource(store: store)],
                policy: ContextPolicy(maxCharacters: 8_000, minimumRelevance: 0)
            ),
            providerFabric: ModelProviderFabric(
                providers: [provider],
                selectedProviderID: providerID
            ),
            conversationStore: store
        )

        let stream = await coordinator.stream(
            AskRequest(
                sessionID: ModelSessionID(rawValue: "latest-boundary-session"),
                conversationID: conversationID,
                text: latestInstruction,
                modelID: "model-1",
                activeGoalID: nil
            )
        )
        for try await _ in stream {}

        let requests = await provider.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.conversation.last, ModelMessage(role: .user, content: latestInstruction))
        XCTAssertEqual(
            request.conversation.filter { $0.content == latestInstruction }.count,
            1,
            "Latest direct instruction must appear exactly once, as the final direct user message."
        )
        if let systemMessage = request.conversation.first(where: { $0.role == .system }) {
            XCTAssertFalse(
                systemMessage.content.contains(latestInstruction),
                "Latest direct instruction must not be copied into retrieved system context."
            )
        }
    }
}

private actor LatestInstructionConversationStore: ConversationStoring {
    private var stored: [ConversationMessage]

    init(initial: [ConversationMessage]) {
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

private actor LatestInstructionRecordingProvider: ModelProvider {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities = [.textStreaming]

    private(set) var requests: [ModelRequest] = []

    init(id: ModelProviderID) {
        self.id = id
        displayName = id.rawValue
    }

    func status() async -> ProviderStatus {
        ProviderStatus(providerID: id, displayName: displayName, availability: .ready)
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        []
    }

    nonisolated func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                continuation.yield(.completed)
                continuation.finish()
            }
        }
    }

    func cancel(sessionID _: ModelSessionID) async {}

    private func record(_ request: ModelRequest) {
        requests.append(request)
    }
}
