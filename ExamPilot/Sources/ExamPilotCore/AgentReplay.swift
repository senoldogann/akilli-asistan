import Foundation

public struct AgentReplaySnapshot: Equatable {
    public let sessionID: String?
    public let eventCount: Int
    public let lastSequence: Int64?
    public let lastCycle: Int?
    public let lastStateVersion: UInt64?
    public let lastQuestionGeneration: UInt64?
    public let historicalAnswerVerified: Bool
    public let historicalUIPhase: ExamUIPhase
    public let lastEventKind: AgentEventKind?

    public var historicalOnly: Bool { true }

    public init(
        sessionID: String?,
        eventCount: Int,
        lastSequence: Int64?,
        lastCycle: Int?,
        lastStateVersion: UInt64?,
        lastQuestionGeneration: UInt64?,
        historicalAnswerVerified: Bool,
        historicalUIPhase: ExamUIPhase,
        lastEventKind: AgentEventKind?
    ) {
        self.sessionID = sessionID
        self.eventCount = eventCount
        self.lastSequence = lastSequence
        self.lastCycle = lastCycle
        self.lastStateVersion = lastStateVersion
        self.lastQuestionGeneration = lastQuestionGeneration
        self.historicalAnswerVerified = historicalAnswerVerified
        self.historicalUIPhase = historicalUIPhase
        self.lastEventKind = lastEventKind
    }

    public static let empty = AgentReplaySnapshot(
        sessionID: nil,
        eventCount: 0,
        lastSequence: nil,
        lastCycle: nil,
        lastStateVersion: nil,
        lastQuestionGeneration: nil,
        historicalAnswerVerified: false,
        historicalUIPhase: .stable,
        lastEventKind: nil
    )
}

public struct AgentReplayProjector {
    public init() {}

    public func project(events: [StoredAgentEvent]) throws -> AgentReplaySnapshot {
        guard let first = events.first else {
            return .empty
        }
        guard first.sequence > 0 else {
            throw AgentPersistenceError.malformedRecord
        }

        let sessionID = first.event.sessionID
        var previousSequence: Int64 = 0
        var previousQuestionGeneration: UInt64?
        var historicalAnswerVerified = false
        var historicalUIPhase: ExamUIPhase = .stable

        for stored in events {
            guard stored.sequence > previousSequence,
                  stored.event.sessionID == sessionID else {
                throw AgentPersistenceError.malformedRecord
            }

            if let previousQuestionGeneration,
               stored.event.questionGeneration != previousQuestionGeneration {
                historicalAnswerVerified = false
            }

            switch stored.event.kind {
            case .answerVerified:
                historicalAnswerVerified = true
            case .boundaryTransitionStarted:
                historicalUIPhase = .transitioning
            case .boundaryTransitionCompleted:
                historicalAnswerVerified = false
                historicalUIPhase = .stable
            default:
                break
            }

            previousSequence = stored.sequence
            previousQuestionGeneration = stored.event.questionGeneration
        }

        guard let last = events.last else {
            return .empty
        }
        return AgentReplaySnapshot(
            sessionID: sessionID,
            eventCount: events.count,
            lastSequence: last.sequence,
            lastCycle: last.event.cycle,
            lastStateVersion: last.event.stateVersion,
            lastQuestionGeneration: last.event.questionGeneration,
            historicalAnswerVerified: historicalAnswerVerified,
            historicalUIPhase: historicalUIPhase,
            lastEventKind: last.event.kind
        )
    }
}

public struct AgentResumeCheckpoint: Equatable {
    public let sessionID: String
    public let replaySnapshot: AgentReplaySnapshot
    public let conversationHistory: AgentConversationRecord?
    public let memoryHistory: AgentMemoryRecord?

    public var requiresFreshObservation: Bool { true }
    public var requiresReconciliation: Bool { true }
    public var restoresRuntimeAuthority: Bool { false }

    public init(
        sessionID: String,
        replaySnapshot: AgentReplaySnapshot,
        conversationHistory: AgentConversationRecord?,
        memoryHistory: AgentMemoryRecord?
    ) throws {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty,
              sessionID == trimmed,
              sessionID.count <= 200 else {
            throw AgentPersistenceError.invalidSessionID
        }
        if let replaySessionID = replaySnapshot.sessionID,
           replaySessionID != sessionID {
            throw AgentPersistenceError.malformedRecord
        }
        if let conversationHistory,
           conversationHistory.sessionID != sessionID {
            throw AgentPersistenceError.malformedRecord
        }
        if let memoryHistory,
           memoryHistory.sessionID != sessionID {
            throw AgentPersistenceError.malformedRecord
        }

        self.sessionID = sessionID
        self.replaySnapshot = replaySnapshot
        self.conversationHistory = conversationHistory
        self.memoryHistory = memoryHistory
    }
}
