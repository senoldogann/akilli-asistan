import Foundation

public struct AgentActionMemory: Codable, Equatable {
    public let sequence: UInt64
    public let stateVersion: UInt64
    public let questionGeneration: UInt64
    public let intent: AgentIntentFingerprint

    public init(
        sequence: UInt64,
        stateVersion: UInt64,
        questionGeneration: UInt64,
        intent: AgentIntentFingerprint
    ) {
        self.sequence = sequence
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.intent = intent
    }
}

public struct AgentFailureMemory: Codable, Equatable {
    public let sequence: UInt64
    public let stateVersion: UInt64
    public let questionGeneration: UInt64
    public let reason: AgentFailureReason
    public let recoveryStrategy: RecoveryStrategy?

    public init(
        sequence: UInt64,
        stateVersion: UInt64,
        questionGeneration: UInt64,
        reason: AgentFailureReason,
        recoveryStrategy: RecoveryStrategy?
    ) {
        self.sequence = sequence
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.reason = reason
        self.recoveryStrategy = recoveryStrategy
    }
}

public struct AgentEvidenceMemory: Codable, Equatable {
    public let sequence: UInt64
    public let stateVersion: UInt64
    public let questionGeneration: UInt64
    public let outcome: ExpectedOutcomeKind

    public init(
        sequence: UInt64,
        stateVersion: UInt64,
        questionGeneration: UInt64,
        outcome: ExpectedOutcomeKind
    ) {
        self.sequence = sequence
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.outcome = outcome
    }
}

public struct AgentWorkingMemorySnapshot: Codable, Equatable {
    public let actions: [AgentActionMemory]
    public let failures: [AgentFailureMemory]
    public let evidence: [AgentEvidenceMemory]
    public let currentRecoveryStrategy: RecoveryStrategy?

    public init(
        actions: [AgentActionMemory] = [],
        failures: [AgentFailureMemory] = [],
        evidence: [AgentEvidenceMemory] = [],
        currentRecoveryStrategy: RecoveryStrategy? = nil
    ) {
        self.actions = actions
        self.failures = failures
        self.evidence = evidence
        self.currentRecoveryStrategy = currentRecoveryStrategy
    }
}

public final class AgentWorkingMemory {
    private let maxActions: Int
    private let maxFailures: Int
    private let maxEvidence: Int

    private var actions: [AgentActionMemory] = []
    private var failures: [AgentFailureMemory] = []
    private var evidence: [AgentEvidenceMemory] = []
    private var currentRecoveryStrategy: RecoveryStrategy?

    public init(
        maxActions: Int = 12,
        maxFailures: Int = 12,
        maxEvidence: Int = 8
    ) {
        self.maxActions = max(1, maxActions)
        self.maxFailures = max(1, maxFailures)
        self.maxEvidence = max(1, maxEvidence)
    }

    public func recordAction(
        _ intent: AgentIntentFingerprint,
        sequence: UInt64,
        stateVersion: UInt64,
        questionGeneration: UInt64
    ) {
        actions.append(
            AgentActionMemory(
                sequence: sequence,
                stateVersion: stateVersion,
                questionGeneration: questionGeneration,
                intent: intent
            )
        )
        trim(&actions, to: maxActions)
    }

    public func recordFailure(
        _ reason: AgentFailureReason,
        recoveryStrategy: RecoveryStrategy?,
        sequence: UInt64,
        stateVersion: UInt64,
        questionGeneration: UInt64
    ) {
        failures.append(
            AgentFailureMemory(
                sequence: sequence,
                stateVersion: stateVersion,
                questionGeneration: questionGeneration,
                reason: reason,
                recoveryStrategy: recoveryStrategy
            )
        )
        trim(&failures, to: maxFailures)
    }

    public func recordEvidence(
        _ outcome: ExpectedOutcomeKind,
        sequence: UInt64,
        stateVersion: UInt64,
        questionGeneration: UInt64
    ) {
        evidence.append(
            AgentEvidenceMemory(
                sequence: sequence,
                stateVersion: stateVersion,
                questionGeneration: questionGeneration,
                outcome: outcome
            )
        )
        trim(&evidence, to: maxEvidence)
    }

    public func setCurrentRecoveryStrategy(_ strategy: RecoveryStrategy?) {
        currentRecoveryStrategy = strategy
    }

    public func snapshot() -> AgentWorkingMemorySnapshot {
        AgentWorkingMemorySnapshot(
            actions: actions,
            failures: failures,
            evidence: evidence,
            currentRecoveryStrategy: currentRecoveryStrategy
        )
    }

    private func trim<T>(_ values: inout [T], to limit: Int) {
        guard values.count > limit else { return }
        values.removeFirst(values.count - limit)
    }
}
