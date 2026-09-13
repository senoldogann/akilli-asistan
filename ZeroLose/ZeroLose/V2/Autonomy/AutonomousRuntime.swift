import Foundation

enum AutonomousRuntimeLifecycle: String, Sendable, Equatable {
    case initialized
    case restoring
    case paused
    case completed
}

enum AutonomousRuntimeError: Error, Equatable {
    case checkpointUnavailable
    case manualResolutionRequired
}

protocol RuntimeRegistryRefreshing: Sendable {
    func refreshRegistry() async throws
}

protocol CredentialHandleDiscarding: Sendable {
    func discardCredentialHandles() async throws
}

protocol CurrentPolicyLoading: Sendable {
    func loadCurrentPolicy() async throws
}

protocol WorldReobserving: Sendable {
    func reobserveWorld() async throws
}

protocol OutstandingMutationReconciling: Sendable {
    func reconcileOutstandingMutations() async throws
}

protocol ReadinessRebuilding: Sendable {
    func rebuildReadiness() async throws
}

enum AutonomousRestoreDisposition: Sendable, Equatable {
    case readyToResume
    case manualResolutionRequired
}

struct AutonomousRestoreResult: Sendable, Equatable {
    let checkpoint: RuntimeCheckpoint
    let replayedEventSequences: [UInt64]
    let disposition: AutonomousRestoreDisposition
}

protocol AutonomousSessionRestoring: Sendable {
    func restoreSession(streamID: String) async throws -> AutonomousRestoreResult
}

struct AutonomousRuntimeRestoreCoordinator: AutonomousSessionRestoring {
    private let checkpointStore: any CheckpointStoring
    private let eventStore: any EventStoring
    private let replayExecutor: any ReplayExecuting
    private let registryRefresher: any RuntimeRegistryRefreshing
    private let credentialHandleDiscarder: any CredentialHandleDiscarding
    private let currentPolicyLoader: any CurrentPolicyLoading
    private let worldReobserver: any WorldReobserving
    private let mutationReconciler: any OutstandingMutationReconciling
    private let readinessRebuilder: any ReadinessRebuilding

    init(
        checkpointStore: any CheckpointStoring,
        eventStore: any EventStoring,
        replayExecutor: any ReplayExecuting,
        registryRefresher: any RuntimeRegistryRefreshing,
        credentialHandleDiscarder: any CredentialHandleDiscarding,
        currentPolicyLoader: any CurrentPolicyLoading,
        worldReobserver: any WorldReobserving,
        mutationReconciler: any OutstandingMutationReconciling,
        readinessRebuilder: any ReadinessRebuilding
    ) {
        self.checkpointStore = checkpointStore
        self.eventStore = eventStore
        self.replayExecutor = replayExecutor
        self.registryRefresher = registryRefresher
        self.credentialHandleDiscarder = credentialHandleDiscarder
        self.currentPolicyLoader = currentPolicyLoader
        self.worldReobserver = worldReobserver
        self.mutationReconciler = mutationReconciler
        self.readinessRebuilder = readinessRebuilder
    }

    func restoreSession(streamID: String) async throws -> AutonomousRestoreResult {
        guard let checkpoint = try await checkpointStore.latest(streamID: streamID) else {
            throw AutonomousRuntimeError.checkpointUnavailable
        }

        let subsequentEvents = try await eventStore.events(
            streamID: checkpoint.streamID,
            after: checkpoint.eventSequence
        )
        let replayState = try await ReplayRuntime(
            events: subsequentEvents,
            executor: replayExecutor
        ).run()

        try await registryRefresher.refreshRegistry()
        try await credentialHandleDiscarder.discardCredentialHandles()
        try await currentPolicyLoader.loadCurrentPolicy()
        try await worldReobserver.reobserveWorld()

        do {
            try await mutationReconciler.reconcileOutstandingMutations()
        } catch AutonomousRuntimeError.manualResolutionRequired {
            return AutonomousRestoreResult(
                checkpoint: checkpoint,
                replayedEventSequences: replayState.eventSequences,
                disposition: .manualResolutionRequired
            )
        }

        try await readinessRebuilder.rebuildReadiness()
        return AutonomousRestoreResult(
            checkpoint: checkpoint,
            replayedEventSequences: replayState.eventSequences,
            disposition: .readyToResume
        )
    }
}

