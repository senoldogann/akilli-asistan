import Foundation
@testable import ZeroLose

actor RecordingModelProvider: ModelProvider {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities

    private let emittedEvents: [ModelEvent]
    private let terminalError: ProviderError?

    private(set) var requestCount = 0
    private(set) var cancelledSessions: [ModelSessionID] = []

    init(
        id: String,
        events: [ModelEvent] = [.completed],
        error: ProviderError? = nil
    ) {
        self.id = ModelProviderID(rawValue: id)
        displayName = id.capitalized
        capabilities = [.textStreaming]
        emittedEvents = events
        terminalError = error
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
                id: "default",
                displayName: "Default",
                providerID: id,
                capabilities: capabilities
            )
        ]
    }

    nonisolated func stream(
        _ request: ModelRequest
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordRequest()
                if let error = await self.terminalErrorValue() {
                    continuation.finish(throwing: error)
                    return
                }
                for event in await self.eventsValue() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        cancelledSessions.append(sessionID)
    }

    private func recordRequest() {
        requestCount += 1
    }

    private func eventsValue() -> [ModelEvent] {
        emittedEvents
    }

    private func terminalErrorValue() -> ProviderError? {
        terminalError
    }
}

extension ModelRequest {
    static func fixture(providerModel: String = "default") -> Self {
        ModelRequest(
            sessionID: ModelSessionID(rawValue: "s1"),
            conversation: [ModelMessage(role: .user, content: "hello")],
            modelID: providerModel,
            tools: [],
            responseMode: .text
        )
    }
}
