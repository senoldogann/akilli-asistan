import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class AccessibilityFusingVisionAgentTests: XCTestCase {
    func testMatchingSnapshotIsForwardedAsPlannerState() async throws {
        let frame = try makeFrame(processID: 4242)
        let observer = DecoratorAccessibilityObserver(result: .success(
            AccessibilitySnapshot(
                stateVersion: 7,
                processID: 4242,
                windowBounds: AccessibilityBounds(frame.screenBounds),
                elements: [
                    AccessibilityElementHint(
                        role: .button,
                        bounds: AccessibilityBounds(x: 70, y: 70, width: 20, height: 20),
                        isFocused: true,
                        isSelected: nil,
                        isEnabled: true
                    )
                ]
            )
        ))
        let base = DecoratorRecordingAgent()
        let agent = AccessibilityFusingVisionAgent(base: base, observer: observer)
        let state = ExamObservationState(
            cycle: 1,
            nonProgressCount: 0,
            lastSummary: nil,
            stateVersion: 7
        )

        _ = try await agent.decide(frame: frame, state: state)

        XCTAssertEqual(observer.calls, 1)
        XCTAssertEqual(base.states.count, 1)
        XCTAssertEqual(base.states[0].accessibility?.elements.first?.role, .button)
        XCTAssertEqual(base.states[0].accessibility?.stateVersion, 7)
    }

    func testObserverFailureFallsBackToScreenshotOnlyPlannerState() async throws {
        let frame = try makeFrame(processID: 4242)
        let observer = DecoratorAccessibilityObserver(
            result: .failure(AccessibilityObservationError.notTrusted)
        )
        let base = DecoratorRecordingAgent()
        let agent = AccessibilityFusingVisionAgent(base: base, observer: observer)
        let state = ExamObservationState(
            cycle: 1,
            nonProgressCount: 0,
            lastSummary: nil,
            stateVersion: 7
        )

        _ = try await agent.decide(frame: frame, state: state)

        XCTAssertEqual(observer.calls, 1)
        XCTAssertNil(base.states.first?.accessibility)
    }

    func testStaleSnapshotIsNotForwarded() async throws {
        let frame = try makeFrame(processID: 4242)
        let observer = DecoratorAccessibilityObserver(result: .success(
            AccessibilitySnapshot(
                stateVersion: 6,
                processID: 4242,
                windowBounds: AccessibilityBounds(frame.screenBounds),
                elements: [
                    AccessibilityElementHint(
                        role: .radioButton,
                        bounds: AccessibilityBounds(x: 20, y: 20, width: 20, height: 20),
                        isFocused: false,
                        isSelected: true,
                        isEnabled: true
                    )
                ]
            )
        ))
        let base = DecoratorRecordingAgent()
        let agent = AccessibilityFusingVisionAgent(base: base, observer: observer)
        let state = ExamObservationState(
            cycle: 1,
            nonProgressCount: 0,
            lastSummary: nil,
            stateVersion: 7
        )

        _ = try await agent.decide(frame: frame, state: state)

        XCTAssertNil(base.states.first?.accessibility)
    }

    private func makeFrame(processID: Int32) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "AccessibilityFusingVisionAgentTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetProcessID: processID
        )
    }
}

private final class DecoratorAccessibilityObserver: AccessibilityObserving {
    private let result: Result<AccessibilitySnapshot?, Error>
    private(set) var calls = 0

    init(result: Result<AccessibilitySnapshot?, Error>) {
        self.result = result
    }

    func observe(target: ScreenFrame, stateVersion: UInt64) throws -> AccessibilitySnapshot? {
        calls += 1
        return try result.get()
    }
}

private final class DecoratorRecordingAgent: VisionAgent {
    private(set) var states: [ExamObservationState] = []

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        states.append(state)
        return ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()])
    }
}
