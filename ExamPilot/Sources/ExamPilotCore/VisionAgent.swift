import Foundation

public struct ExamObservationState: Codable, Equatable {
    public var cycle: Int
    public var nonProgressCount: Int
    public var lastSummary: String?
    public var stateVersion: UInt64
    public var questionGeneration: UInt64
    public var answerVerified: Bool
    public var uiPhase: ExamUIPhase
    public var sessionID: String
    public var workingMemory: AgentWorkingMemorySnapshot
    public var providerContinuationAvailable: Bool

    public init(
        cycle: Int,
        nonProgressCount: Int,
        lastSummary: String?,
        stateVersion: UInt64 = 0,
        questionGeneration: UInt64 = 1,
        answerVerified: Bool = false,
        uiPhase: ExamUIPhase = .stable,
        sessionID: String = "unscoped",
        workingMemory: AgentWorkingMemorySnapshot = AgentWorkingMemorySnapshot(),
        providerContinuationAvailable: Bool = false
    ) {
        self.cycle = cycle
        self.nonProgressCount = nonProgressCount
        self.lastSummary = lastSummary
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.answerVerified = answerVerified
        self.uiPhase = uiPhase
        self.sessionID = sessionID
        self.workingMemory = workingMemory
        self.providerContinuationAvailable = providerContinuationAvailable
    }
}

public protocol VisionAgent: AnyObject {
    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision
}

public enum VisionAgentError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case missingOutputText
    case invalidDecision

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Responses API endpoint URL is invalid."
        case .invalidResponse:
            return "The Responses API returned an invalid HTTP response."
        case .httpStatus(let status):
            return "The Responses API returned HTTP \(status)."
        case .missingOutputText:
            return "The Responses API response did not contain output_text."
        case .invalidDecision:
            return "The model output could not be decoded as an ExamDecision."
        }
    }
}