actor AutonomousRuntime {
    let streamID: String
    let goal: GoalSnapshot

    private let graph: TaskGraph
    private let checkpointStore: any CheckpointStoring
    private let eventStore: any EventStoring
    private let replayExecutor: any ReplayExecuting
    private let registryRefresher: any RuntimeRegistryRefreshing
    private let credentialHandleDiscarder: any CredentialHandleDiscarding
    private let currentPolicyLoader: any CurrentPolicyLoading
    private let worldReobserver: any WorldReobserving
    private let mutationReconciler: any OutstandingMutationReconciling
    private let readinessRebuilder: any ReadinessRebuilding
    private let goalVerifier: any GoalVerifying
    private let restoreCoordinator: AutonomousRuntimeRestoreCoordinator

    private(set) var lifecycle: AutonomousRuntimeLifecycle = .initialized
    private(set) var requiresReconciliation = false
    private(set) var replayedEventSequences: [UInt64] = []

    init(
        streamID: String,
        goal: GoalSnapshot,
        graph: TaskGraph,
        checkpointStore: any CheckpointStoring,
        eventStore: any EventStoring,
        replayExecutor: any ReplayExecuting,
        registryRefresher: any RuntimeRegistryRefreshing,
        credentialHandleDiscarder: any CredentialHandleDiscarding,
        currentPolicyLoader: any CurrentPolicyLoading,
        worldReobserver: any WorldReobserving,
        mutationReconciler: any OutstandingMutationReconciling,
        readinessRebuilder: any ReadinessRebuilding,
        goalVerifier: any GoalVerifying
    ) {
        self.streamID = streamID
        self.goal = goal
        self.graph = graph
        self.checkpointStore = checkpointStore
        self.eventStore = eventStore
        self.replayExecutor = replayExecutor
        self.registryRefresher = registryRefresher
        self.credentialHandleDiscarder = credentialHandleDiscarder
        self.currentPolicyLoader = currentPolicyLoader
        self.worldReobserver = worldReobserver
        self.mutationReconciler = mutationReconciler
        self.readinessRebuilder = readinessRebuilder
        self.goalVerifier = goalVerifier
        self.restoreCoordinator = AutonomousRuntimeRestoreCoordinator(
            checkpointStore: checkpointStore,
            eventStore: eventStore,
            replayExecutor: replayExecutor,
            registryRefresher: registryRefresher,
            credentialHandleDiscarder: credentialHandleDiscarder,
            currentPolicyLoader: currentPolicyLoader,
            worldReobserver: worldReobserver,
            mutationReconciler: mutationReconciler,
            readinessRebuilder: readinessRebuilder
        )
    }

    func restore() async throws {
        lifecycle = .restoring
        requiresReconciliation = true
        replayedEventSequences = []

        do {
            let result = try await restoreCoordinator.restoreSession(streamID: streamID)
            replayedEventSequences = result.replayedEventSequences
            requiresReconciliation = result.disposition == .manualResolutionRequired
            lifecycle = .paused
        } catch {
            lifecycle = .paused
            requiresReconciliation = true
            throw error
        }
    }

    func evaluateGoalCompletion() async throws -> GoalVerificationResult {
        let graphSnapshot = await graph.snapshot()
        let verification = try await goalVerifier.verify(
            goal: goal,
            graph: graphSnapshot
        )

        guard verification.completed, let evidence = verification.evidence else {
            return GoalVerificationResult(completed: false, evidence: nil)
        }

        lifecycle = .completed
        return GoalVerificationResult(completed: true, evidence: evidence)
    }
}
