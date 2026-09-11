nonisolated struct ContextQuery: Sendable, Equatable {
    let text: String
    let conversationID: String
    let activeGoalID: GoalID?
}

nonisolated protocol ContextSource: Sendable {
    var kind: ContextSourceKind { get }
    func candidates(for query: ContextQuery) async throws -> [ContextItem]
}
