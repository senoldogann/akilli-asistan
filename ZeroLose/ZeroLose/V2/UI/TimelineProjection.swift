import Foundation
import Observation

struct VerificationProjectionPayload: Codable, Sendable, Equatable {
    let verified: Bool
    let summary: String
}

enum TimelineItemState: String, Sendable, Equatable {
    case running
    case executed
    case succeeded
    case failed
}

struct TimelineItem: Identifiable, Sendable, Equatable {
    let id: String
    let taskID: TaskID?
    var state: TimelineItemState
    var summary: String
}

@MainActor
@Observable
final class TimelineProjection {
    private(set) var items: [TimelineItem] = []

    func consume(_ event: RuntimeEvent) {
        switch event.eventKind {
        case .tool:
            applyTool(event)
        case .verification:
            applyVerification(event)
        default:
            break
        }
    }

    private func applyTool(_ event: RuntimeEvent) {
        guard let payload = try? JSONDecoder().decode(
            RuntimeToolEventPayload.self,
            from: event.payload
        ) else {
            upsertRunning(event)
            return
        }

        let itemID = "tool:\(payload.invocationID.rawValue)"
        let state: TimelineItemState
        switch payload.state {
        case .started:
            state = .running
        case .completed:
            state = .executed
        case .failed:
            state = .failed
        }

        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].state = state
            items[index].summary = payload.summary
            return
        }

        items.append(
            TimelineItem(
                id: itemID,
                taskID: event.taskID,
                state: state,
                summary: payload.summary
            )
        )
    }

    private func upsertRunning(_ event: RuntimeEvent) {
        if let taskID = event.taskID,
           let index = items.firstIndex(where: { $0.taskID == taskID }) {
            guard items[index].state != .succeeded else { return }
            items[index].state = .running
            return
        }

        items.append(
            TimelineItem(
                id: event.eventID.rawValue,
                taskID: event.taskID,
                state: .running,
                summary: "Execution completed; awaiting verification"
            )
        )
    }

    private func applyVerification(_ event: RuntimeEvent) {
        guard let payload = try? JSONDecoder().decode(
            VerificationProjectionPayload.self,
            from: event.payload
        ) else {
            return
        }

        let state: TimelineItemState = payload.verified ? .succeeded : .failed
        if let taskID = event.taskID,
           let index = items.firstIndex(where: { $0.taskID == taskID }) {
            items[index].state = state
            items[index].summary = payload.summary
            return
        }

        items.append(
            TimelineItem(
                id: event.eventID.rawValue,
                taskID: event.taskID,
                state: state,
                summary: payload.summary
            )
        )
    }
}
