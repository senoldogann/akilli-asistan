import Foundation

nonisolated struct AskRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversationID: String
    let text: String
    let modelID: String
    let activeGoalID: GoalID?

    nonisolated init(
        sessionID: ModelSessionID,
        conversationID: String,
        text: String,
        modelID: String,
        activeGoalID: GoalID?
    ) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.text = text
        self.modelID = modelID
        self.activeGoalID = activeGoalID
    }
}

nonisolated enum RequestCoordinatorError: Error, Sendable, Equatable {
    case emptyUserText
}
