nonisolated struct AgentSessionID: Hashable, Codable, Sendable {
    let rawValue: String
}

nonisolated struct AgentSessionSnapshot: Sendable, Equatable {
    let id: AgentSessionID
    let goalID: GoalID
    private(set) var lifecycle: AgentLifecycle
    private(set) var verificationEvidenceID: String?

    mutating func transition(
        to next: AgentLifecycle,
        verificationEvidenceID: String?
    ) throws {
        let allowed: Set<AgentLifecycle>
        switch lifecycle {
        case .created:
            allowed = [.planning, .cancelled, .failed]
        case .planning:
            allowed = [.ready, .blocked, .failed, .cancelled]
        case .ready:
            allowed = [.executing, .blocked, .cancelled]
        case .executing:
            allowed = [
                .observing,
                .blocked,
                .failed,
                .cancelled,
                .manualResolutionRequired
            ]
        case .observing:
            allowed = [
                .verifying,
                .planning,
                .blocked,
                .failed,
                .cancelled,
                .manualResolutionRequired
            ]
        case .verifying:
            allowed = [.completed, .planning, .blocked, .failed, .cancelled]
        case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
            allowed = []
        }

        guard allowed.contains(next) else {
            throw AgentLifecycleError.invalidTransition(from: lifecycle, to: next)
        }
        if next == .completed, verificationEvidenceID == nil {
            throw AgentLifecycleError.completionRequiresEvidence
        }

        lifecycle = next
        if next == .completed {
            self.verificationEvidenceID = verificationEvidenceID
        }
    }
}
