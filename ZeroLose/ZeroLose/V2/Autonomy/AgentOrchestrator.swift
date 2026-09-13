import Foundation

struct AgentLifecycleEventPayload: Codable, Sendable, Equatable {
    let sessionID: AgentSessionID
    let goalID: GoalID
    let lifecycle: AgentLifecycle
    let verificationEvidenceID: String?
}

enum AgentOrchestratorError: Error, Sendable, Equatable {
    case sessionAlreadyActive
    case invalidPlanningProposal
    case noRunnableTasks
    case restoreUnavailable
    case invalidRestoredState
    case manualResolutionRequired
}

actor AgentOrchestrator {
    private let planner: any Planning
    private let scheduler: Scheduler
    private let taskRuntime: TaskRuntime
    private let checkpointStore: any CheckpointStoring
    private let eventStore: any EventStoring
    private let goalVerifier: any GoalVerifying
    private let budget: RuntimeBudget
    private let planningContext: PlanningContext
    private let restoreCoordinator: (any AutonomousSessionRestoring)?

    private var currentGoal: GoalSnapshot?
    private var graph: TaskGraph?
    private var session: AgentSessionSnapshot?
    private var eventSequence: UInt64 = 0
    private var pauseRequested = false
    private var cancellationRequested = false
    private var emergencyStopRequested = false

    init(
        planner: any Planning,
        scheduler: Scheduler,
        taskRuntime: TaskRuntime,
        checkpointStore: any CheckpointStoring,
        eventStore: any EventStoring,
        goalVerifier: any GoalVerifying,
        budget: RuntimeBudget,
        planningContext: PlanningContext,
        restoreCoordinator: (any AutonomousSessionRestoring)? = nil
    ) {
        self.planner = planner
        self.scheduler = scheduler
        self.taskRuntime = taskRuntime
        self.checkpointStore = checkpointStore
        self.eventStore = eventStore
        self.goalVerifier = goalVerifier
        self.budget = budget
        self.planningContext = planningContext
        self.restoreCoordinator = restoreCoordinator
    }

    func restore(sessionID: AgentSessionID) async throws -> AgentSessionSnapshot {
        if let session, !Self.isTerminal(session.lifecycle) {
            throw AgentOrchestratorError.sessionAlreadyActive
        }
        guard let restoreCoordinator else {
            throw AgentOrchestratorError.restoreUnavailable
        }

        pauseRequested = true
        cancellationRequested = false
        emergencyStopRequested = false

        let result = try await restoreCoordinator.restoreSession(
            streamID: "agent:\(sessionID.rawValue)"
        )
        let restoredSession = try JSONDecoder().decode(
            AgentSessionSnapshot.self,
            from: result.checkpoint.lifecycleSnapshot
        )
        let restoredGraph = try JSONDecoder().decode(
            TaskGraphSnapshot.self,
            from: result.checkpoint.taskGraphSnapshot
        )
        _ = try JSONDecoder().decode(
            RuntimeBudgetSnapshot.self,
            from: result.checkpoint.budgetSnapshot
        )

        guard restoredSession.id == sessionID,
              restoredGraph.goalID == restoredSession.goalID,
              result.checkpoint.streamID == "agent:\(sessionID.rawValue)" else {
            throw AgentOrchestratorError.invalidRestoredState
        }

        currentGoal = nil
        graph = nil
        eventSequence = max(
            result.checkpoint.eventSequence,
            result.replayedEventSequences.max() ?? result.checkpoint.eventSequence
        )

        switch result.disposition {
        case .readyToResume:
            session = restoredSession
        case .manualResolutionRequired:
            session = AgentSessionSnapshot(
                id: restoredSession.id,
                goalID: restoredSession.goalID,
                lifecycle: .manualResolutionRequired,
                verificationEvidenceID: restoredSession.verificationEvidenceID
            )
        }

        return try requireSession()
    }

    func start(goal: GoalSnapshot) async throws -> AgentSessionSnapshot {
        if let session, !Self.isTerminal(session.lifecycle) {
            throw AgentOrchestratorError.sessionAlreadyActive
        }

        let sessionID = AgentSessionID(rawValue: UUID().uuidString)
        let taskGraph = TaskGraph(goalID: goal.id, eventStore: eventStore)

        currentGoal = goal
        graph = taskGraph
        session = AgentSessionSnapshot(
            id: sessionID,
            goalID: goal.id,
            lifecycle: .created,
            verificationEvidenceID: nil
        )
        eventSequence = 0
        pauseRequested = false
        cancellationRequested = false
        emergencyStopRequested = false

        try await transitionSession(to: .planning)

        while true {
            try await waitAtSafeBoundary()
            if cancellationRequested || emergencyStopRequested {
                return try await finishCancelled()
            }

            guard let current = session else {
                throw AgentOrchestratorError.noRunnableTasks
            }

            switch current.lifecycle {
            case .planning:
                let planned = try await performPlanning(goal: goal, graph: taskGraph)
                if let terminal = planned {
                    return terminal
                }
                try await transitionSession(to: .ready)

            case .ready:
                let graphSnapshot = await taskGraph.snapshot()
                let orderedTasks = graphSnapshot.tasks.values.sorted {
                    $0.id.rawValue < $1.id.rawValue
                }
                let selectedTaskIDs = await scheduler.select(from: orderedTasks)

                guard !selectedTaskIDs.isEmpty else {
                    try await transitionSession(to: .blocked)
                    return try requireSession()
                }

                try await transitionSession(to: .executing)

                var rejectedTaskID: TaskID?
                for taskID in selectedTaskIDs {
                    try await waitAtSafeBoundary()
                    if cancellationRequested || emergencyStopRequested {
                        return try await finishCancelled()
                    }

                    let snapshot = await taskGraph.snapshot()
                    guard let task = snapshot.tasks[taskID], task.lifecycle == .ready else {
                        continue
                    }

                    try await taskGraph.transition(taskID: taskID, to: .running, evidence: nil)
                    if task.plannedInvocation != nil {
                        do {
                            try await budget.reserveToolCall()
                        } catch {
                            try await taskGraph.transition(taskID: taskID, to: .failed, evidence: nil)
                            try await transitionSession(to: .failed)
                            return try requireSession()
                        }
                    }

                    do {
                        let result = try await taskRuntime.run(task)
                        switch result.lifecycle {
                        case .succeeded:
                            try await taskGraph.transition(
                                taskID: taskID,
                                to: .verifying,
                                evidence: nil
                            )
                            guard let evidence = result.verificationEvidence.last else {
                                try await taskGraph.transition(
                                    taskID: taskID,
                                    to: .failed,
                                    evidence: nil
                                )
                                rejectedTaskID = taskID
                                break
                            }
                            try await taskGraph.transition(
                                taskID: taskID,
                                to: .succeeded,
                                evidence: evidence
                            )

                        case .failed:
                            try await taskGraph.transition(
                                taskID: taskID,
                                to: .verifying,
                                evidence: nil
                            )
                            try await taskGraph.transition(
                                taskID: taskID,
                                to: .failed,
                                evidence: nil
                            )
                            rejectedTaskID = taskID

                        case .cancelled:
                            try await taskGraph.transition(
                                taskID: taskID,
                                to: .cancelled,
                                evidence: nil
                            )
                            return try await finishCancelled()

                        default:
                            try await taskGraph.transition(
                                taskID: taskID,
                                to: .failed,
                                evidence: nil
                            )
                            rejectedTaskID = taskID
                        }
                    } catch let error as ToolFabricError {
                        try await taskGraph.transition(taskID: taskID, to: .failed, evidence: nil)
                        if case .policyDenied = error {
                            try await transitionSession(to: .blocked)
                            return try requireSession()
                        }
                        rejectedTaskID = taskID
                    } catch is CancellationError {
                        try await taskGraph.transition(taskID: taskID, to: .cancelled, evidence: nil)
                        return try await finishCancelled()
                    } catch {
                        try await taskGraph.transition(taskID: taskID, to: .failed, evidence: nil)
                        rejectedTaskID = taskID
                    }

                    if rejectedTaskID != nil {
                        break
                    }
                }

                if cancellationRequested || emergencyStopRequested {
                    return try await finishCancelled()
                }

                try await transitionSession(to: .observing)

                if let rejectedTaskID {
                    let recovered = try await prepareRecovery(
                        taskID: rejectedTaskID,
                        graph: taskGraph
                    )
                    if recovered {
                        try await transitionSession(to: .planning)
                        continue
                    }
                    try await transitionSession(to: .failed)
                    return try requireSession()
                }

                try await transitionSession(to: .verifying)
                let verificationGraphSnapshot = await taskGraph.snapshot()
                let verification = try await goalVerifier.verify(
                    goal: goal,
                    graph: verificationGraphSnapshot
                )

                if verification.completed, let evidence = verification.evidence {
                    try await transitionSession(
                        to: .completed,
                        verificationEvidenceID: evidence.evidenceID
                    )
                    return try requireSession()
                }

                if Self.hasPendingWork(verificationGraphSnapshot) {
                    try await transitionSession(to: .planning)
                    continue
                }

                let canRecover = try await reserveGoalRecovery(graphSnapshot: verificationGraphSnapshot)
                if canRecover {
                    try await transitionSession(to: .planning)
                    continue
                }

                try await transitionSession(to: .failed)
                return try requireSession()

            case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
                return current

            case .created, .executing, .observing, .verifying:
                try await transitionSession(to: .failed)
                return try requireSession()
            }
        }
    }

    func pause() {
        guard let session, !Self.isTerminal(session.lifecycle) else {
            return
        }
        pauseRequested = true
    }

    func resume() throws {
        if session?.lifecycle == .manualResolutionRequired {
            throw AgentOrchestratorError.manualResolutionRequired
        }
        pauseRequested = false
    }

    func cancel() async {
        guard let session, !Self.isTerminal(session.lifecycle) else {
            return
        }
        cancellationRequested = true
        pauseRequested = false
        await taskRuntime.cancel()
    }

    func emergencyStop() async {
        guard let session, !Self.isTerminal(session.lifecycle) else {
            return
        }
        emergencyStopRequested = true
        cancellationRequested = true
        pauseRequested = false
        await taskRuntime.cancel()
    }

    func snapshot() -> AgentSessionSnapshot? {
        session
    }

    func isPaused() -> Bool {
        pauseRequested
    }

    private func performPlanning(
        goal: GoalSnapshot,
        graph taskGraph: TaskGraph
    ) async throws -> AgentSessionSnapshot? {
        do {
            try await budget.reserveModelCall()
            let graphSnapshot = await taskGraph.snapshot()
            let budgetSnapshot = try await budget.snapshot()
            let proposal = try await planner.propose(
                goal: goal,
                graph: graphSnapshot,
                budgets: budgetSnapshot,
                context: planningContext
            )
            try await apply(proposal: proposal, to: taskGraph)
            try await promoteReadyTasks(in: taskGraph)

            let updated = await taskGraph.snapshot()
            if updated.tasks.isEmpty {
                try await transitionSession(to: .failed)
                return try requireSession()
            }
            if !Self.hasRunnableOrPendingWork(updated) {
                try await transitionSession(to: .blocked)
                return try requireSession()
            }
            return nil
        } catch {
            if cancellationRequested || emergencyStopRequested {
                return try await finishCancelled()
            }
            try await transitionSession(to: .failed)
            return try requireSession()
        }
    }

    private func apply(
        proposal: PlanningProposal,
        to taskGraph: TaskGraph
    ) async throws {
        var nodesByID = Dictionary(
            uniqueKeysWithValues: proposal.addTasks.map { ($0.id, $0) }
        )

        guard nodesByID.count == proposal.addTasks.count else {
            throw AgentOrchestratorError.invalidPlanningProposal
        }

        for dependency in proposal.addDependencies {
            guard var node = nodesByID[dependency.taskID] else {
                throw AgentOrchestratorError.invalidPlanningProposal
            }
            node.dependencies.insert(dependency.dependsOn)
            nodesByID[dependency.taskID] = node
        }

        for task in proposal.addTasks {
            guard let node = nodesByID[task.id] else {
                throw AgentOrchestratorError.invalidPlanningProposal
            }
            try await taskGraph.add(node)
        }

        for taskID in proposal.markBlocked {
            let snapshot = await taskGraph.snapshot()
            guard let node = snapshot.tasks[taskID] else {
                throw AgentOrchestratorError.invalidPlanningProposal
            }
            if node.lifecycle == .created {
                try await taskGraph.transition(taskID: taskID, to: .blocked, evidence: nil)
            }
        }
    }

    private func promoteReadyTasks(in taskGraph: TaskGraph) async throws {
        let snapshot = await taskGraph.snapshot()
        for node in snapshot.tasks.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard node.lifecycle == .created || node.lifecycle == .replanned else {
                continue
            }
            let dependenciesSatisfied = node.dependencies.allSatisfy { dependencyID in
                snapshot.tasks[dependencyID]?.lifecycle == .succeeded
            }
            if dependenciesSatisfied {
                try await taskGraph.transition(taskID: node.id, to: .ready, evidence: nil)
            }
        }
    }

    private func prepareRecovery(
        taskID: TaskID,
        graph taskGraph: TaskGraph
    ) async throws -> Bool {
        do {
            try await budget.reserveRecoveryAttempt(
                failureFingerprint: "task-verification:\(taskID.rawValue)",
                strategyID: "retry:\(eventSequence)"
            )
            try await taskGraph.transition(taskID: taskID, to: .recovering, evidence: nil)
            try await taskGraph.transition(taskID: taskID, to: .ready, evidence: nil)
            return true
        } catch let error as RuntimeBudgetError {
            if error == .recoveryAttemptLimitExceeded || error == .duplicateRecoveryStrategy {
                return false
            }
            throw error
        }
    }

    private func reserveGoalRecovery(
        graphSnapshot: TaskGraphSnapshot
    ) async throws -> Bool {
        do {
            try await budget.reserveRecoveryAttempt(
                failureFingerprint: "goal-verification:\(graphSnapshot.revision)",
                strategyID: "replan:\(eventSequence)"
            )
            return true
        } catch let error as RuntimeBudgetError {
            if error == .recoveryAttemptLimitExceeded || error == .duplicateRecoveryStrategy {
                return false
            }
            throw error
        }
    }

    private func waitAtSafeBoundary() async throws {
        while pauseRequested && !cancellationRequested && !emergencyStopRequested {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func finishCancelled() async throws -> AgentSessionSnapshot {
        guard let current = session else {
            throw AgentOrchestratorError.noRunnableTasks
        }
        if current.lifecycle != .cancelled {
            try await transitionSession(to: .cancelled)
        }
        return try requireSession()
    }

    private func transitionSession(
        to lifecycle: AgentLifecycle,
        verificationEvidenceID: String? = nil
    ) async throws {
        guard var current = session else {
            throw AgentOrchestratorError.noRunnableTasks
        }
        try current.transition(
            to: lifecycle,
            verificationEvidenceID: verificationEvidenceID
        )
        session = current
        try await persistCurrentState()
    }

    private func persistCurrentState() async throws {
        guard let session, let graph else {
            throw AgentOrchestratorError.noRunnableTasks
        }

        eventSequence += 1
        let graphSnapshot = await graph.snapshot()
        let lifecyclePayload = AgentLifecycleEventPayload(
            sessionID: session.id,
            goalID: session.goalID,
            lifecycle: session.lifecycle,
            verificationEvidenceID: session.verificationEvidenceID
        )
        let payload = try JSONEncoder().encode(lifecyclePayload)
        let streamID = "agent:\(session.id.rawValue)"
        let event = RuntimeEvent(
            eventID: RuntimeEventID(rawValue: UUID().uuidString),
            streamID: streamID,
            sequence: eventSequence,
            schemaVersion: 1,
            goalID: session.goalID,
            taskID: nil,
            sessionID: SessionID(rawValue: session.id.rawValue),
            eventKind: .runtime,
            causationID: nil,
            correlationID: session.id.rawValue,
            taskGraphRevision: graphSnapshot.revision,
            toolRegistryRevision: planningContext.registry.revision,
            policyRevision: nil,
            payload: payload,
            redactionClass: .normal,
            provenance: "agent-orchestrator",
            tainted: false,
            recordedAt: Date()
        )
        try await eventStore.append(event)

        let budgetSnapshot = try await budget.snapshot()
        let checkpoint = RuntimeCheckpoint(
            streamID: streamID,
            eventSequence: eventSequence,
            taskGraphRevision: graphSnapshot.revision,
            taskGraphSnapshot: try JSONEncoder().encode(graphSnapshot),
            lifecycleSnapshot: try JSONEncoder().encode(session),
            budgetSnapshot: try JSONEncoder().encode(budgetSnapshot),
            boundedWorkingMemory: Data("{}".utf8),
            providerContinuationMetadata: nil,
            createdAt: Date()
        )
        try await checkpointStore.save(checkpoint)
    }

    private func requireSession() throws -> AgentSessionSnapshot {
        guard let session else {
            throw AgentOrchestratorError.noRunnableTasks
        }
        return session
    }

    private static func isTerminal(_ lifecycle: AgentLifecycle) -> Bool {
        switch lifecycle {
        case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
            return true
        case .created, .planning, .ready, .executing, .observing, .verifying:
            return false
        }
    }

    private static func hasPendingWork(_ snapshot: TaskGraphSnapshot) -> Bool {
        snapshot.tasks.values.contains { task in
            switch task.lifecycle {
            case .created, .blocked, .ready, .planning, .running, .verifying,
                 .failed, .recovering, .replanned, .waitingExternal,
                 .waitingApproval, .paused:
                return true
            case .succeeded, .exhausted, .cancelled:
                return false
            }
        }
    }

    private static func hasRunnableOrPendingWork(_ snapshot: TaskGraphSnapshot) -> Bool {
        snapshot.tasks.values.contains { task in
            switch task.lifecycle {
            case .created, .ready, .planning, .running, .verifying,
                 .failed, .recovering, .replanned, .waitingExternal,
                 .waitingApproval, .paused:
                return true
            case .blocked, .succeeded, .exhausted, .cancelled:
                return false
            }
        }
    }
}
