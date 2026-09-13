import Foundation

nonisolated struct AskRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversationID: String
    let text: String
    let selection: ProviderSelectionSnapshot
    let activeGoalID: GoalID?

    nonisolated init(
        sessionID: ModelSessionID,
        conversationID: String,
        text: String,
        selection: ProviderSelectionSnapshot,
        activeGoalID: GoalID?
    ) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.text = text
        self.selection = selection
        self.activeGoalID = activeGoalID
    }
}

nonisolated enum RequestCoordinatorError: Error, Sendable, Equatable {
    case emptyUserText
}
