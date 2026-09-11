nonisolated struct ActiveTaskContextSnapshot: Sendable, Equatable {
    let goalID: GoalID
    let summary: String
    let lifecycle: String
    let mandatoryForActiveGoal: Bool
}

nonisolated protocol ActiveTaskContextProviding: Sendable {
    func activeTask(goalID: GoalID?) async -> ActiveTaskContextSnapshot?
}

nonisolated struct ActiveTaskContextSource: ContextSource {
    let kind: ContextSourceKind = .activeTask

    private let provider: any ActiveTaskContextProviding

    init(provider: any ActiveTaskContextProviding) {
        self.provider = provider
    }

    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        guard let activeGoalID = query.activeGoalID,
              let snapshot = await provider.activeTask(goalID: activeGoalID),
              snapshot.goalID == activeGoalID else {
            return []
        }

        return [
            try ContextItem.validated(
                content: snapshot.summary,
                provenance: ContextProvenance(
                    sourceID: "active-task:\(snapshot.goalID.rawValue)",
                    kind: .activeTask,
                    timestamp: nil,
                    tainted: false,
                    sensitivity: .privateContent
                ),
                mandatory: snapshot.mandatoryForActiveGoal,
                sourceScore: 0
            )
        ]
    }
}
