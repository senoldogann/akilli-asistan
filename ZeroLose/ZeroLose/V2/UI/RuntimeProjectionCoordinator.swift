import Observation

@MainActor
@Observable
final class RuntimeProjectionCoordinator {
    private let eventStore: any EventStoring
    private let streamID: String
    private let timeline: TimelineProjection

    private(set) var lastSequence: UInt64 = 0
    private(set) var lastError: String?

    init(
        eventStore: any EventStoring,
        streamID: String = "runtime:main",
        timeline: TimelineProjection
    ) {
        self.eventStore = eventStore
        self.streamID = streamID
        self.timeline = timeline
    }

    func refresh() async {
        do {
            let events = try await eventStore.events(streamID: streamID, after: lastSequence)
            for event in events {
                timeline.consume(event)
                lastSequence = max(lastSequence, event.sequence)
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }
}
