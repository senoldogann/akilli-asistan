import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopAccessibilityTests: XCTestCase {
    func testLoopForwardsMatchingAccessibilityHintsToPlanner() async throws {
        let frame = try makeFrame(processID: 4242)
        let observer = StubAccessibilityObserver(result: .success(
            AccessibilitySnapshot(
                stateVersion: 1,
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
        let agent = AccessibilityRecordingAgent()
        let loop = ExamLoop(
            capture: SingleFrameCapture(frame: frame),
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: NoopAccessibilityDriver()),
            accessibilityObserver: observer,
            dryRun: false
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 1))
        XCTAssertEqual(observer.calls, 1)
        XCTAssertEqual(agent.states.count, 1)
        XCTAssertEqual(agent.states[0].accessibility?.elements.first?.role, .button)
        XCTAssertEqual(agent.states[0].accessibility?.stateVersion, agent.states[0].stateVersion)
    }

    func testAccessibilityFailureFallsBackToScreenshotOnly() async throws {
        let frame = try makeFrame(processID: 4242)
        let observer = StubAccessibilityObserver(result: .failure(AccessibilityObservationError.notTrusted))
        let agent = AccessibilityRecordingAgent()
        let loop = ExamLoop(
            capture: SingleFrameCapture(frame: frame),
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: NoopAccessibilityDriver()),
            accessibilityObserver: observer,
            dryRun: false
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 1))
        XCTAssertEqual(observer.calls, 1)
        XCTAssertNil(agent.states.first?.accessibility)
    }

    func testStaleObserverResultIsNotForwardedToPlanner() async throws {
        let frame = try makeFrame(processID: 4242)
        let observer = StubAccessibilityObserver(result: .success(
            AccessibilitySnapshot(
                stateVersion: 0,
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
        let agent = AccessibilityRecordingAgent()
        let loop = ExamLoop(
            capture: SingleFrameCapture(frame: frame),
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: NoopAccessibilityDriver()),
            accessibilityObserver: observer,
            dryRun: false
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 1))
        XCTAssertNil(agent.states.first?.accessibility)
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
            throw NSError(domain: "ExamLoopAccessibilityTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetProcessID: processID
        )
    }
}

private final class StubAccessibilityObserver: AccessibilityObserving {
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

private final class AccessibilityRecordingAgent: VisionAgent {
    private(set) var states: [ExamObservationState] = []

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        states.append(state)
        return ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()])
    }
}

private final class SingleFrameCapture: ScreenCapturing {
    private let frame: ScreenFrame

    init(frame: ScreenFrame) {
        self.frame = frame
    }

    func capture() async throws -> ScreenFrame {
        frame
    }
}

private final class NoopAccessibilityDriver: InputDriving {
    func moveAndClick(x: Double, y: Double) async throws {}
    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}
