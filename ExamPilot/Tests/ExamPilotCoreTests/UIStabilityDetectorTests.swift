import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class UIStabilityDetectorTests: XCTestCase {
    func testIdenticalFramesAreStable() throws {
        let frame = try makeImage(gray: 0.4)

        XCTAssertTrue(UIStabilityDetector().isStable(previous: frame, current: frame))
    }

    func testMateriallyDifferentFramesAreNotStable() throws {
        let dark = try makeImage(gray: 0.1)
        let bright = try makeImage(gray: 0.9)

        XCTAssertFalse(UIStabilityDetector().isStable(previous: dark, current: bright))
    }

    private func makeImage(gray: CGFloat) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "UIStabilityDetectorTests", code: 1)
        }

        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "UIStabilityDetectorTests", code: 2)
        }
        return image
    }
}
