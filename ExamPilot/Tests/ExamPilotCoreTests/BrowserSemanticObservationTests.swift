import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class BrowserSemanticObservationTests: XCTestCase {
    func testMatchingSnapshotProducesBoundedObservation() throws {
        let frame = try makeFrame(processID: 42)
        let snapshot = BrowserSemanticSnapshot(
            stateVersion: 7,
            processID: 42,
            windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
            viewportWidth: 760,
            viewportHeight: 470,
            elements: [
                BrowserSemanticElementHint(
                    role: .button,
                    bounds: BrowserSemanticNormalizedBounds(x: 0.25, y: 0.50, width: 0.20, height: 0.10),
                    isFocused: false,
                    isSelected: nil,
                    isEnabled: true
                )
            ]
        )

        let observation = BrowserSemanticObservationFusion().fuse(
            snapshot: snapshot,
            target: frame,
            stateVersion: 7
        )

        XCTAssertEqual(observation?.processID, 42)
        XCTAssertEqual(observation?.stateVersion, 7)
        XCTAssertEqual(observation?.elements.count, 1)
        XCTAssertEqual(observation?.elements.first?.role, .button)
    }

    func testRejectsStaleStateVersion() throws {
        let frame = try makeFrame(processID: 42)
        let snapshot = makeSnapshot(stateVersion: 6, processID: 42)

        XCTAssertNil(
            BrowserSemanticObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 7
            )
        )
    }

    func testRejectsDifferentChromeProcess() throws {
        let frame = try makeFrame(processID: 42)
        let snapshot = makeSnapshot(stateVersion: 7, processID: 99)

        XCTAssertNil(
            BrowserSemanticObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 7
            )
        )
    }

    func testRejectsDifferentBrowserWindowGeometry() throws {
        let frame = try makeFrame(processID: 42)
        let snapshot = BrowserSemanticSnapshot(
            stateVersion: 7,
            processID: 42,
            windowBounds: BrowserSemanticWindowBounds(x: 300, y: 300, width: 500, height: 500),
            viewportWidth: 480,
            viewportHeight: 360,
            elements: []
        )

        XCTAssertNil(
            BrowserSemanticObservationFusion(windowTolerance: 8).fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 7
            )
        )
    }

    func testClipsNormalizedBoundsGeometricallyAndBoundsElementCount() throws {
        let frame = try makeFrame(processID: 42)
        let elements = (0..<90).map { index in
            BrowserSemanticElementHint(
                role: .button,
                bounds: BrowserSemanticNormalizedBounds(
                    x: index == 0 ? -0.2 : 0.1,
                    y: index == 0 ? 0.8 : 0.2,
                    width: index == 0 ? 1.4 : 0.3,
                    height: index == 0 ? 0.5 : 0.1
                ),
                isFocused: false,
                isSelected: nil,
                isEnabled: true
            )
        }
        let snapshot = BrowserSemanticSnapshot(
            stateVersion: 7,
            processID: 42,
            windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
            viewportWidth: 760,
            viewportHeight: 470,
            elements: elements
        )

        let observation = try XCTUnwrap(
            BrowserSemanticObservationFusion(maximumElementCount: 24).fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 7
            )
        )

        XCTAssertEqual(observation.elements.count, 24)
        let first = try XCTUnwrap(observation.elements.first)
        XCTAssertEqual(first.bounds.x, 0, accuracy: 0.0001)
        XCTAssertEqual(first.bounds.y, 0.8, accuracy: 0.0001)
        XCTAssertEqual(first.bounds.width, 1, accuracy: 0.0001)
        XCTAssertEqual(first.bounds.height, 0.2, accuracy: 0.0001)
    }

    func testDiscardsBoundsFullyOutsideViewport() throws {
        let frame = try makeFrame(processID: 42)
        let snapshot = BrowserSemanticSnapshot(
            stateVersion: 7,
            processID: 42,
            windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
            viewportWidth: 760,
            viewportHeight: 470,
            elements: [
                BrowserSemanticElementHint(
                    role: .button,
                    bounds: BrowserSemanticNormalizedBounds(x: 1.2, y: 0.2, width: 0.1, height: 0.1),
                    isFocused: false,
                    isSelected: nil,
                    isEnabled: true
                )
            ]
        )

        let observation = try XCTUnwrap(
            BrowserSemanticObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 7
            )
        )

        XCTAssertTrue(observation.elements.isEmpty)
    }

    func testPlannerSummaryContainsOnlyBoundedRoleStateAndGeometry() throws {
        let frame = try makeFrame(processID: 42)
        let snapshot = makeSnapshot(stateVersion: 7, processID: 42)
        let observation = try XCTUnwrap(
            BrowserSemanticObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 7
            )
        )

        let summary = observation.plannerHintSummary(maxElements: 8)

        XCTAssertTrue(summary.contains("button"))
        XCTAssertTrue(summary.contains("nx="))
        XCTAssertTrue(summary.contains("enabled=true"))
        XCTAssertFalse(summary.contains("http://"))
        XCTAssertFalse(summary.contains("https://"))
        XCTAssertFalse(summary.contains("title="))
        XCTAssertFalse(summary.contains("value="))
        XCTAssertFalse(summary.contains("name="))
    }

    private func makeSnapshot(stateVersion: UInt64, processID: Int32) -> BrowserSemanticSnapshot {
        BrowserSemanticSnapshot(
            stateVersion: stateVersion,
            processID: processID,
            windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
            viewportWidth: 760,
            viewportHeight: 470,
            elements: [
                BrowserSemanticElementHint(
                    role: .button,
                    bounds: BrowserSemanticNormalizedBounds(x: 0.2, y: 0.3, width: 0.1, height: 0.05),
                    isFocused: false,
                    isSelected: nil,
                    isEnabled: true
                )
            ]
        )
    }

    private func makeFrame(processID: Int32) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "BrowserSemanticObservationTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            targetProcessID: processID
        )
    }
}
