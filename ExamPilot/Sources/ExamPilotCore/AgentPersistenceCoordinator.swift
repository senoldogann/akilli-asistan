import Foundation

public final class CompositeAgentEventSink: AgentEventSinking {
    private let sinks: [AgentEventSinking]

    public init(sinks: [AgentEventSinking]) {
        self.sinks = sinks
    }

    public func record(_ event: AgentEvent) {
        for sink in sinks {
            sink.record(event)
        }
    }
}

public final class PersistentAgentEventSink: AgentEventSinking {
    private let store: AgentEventStore
    private let onFailure: (String) -> Void

    public init(
        store: AgentEventStore,
        onFailure: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.onFailure = onFailure
    }

    public func record(_ event: AgentEvent) {
        do {
            try store.append(event)
        } catch {
            onFailure(Self.normalized(error).diagnosticID)
        }
    }

    private static func normalized(_ error: Error) -> AgentPersistenceError {
        error as? AgentPersistenceError ?? .storageFailure
    }
}

public final class AgentPersistenceCoordinator {
    private let eventStore: AgentEventStore
    private let conversationStore: AgentConversationStore
    private let memoryStore: AgentMemoryStore
    private let replayProjector: AgentReplayProjector

    public init(
        eventStore: AgentEventStore,
        conversationStore: AgentConversationStore,
        memoryStore: AgentMemoryStore,
        replayProjector: AgentReplayProjector = AgentReplayProjector()
    ) {
        self.eventStore = eventStore
        self.conversationStore = conversationStore
        self.memoryStore = memoryStore
        self.replayProjector = replayProjector
    }

    public func checkpoint(session: ComputerAgentSession) throws {
        do {
            try conversationStore.saveConversation(
                AgentConversationRecord(
                    sessionID: session.id,
                    state: session.providerConversationState
                )
            )
            try memoryStore.saveMemory(
                AgentMemoryRecord(
                    sessionID: session.id,
                    snapshot: session.workingMemory.snapshot()
                )
            )
        } catch {
            throw Self.normalized(error)
        }
    }

    public func prepareResume(sessionID: String) throws -> AgentResumeCheckpoint {
        do {
            let events = try eventStore.events(sessionID: sessionID)
            let conversation = try conversationStore.conversation(sessionID: sessionID)
            let memory = try memoryStore.memory(sessionID: sessionID)
            let replay = try replayProjector.project(events: events)
            return try AgentResumeCheckpoint(
                sessionID: sessionID,
                replaySnapshot: replay,
                conversationHistory: conversation,
                memoryHistory: memory
            )
        } catch {
            throw Self.normalized(error)
        }
    }

    private static func normalized(_ error: Error) -> AgentPersistenceError {
        error as? AgentPersistenceError ?? .storageFailure
    }
}
