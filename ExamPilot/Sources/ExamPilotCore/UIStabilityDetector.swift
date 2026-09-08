import CoreGraphics

public struct UIStabilityDetector {
    private let changeDetector: VisualChangeDetector

    public init(gridSize: Int = 24, threshold: Double = 0.015) {
        self.changeDetector = VisualChangeDetector(gridSize: gridSize, threshold: threshold)
    }

    public func isStable(previous: CGImage, current: CGImage) -> Bool {
        !changeDetector.hasMeaningfulChange(before: previous, after: current)
    }
}
