import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class AccessibilityObservationTests: XCTestCase {
    func testMatchingSnapshotProducesBoundedSemanticHints() throws {
        let frame = try makeFrame(
            bounds: CGRect(x: 100, y: 200, width: 800, height: 600),
            processID: 42
        )
        let snapshot = AccessibilitySnapshot(
            stateVersion: 7,
            processID: 42,
            windowBounds: AccessibilityBounds(frame.screenBounds),
            elements: [
                AccessibilityElementHint(
                    role: .radioButton,
                    bounds: AccessibilityBounds(x: 140, y: 260, width: 20, height: 20),
                    isFocused: false,
                    isSelected: true,
                    isEnabled: true
                ),
                AccessibilityElementHint(
                    role: .button,
                    bounds: AccessibilityBounds(x: 760, y: 720, width: 100, height: 32),
                    isFocused: true,
                    isSelected: nil,
                    isEnabled: true
                ),
            ]
        )

        let fused = AccessibilityObservationFusion().fuse(
            snapshot: snapshot,
            target: frame,
            stateVersion: 7
        )

        XCTAssertEqual(fused?.elements, snapshot.elements)
        XCTAssertEqual(fused?.processID, 42)
        XCTAssertEqual(fused?.stateVersion, 7)
    }

    func testSnapshotFromDifferentProcessIsRejected() throws {
        let frame = try makeFrame(bounds: CGRect(x: 0, y: 0, width: 500, height: 400), processID: 42)
        let snapshot = AccessibilitySnapshot(
            stateVersion: 3,
            processID: 99,
            windowBounds: AccessibilityBounds(frame.screenBounds),
            elements: []
        )

        XCTAssertNil(
            AccessibilityObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 3
            )
        )
    }

    func testSnapshotFromDifferentWindowIsRejected() throws {
        let frame = try makeFrame(bounds: CGRect(x: 0, y: 0, width: 500, height: 400), processID: 42)
        let snapshot = AccessibilitySnapshot(
            stateVersion: 3,
            processID: 42,
            windowBounds: AccessibilityBounds(x: 700, y: 0, width: 500, height: 400),
            elements: []
        )

        XCTAssertNil(
            AccessibilityObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 3
            )
        )
    }

    func testStaleAccessibilitySnapshotIsRejected() throws {
        let frame = try makeFrame(bounds: CGRect(x: 0, y: 0, width: 500, height: 400), processID: 42)
        let snapshot = AccessibilitySnapshot(
            stateVersion: 4,
            processID: 42,
            windowBounds: AccessibilityBounds(frame.screenBounds),
            elements: []
        )

        XCTAssertNil(
            AccessibilityObservationFusion().fuse(
                snapshot: snapshot,
                target: frame,
                stateVersion: 5
            )
        )
    }

    func testAccessibilityEvidenceCannotGrantRuntimeAnswerAuthority() {
        let selected = AccessibilityObservation(
            stateVersion: 8,
            processID: 42,
            windowBounds: AccessibilityBounds(x: 0, y: 0, width: 500, height: 400),
            elements: [
                AccessibilityElementHint(
                    role: .radioButton,
                    bounds: AccessibilityBounds(x: 10, y: 10, width: 20, height: 20),
                    isFocused: false,
                    isSelected: true,
                    isEnabled: true
                )
            ]
        )
        let state = ExamObservationState(
            cycle: 1,
            nonProgressCount: 0,
            lastSummary: nil,
            stateVersion: 8,
            answerVerified: false,
            accessibility: selected
        )

        XCTAssertFalse(state.answerVerified)
        XCTAssertEqual(state.accessibility?.selectedElementCount, 1)
    }

    func testAccessibilityModelsContainNoRawTextOrLabelPayload() throws {
        let observation = AccessibilityObservation(
            stateVersion: 1,
            processID: 42,
            windowBounds: AccessibilityBounds(x: 0, y: 0, width: 100, height: 100),
            elements: [
                AccessibilityElementHint(
                    role: .textField,
                    bounds: AccessibilityBounds(x: 5, y: 5, width: 90, height: 20),
                    isFocused: true,
                    isSelected: nil,
                    isEnabled: true
                )
            ]
        )

        let encoded = try JSONEncoder().encode(observation)
        let text = String(decoding: encoded, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("label"))
        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("value"))
        XCTAssertFalse(text.contains("rawtext"))
    }

    private func makeFrame(bounds: CGRect, processID: Int32) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "AccessibilityObservationTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: bounds,
            targetProcessID: processID
        )
    }
}
