import Foundation

enum TaskGraphError: Error, Equatable {
    case duplicateTask(TaskID)
    case taskNotFound(TaskID)
    case illegalTransition(from: TaskLifecycle, to: TaskLifecycle)
    case verificationEvidenceRequired
}

actor TaskGraph {
    let goalID: GoalID
    private(set) var revision: UInt64 = 0

    private var tasks: [TaskID: TaskNode] = [:]
    private let eventStore: (any EventStoring)?
    private let streamID: String

    init(goalID: GoalID, eventStore: (any EventStoring)? = nil) {
        self.goalID = goalID
        self.eventStore = eventStore
        self.streamID = "task-graph:\(goalID.rawValue)"
    }

    func add(_ node: TaskNode) async throws {
        guard tasks[node.id] == nil else {
            throw TaskGraphError.duplicateTask(node.id)
        }

        let nextRevision = revision + 1
        try await appendRevisionEvent(
            taskID: node.id,
            action: .taskAdded,
            from: nil,
            to: node.lifecycle,
            nextRevision: nextRevision
        )

        tasks[node.id] = node
        revision = nextRevision
    }

    func transition(
        taskID: TaskID,
        to lifecycle: TaskLifecycle,
        evidence: VerificationEvidence?
    ) async throws {
        guard var node = tasks[taskID] else {
            throw TaskGraphError.taskNotFound(taskID)
        }

        if lifecycle == .succeeded, evidence == nil {
            throw TaskGraphError.verificationEvidenceRequired
        }

        guard Self.canTransition(from: node.lifecycle, to: lifecycle) else {
            throw TaskGraphError.illegalTransition(from: node.lifecycle, to: lifecycle)
        }

        let previousLifecycle = node.lifecycle
        let nextRevision = revision + 1
        try await appendRevisionEvent(
            taskID: taskID,
            action: .taskTransitioned,
            from: previousLifecycle,
            to: lifecycle,
            nextRevision: nextRevision
        )

        node.lifecycle = lifecycle
        if let evidence {
            node.verificationEvidence.append(evidence)
        }
        tasks[taskID] = node
        revision = nextRevision
    }

    func snapshot() -> TaskGraphSnapshot {
        TaskGraphSnapshot(goalID: goalID, revision: revision, tasks: tasks)
    }

    private func appendRevisionEvent(
        taskID: TaskID,
        action: TaskGraphEventAction,
        from: TaskLifecycle?,
        to: TaskLifecycle,
        nextRevision: UInt64
    ) async throws {
        guard let eventStore else {
            return
        }

        let payload = TaskGraphEventPayload(
            action: action,
            taskID: taskID,
            from: from,
            to: to,
            revision: nextRevision
        )
        let encodedPayload = try JSONEncoder().encode(payload)
        let event = RuntimeEvent(
            eventID: RuntimeEventID(rawValue: UUID().uuidString),
            streamID: streamID,
            sequence: nextRevision,
            schemaVersion: 1,
            goalID: goalID,
            taskID: taskID,
            sessionID: nil,
            eventKind: .taskGraph,
            causationID: nil,
            correlationID: nil,
            taskGraphRevision: nextRevision,
            toolRegistryRevision: nil,
            policyRevision: nil,
            payload: encodedPayload,
            redactionClass: .normal,
            provenance: "task-graph",
            tainted: false,
            recordedAt: Date()
        )
        try await eventStore.append(event)
    }

    private static func canTransition(from: TaskLifecycle, to: TaskLifecycle) -> Bool {
        switch from {
        case .created:
            return [.blocked, .ready, .planning, .paused, .cancelled].contains(to)
        case .blocked:
            return [.ready, .replanned, .paused, .cancelled].contains(to)
        case .ready:
            return [.planning, .running, .paused, .cancelled].contains(to)
        case .planning:
            return [.ready, .running, .blocked, .failed, .replanned, .waitingExternal, .waitingApproval, .paused, .cancelled].contains(to)
        case .running:
            return [.verifying, .failed, .waitingExternal, .waitingApproval, .paused, .cancelled].contains(to)
        case .verifying:
            return [.succeeded, .failed, .recovering, .paused, .cancelled].contains(to)
        case .failed:
            return [.recovering, .replanned, .exhausted, .cancelled].contains(to)
        case .recovering:
            return [.ready, .replanned, .failed, .exhausted, .paused, .cancelled].contains(to)
        case .replanned:
            return [.blocked, .ready, .planning, .paused, .cancelled].contains(to)
        case .waitingExternal:
            return [.ready, .verifying, .failed, .paused, .cancelled].contains(to)
        case .waitingApproval:
            return [.ready, .running, .failed, .paused, .cancelled].contains(to)
        case .paused:
            return [.ready, .cancelled].contains(to)
        case .succeeded, .exhausted, .cancelled:
            return false
        }
    }
}

private enum TaskGraphEventAction: String, Codable, Sendable {
    case taskAdded
    case taskTransitioned
}

private struct TaskGraphEventPayload: Codable, Sendable {
    let action: TaskGraphEventAction
    let taskID: TaskID
    let from: TaskLifecycle?
    let to: TaskLifecycle
    let revision: UInt64
}
