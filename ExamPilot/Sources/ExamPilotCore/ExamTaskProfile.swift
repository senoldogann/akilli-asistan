public struct ExamTaskProfile: Equatable {
    public let state: ExamRuntimeState

    public init(state: ExamRuntimeState) {
        self.state = state
    }

    public var navigationAllowed: Bool {
        state.uiPhase == .stable && state.answerState == .verified
    }
}
