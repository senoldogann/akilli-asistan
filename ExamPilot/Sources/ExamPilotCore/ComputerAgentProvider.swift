import Foundation

public protocol ComputerAgentProvider: AnyObject {
    func nextStep(
        frame: ScreenFrame,
        state: ComputerAgentProviderState
    ) async throws -> ComputerAgentProviderTurn
}

public struct ComputerAgentProviderState: Equatable {
    public let sessionID: String
    public let goal: String
    public let stateVersion: UInt64
    public let questionGeneration: UInt64
    public let answerVerified: Bool
    public let uiPhase: ExamUIPhase
    public let workingMemory: AgentWorkingMemorySnapshot
    public let previousResponseID: String?
    public let pendingComputerCallID: String?

    public init(
        sessionID: String,
        goal: String,
        stateVersion: UInt64,
        questionGeneration: UInt64,
        answerVerified: Bool,
        uiPhase: ExamUIPhase,
        workingMemory: AgentWorkingMemorySnapshot,
        previousResponseID: String? = nil,
        pendingComputerCallID: String? = nil
    ) {
        self.sessionID = sessionID
        self.goal = goal
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.answerVerified = answerVerified
        self.uiPhase = uiPhase
        self.workingMemory = workingMemory
        self.previousResponseID = previousResponseID
        self.pendingComputerCallID = pendingComputerCallID
    }
}

public enum NativeComputerActionKind: String, Codable, CaseIterable, Equatable {
    case click
    case doubleClick = "double_click"
    case scroll
    case type
    case wait
    case keypress
    case drag
    case move
    case screenshot
}

public struct NativeComputerPoint: Codable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct NativeComputerAction: Codable, Equatable {
    public let kind: NativeComputerActionKind
    public let x: Double?
    public let y: Double?
    public let button: String?
    public let text: String?
    public let scrollX: Double?
    public let scrollY: Double?
    public let keys: [String]?
    public let path: [NativeComputerPoint]?

    public init(
        kind: NativeComputerActionKind,
        x: Double? = nil,
        y: Double? = nil,
        button: String? = nil,
        text: String? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        keys: [String]? = nil,
        path: [NativeComputerPoint]? = nil
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.text = text
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.keys = keys
        self.path = path
    }
}

public struct ComputerAgentProviderTurn: Codable, Equatable {
    public let responseID: String
    public let computerCallID: String?
    public let actions: [NativeComputerAction]
    public let finalText: String?

    public init(
        responseID: String,
        computerCallID: String?,
        actions: [NativeComputerAction],
        finalText: String?
    ) {
        self.responseID = responseID
        self.computerCallID = computerCallID
        self.actions = actions
        self.finalText = finalText
    }

    public var isTerminal: Bool {
        computerCallID == nil && actions.isEmpty && finalText != nil
    }
}
