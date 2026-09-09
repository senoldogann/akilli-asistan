struct ReplayState: Sendable, Equatable {
    let eventSequences: [UInt64]
    let toolReceipts: [ToolExecutionReceipt]
}

struct ReplayRuntime: Sendable {
    let events: [RuntimeEvent]
    let executor: ReplayToolExecutor

    func run() async throws -> ReplayState {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.eventID.rawValue < rhs.eventID.rawValue
            }
            return lhs.sequence < rhs.sequence
        }

        var receipts: [ToolExecutionReceipt] = []
        for event in orderedEvents {
            guard event.schemaVersion == 1 else {
                throw ReplayError.unsupportedSchemaVersion(event.schemaVersion)
            }

            switch event.eventKind {
            case .tool:
                receipts.append(try executor.receipt(for: event))
            default:
                continue
            }
        }

        return ReplayState(
            eventSequences: orderedEvents.map(\.sequence),
            toolReceipts: receipts
        )
    }
}
