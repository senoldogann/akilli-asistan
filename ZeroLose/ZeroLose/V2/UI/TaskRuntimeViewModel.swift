import Observation

struct TaskRuntimeProjectionSnapshot: Sendable, Equatable {
    let goalID: GoalID
    let statusText: String
}

@MainActor
@Observable
final class TaskRuntimeViewModel {
    private(set) var goalID: GoalID?
    private(set) var statusText = "Autonomous runtime not configured"
    private let commandSender: any ApplicationCommandSending

    var hasActiveGoal: Bool { goalID != nil }
    var canPause: Bool { hasActiveGoal }
    var canResume: Bool { hasActiveGoal }
    var canCancel: Bool { hasActiveGoal }

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: TaskRuntimeProjectionSnapshot) {
        goalID = snapshot.goalID
        statusText = snapshot.statusText
    }

    func pause() async throws {
        guard let goalID else { return }
        try await commandSender.send(.pauseGoal(goalID))
    }

    func resume() async throws {
        guard let goalID else { return }
        try await commandSender.send(.resumeGoal(goalID))
    }

    func cancel() async throws {
        guard let goalID else { return }
        try await commandSender.send(.cancelGoal(goalID))
    }
}
