import Foundation

public enum ExamAnswerState: String, Codable, Equatable {
    case unanswered
    case verified
}

public enum ExamUIPhase: String, Codable, Equatable {
    case stable
    case transitioning
}

public struct ExamRuntimeState: Codable, Equatable {
    public private(set) var stateVersion: UInt64
    public private(set) var questionGeneration: UInt64
    public private(set) var answerState: ExamAnswerState
    public private(set) var uiPhase: ExamUIPhase

    public init(
        stateVersion: UInt64 = 0,
        questionGeneration: UInt64 = 1,
        answerState: ExamAnswerState = .unanswered,
        uiPhase: ExamUIPhase = .stable
    ) {
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.answerState = answerState
        self.uiPhase = uiPhase
    }

    public var navigationAllowed: Bool {
        uiPhase == .stable && answerState == .verified
    }

    public mutating func acceptObservation() {
        advanceVersion()
    }

    public mutating func recordAnswerVerified() {
        answerState = .verified
        uiPhase = .stable
        advanceVersion()
    }

    public mutating func beginBoundaryTransition() {
        uiPhase = .transitioning
        advanceVersion()
    }

    public mutating func completeBoundaryTransition() {
        if questionGeneration < UInt64.max {
            questionGeneration += 1
        }
        answerState = .unanswered
        uiPhase = .stable
        advanceVersion()
    }

    public mutating func cancelBoundaryTransition() {
        uiPhase = .stable
        advanceVersion()
    }

    private mutating func advanceVersion() {
        if stateVersion < UInt64.max {
            stateVersion += 1
        }
    }
}
