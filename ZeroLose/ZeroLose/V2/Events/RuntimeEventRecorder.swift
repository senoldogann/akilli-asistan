import Foundation

enum RuntimeToolEventState: String, Codable, Sendable, Equatable {
    case started
    case completed
    case failed
}

struct RuntimeToolEventPayload: Codable, Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let state: RuntimeToolEventState
    let summary: String
}

actor RuntimeEventRecorder {
    private let eventStore: any EventStoring
    private let streamID: String
    private var nextSequence: UInt64?

    init(eventStore: any EventStoring, streamID: String = "runtime:main") {
        self.eventStore = eventStore
        self.streamID = streamID
    }

    func recordTool(
        invocationID: InvocationID,
        toolID: ToolID,
        state: RuntimeToolEventState,
        summary: String,
        tainted: Bool
    ) async throws {
        let sequence = try await allocateSequence()
        let payload = RuntimeToolEventPayload(
            invocationID: invocationID,
            toolID: toolID,
            state: state,
            summary: summary
        )
        let encoded = try JSONEncoder().encode(payload)
        let event = RuntimeEvent(
            eventID: RuntimeEventID(rawValue: UUID().uuidString),
            streamID: streamID,
            sequence: sequence,
            schemaVersion: 1,
            goalID: nil,
            taskID: nil,
            sessionID: nil,
            eventKind: .tool,
            causationID: nil,
            correlationID: invocationID.rawValue,
            taskGraphRevision: nil,
            toolRegistryRevision: nil,
            policyRevision: nil,
            payload: encoded,
            redactionClass: .normal,
            provenance: "v2-native-tool-runtime",
            tainted: tainted,
            recordedAt: Date()
        )
        try await eventStore.append(event)
    }

    private func allocateSequence() async throws -> UInt64 {
        if nextSequence == nil {
            let existing = try await eventStore.events(streamID: streamID, after: 0)
            let latest = existing.last?.sequence ?? 0
            nextSequence = latest == UInt64.max ? UInt64.max : latest + 1
        }

        guard let sequence = nextSequence, sequence < UInt64.max else {
            throw RuntimeEventRecorderError.sequenceExhausted
        }
        nextSequence = sequence + 1
        return sequence
    }
}

enum RuntimeEventRecorderError: Error, Equatable {
    case sequenceExhausted
}
