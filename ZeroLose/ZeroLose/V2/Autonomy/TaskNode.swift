import Foundation

struct TaskNode: Codable, Equatable, Sendable {
    let id: TaskID
    let title: String
    var dependencies: Set<TaskID>
    var lifecycle: TaskLifecycle
    var verificationEvidence: [VerificationEvidence]

    init(
        id: TaskID,
        title: String,
        dependencies: Set<TaskID> = [],
        lifecycle: TaskLifecycle = .created,
        verificationEvidence: [VerificationEvidence] = []
    ) {
        self.id = id
        self.title = title
        self.dependencies = dependencies
        self.lifecycle = lifecycle
        self.verificationEvidence = verificationEvidence
    }
}

struct TaskGraphSnapshot: Codable, Equatable, Sendable {
    let goalID: GoalID
    let revision: UInt64
    let tasks: [TaskID: TaskNode]
}
