import CoreGraphics

public struct VisualChangeDetector {
    public let gridSize: Int
    public let threshold: Double

    public init(gridSize: Int = 24, threshold: Double = 0.035) {
        self.gridSize = max(4, gridSize)
        self.threshold = max(0, min(1, threshold))
    }

    public func score(before: CGImage, after: CGImage) -> Double {
        guard let lhs = fingerprint(before), let rhs = fingerprint(after), lhs.count == rhs.count, !lhs.isEmpty else {
            return 1
        }

        let total = zip(lhs, rhs).reduce(0.0) { partial, pair in
            partial + Double(abs(Int(pair.0) - Int(pair.1))) / 255.0
        }
        return total / Double(lhs.count)
    }

    public func hasMeaningfulChange(before: CGImage, after: CGImage) -> Bool {
        score(before: before, after: after) >= threshold
    }

    private func fingerprint(_ image: CGImage) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: gridSize,
            height: gridSize,
            bitsPerComponent: 8,
            bytesPerRow: gridSize,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
        guard let raw = context.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: gridSize * gridSize)
        return Array(UnsafeBufferPointer(start: bytes, count: gridSize * gridSize))
    }
}
