import Foundation

nonisolated struct AskRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversationID: String
    let text: String
    let selection: ProviderSelectionSnapshot
    let activeGoalID: GoalID?
    /// JPEG payload for a vision turn. The bound provider must advertise
    /// `ModelCapabilities.vision` or the request fails closed.
    let imageData: Data?

    nonisolated init(
        sessionID: ModelSessionID,
        conversationID: String,
        text: String,
        selection: ProviderSelectionSnapshot,
        activeGoalID: GoalID?,
        imageData: Data? = nil
    ) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.text = text
        self.selection = selection
        self.activeGoalID = activeGoalID
        self.imageData = imageData
    }
}

nonisolated enum RequestCoordinatorError: Error, Sendable, Equatable {
    case emptyUserText
    case visionUnsupported
}

extension RequestCoordinatorError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .emptyUserText:
            return "The request did not contain any text to send."
        case .visionUnsupported:
            return "The selected provider does not support image analysis. Choose a vision-capable provider in Settings."
        }
    }
}
