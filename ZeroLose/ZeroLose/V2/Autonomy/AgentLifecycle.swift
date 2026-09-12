nonisolated enum AgentLifecycle: String, Codable, Sendable, Equatable {
    case created
    case planning
    case ready
    case executing
    case observing
    case verifying
    case completed
    case cancelled
    case blocked
    case failed
    case manualResolutionRequired
}

nonisolated enum AgentLifecycleError: Error, Sendable, Equatable {
    case invalidTransition(from: AgentLifecycle, to: AgentLifecycle)
    case completionRequiresEvidence
}
