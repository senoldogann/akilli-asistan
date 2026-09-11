import Foundation
@testable import ZeroLose

final class RecordingModelProvider: ModelProvider, Sendable {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities

    private let emittedEvents: [ModelEvent]
    private let terminalError: ProviderError?
    private let state = RecordingModelProviderState()

    var requestCount: Int {
        get async { await state.requestCount }
    }

    var cancelledSessions: [ModelSessionID] {
        get async { await state.cancelledSessions }
    }

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

    func stream(
        _ request: ModelRequest
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let emittedEvents = emittedEvents
        let terminalError = terminalError
        let state = state

        return AsyncThrowingStream { continuation in
            Task {
                await state.recordRequest()
                if let terminalError {
                    continuation.finish(throwing: terminalError)
                    return
                }
                for event in emittedEvents {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        await state.record(cancelledSessionID: sessionID)
    }
}

private actor RecordingModelProviderState {
    private(set) var requestCount = 0
    private(set) var cancelledSessions: [ModelSessionID] = []

    func recordRequest() {
        requestCount += 1
    }

    func record(cancelledSessionID: ModelSessionID) {
        cancelledSessions.append(cancelledSessionID)
    }
}

nonisolated struct StubCLIExecutableLocator: CLIExecutableLocating {
    let paths: [String: URL]

    func executable(named name: String) -> URL? {
        paths[name]
    }
}

nonisolated struct FixtureCLIProcessRunner: CLIProcessRunning {
    let events: [CLIProcessEvent]
    let terminalError: CLIProcessRunnerError?
    private let state: FixtureCLIProcessRunnerState

    init(
        events: [CLIProcessEvent] = [],
        terminalError: CLIProcessRunnerError? = nil
    ) {
        self.events = events
        self.terminalError = terminalError
        state = FixtureCLIProcessRunnerState()
    }

    var commands: [CLICommand] {
        get async { await state.commands }
    }

    var cancelled: [ModelSessionID] {
        get async { await state.cancelled }
    }

    func run(
        _ command: CLICommand
    ) async -> AsyncThrowingStream<CLIProcessEvent, Error> {
        await state.record(command: command)
        let events = self.events
        let terminalError = self.terminalError

        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        await state.record(cancelledSessionID: sessionID)
    }
}

private actor FixtureCLIProcessRunnerState {
    private(set) var commands: [CLICommand] = []
    private(set) var cancelled: [ModelSessionID] = []

    func record(command: CLICommand) {
        commands.append(command)
    }

    func record(cancelledSessionID: ModelSessionID) {
        cancelled.append(cancelledSessionID)
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
