import Foundation
import OSLog

public extension AgentFailureReason {
    var diagnosticID: String {
        switch self {
        case .targetMiss:
            return "target_miss"
        case .noVisibleEffect:
            return "no_visible_effect"
        case .staleObservation:
            return "stale_observation"
        case .transitionStillRunning:
            return "transition_still_running"
        case .focusDrift:
            return "focus_drift"
        case .stateMismatch:
            return "state_mismatch"
        case .invalidModelPlan:
            return "invalid_model_plan"
        case .repeatedIntentLoop:
            return "repeated_intent_loop"
        case .targetNotVisible:
            return "target_not_visible"
        case .unknown:
            return "unknown"
        }
    }
}

public struct AgentEventDiagnosticFormatter {
    private static let allowedDetailCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-"
    )

    public init() {}

    public func format(_ event: AgentEvent) -> String {
        let detail = sanitizedDetail(event.detail)
        return "[cycle \(event.cycle)] q=\(event.questionGeneration) state=\(event.stateVersion) \(event.kind.rawValue) \(detail)"
    }

    private func sanitizedDetail(_ detail: String) -> String {
        guard !detail.isEmpty,
              detail.count <= 64,
              detail.unicodeScalars.allSatisfy({ Self.allowedDetailCharacters.contains($0) }) else {
            return "redacted_detail"
        }
        return detail
    }
}

public final class DiagnosticAgentEventSink: AgentEventSinking {
    private let formatter: AgentEventDiagnosticFormatter
    private let logger: Logger
    private let writeLine: (String) -> Void

    public init(
        formatter: AgentEventDiagnosticFormatter = AgentEventDiagnosticFormatter(),
        logger: Logger = Logger(
            subsystem: "com.senoldogan.akilli-asistan.exampilot",
            category: "Runtime"
        ),
        writeLine: @escaping (String) -> Void = { _ in }
    ) {
        self.formatter = formatter
        self.logger = logger
        self.writeLine = writeLine
    }

    public func record(_ event: AgentEvent) {
        let line = formatter.format(event)
        logger.info("\(line, privacy: .public)")
        writeLine(line)
    }
}
