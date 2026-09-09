import Foundation

public final class AccessibilityFusingVisionAgent: VisionAgent {
    private let base: VisionAgent
    private let observer: AccessibilityObserving
    private let fusion: AccessibilityObservationFusion

    public init(
        base: VisionAgent,
        observer: AccessibilityObserving,
        fusion: AccessibilityObservationFusion = AccessibilityObservationFusion()
    ) {
        self.base = base
        self.observer = observer
        self.fusion = fusion
    }

    public func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        var enrichedState = state

        if let snapshot = try? observer.observe(
            target: frame,
            stateVersion: state.stateVersion
        ) {
            enrichedState.accessibility = fusion.fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: state.stateVersion
            )
        } else {
            enrichedState.accessibility = nil
        }

        return try await base.decide(frame: frame, state: enrichedState)
    }
}
