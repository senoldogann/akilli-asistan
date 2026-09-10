struct TaskDependency: Sendable, Equatable, Hashable {
    let taskID: TaskID
    let dependsOn: TaskID
}

struct PlanningProposal: Sendable, Equatable {
    let addTasks: [TaskNode]
    let addDependencies: [TaskDependency]
    let markBlocked: [TaskID]
}
