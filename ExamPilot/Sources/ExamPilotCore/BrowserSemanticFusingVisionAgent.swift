import Foundation

public final class BrowserSemanticFusingVisionAgent: VisionAgent {
    private let base: VisionAgent
    private let observer: BrowserSemanticObserving
    private let fusion: BrowserSemanticObservationFusion

    public init(
        base: VisionAgent,
        observer: BrowserSemanticObserving,
        fusion: BrowserSemanticObservationFusion = BrowserSemanticObservationFusion()
    ) {
        self.base = base
        self.observer = observer
        self.fusion = fusion
    }

    public func decide(
        frame: ScreenFrame,
        state: ExamObservationState
    ) async throws -> ExamDecision {
        var enrichedState = state

        if let snapshot = try? await observer.observe(
            target: frame,
            stateVersion: state.stateVersion
        ) {
            enrichedState.browserSemantics = fusion.fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: state.stateVersion
            )
        } else {
            enrichedState.browserSemantics = nil
        }

        return try await base.decide(frame: frame, state: enrichedState)
    }
}
