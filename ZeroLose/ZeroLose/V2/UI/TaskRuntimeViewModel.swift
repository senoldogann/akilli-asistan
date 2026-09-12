import Observation

struct TaskRuntimeProjectionSnapshot: Sendable, Equatable {
    let goalID: GoalID
    let statusText: String
    let sessionID: AgentSessionID?
    let lifecycle: AgentLifecycle?
    let isPaused: Bool
    let mutationCapableExecutionActive: Bool

    init(
        goalID: GoalID,
        statusText: String,
        sessionID: AgentSessionID? = nil,
        lifecycle: AgentLifecycle? = nil,
        isPaused: Bool = false,
        mutationCapableExecutionActive: Bool = false
    ) {
        self.goalID = goalID
        self.statusText = statusText
        self.sessionID = sessionID
        self.lifecycle = lifecycle
        self.isPaused = isPaused
        self.mutationCapableExecutionActive = mutationCapableExecutionActive
    }
}

@MainActor
@Observable
final class TaskRuntimeViewModel {
    private(set) var goalID: GoalID?
    private(set) var sessionID: AgentSessionID?
    private(set) var lifecycle: AgentLifecycle?
    private(set) var isPaused = false
    private(set) var mutationCapableExecutionActive = false
    private(set) var statusText = "Idle"
    private let commandSender: any ApplicationCommandSending

    var hasActiveGoal: Bool { goalID != nil }
    var hasActiveSession: Bool {
        guard sessionID != nil, let lifecycle else { return false }
        return !Self.isTerminal(lifecycle)
    }
    var canPause: Bool { hasActiveSession && !isPaused }
    var canResume: Bool { hasActiveSession && isPaused }
    var canCancel: Bool { hasActiveSession }
    var canEmergencyStop: Bool {
        hasActiveSession && mutationCapableExecutionActive
    }

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: TaskRuntimeProjectionSnapshot) {
        goalID = snapshot.goalID
        sessionID = snapshot.sessionID
        lifecycle = snapshot.lifecycle
        isPaused = snapshot.isPaused
        mutationCapableExecutionActive = snapshot.mutationCapableExecutionActive
        statusText = snapshot.statusText
    }

    func pause() async throws {
        guard canPause, let sessionID else { return }
        try await commandSender.send(.pauseAgentSession(sessionID))
    }

    func resume() async throws {
        guard canResume, let sessionID else { return }
        try await commandSender.send(.resumeAgentSession(sessionID))
    }

    func cancel() async throws {
        guard canCancel, let sessionID else { return }
        try await commandSender.send(.cancelAgentSession(sessionID))
    }

    func emergencyStop() async throws {
        guard canEmergencyStop else { return }
        try await commandSender.send(.emergencyStop)
    }

    private static func isTerminal(_ lifecycle: AgentLifecycle) -> Bool {
        switch lifecycle {
        case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
            return true
        case .created, .planning, .ready, .executing, .observing, .verifying:
            return false
        }
    }
}
