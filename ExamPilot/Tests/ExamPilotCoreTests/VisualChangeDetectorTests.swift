import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class VisualChangeDetectorTests: XCTestCase {
    func testIdenticalImagesHaveNearZeroScore() throws {
        let image = try makeImage(width: 64, height: 64, gray: 0.25)
        let detector = VisualChangeDetector(gridSize: 16, threshold: 0.02)

        XCTAssertLessThan(detector.score(before: image, after: image), 0.001)
        XCTAssertFalse(detector.hasMeaningfulChange(before: image, after: image))
    }

    func testDifferentImagesCrossThreshold() throws {
        let dark = try makeImage(width: 64, height: 64, gray: 0.1)
        let bright = try makeImage(width: 64, height: 64, gray: 0.9)
        let detector = VisualChangeDetector(gridSize: 16, threshold: 0.02)

        XCTAssertGreaterThan(detector.score(before: dark, after: bright), 0.5)
        XCTAssertTrue(detector.hasMeaningfulChange(before: dark, after: bright))
    }

    func testLocalizedChangeIsDetected() throws {
        let base = try makeImage(width: 80, height: 80, gray: 0.2)
        let changed = try makeSplitImage(width: 80, height: 80)
        let detector = VisualChangeDetector(gridSize: 20, threshold: 0.04)

        XCTAssertTrue(detector.hasMeaningfulChange(before: base, after: changed))
    }

    private func makeImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "tests", code: 1)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw NSError(domain: "tests", code: 2) }
        return image
    }

    private func makeSplitImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "tests", code: 3)
        }
        context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else { throw NSError(domain: "tests", code: 4) }
        return image
    }
}
