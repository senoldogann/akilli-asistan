import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class InputFocusPreparationTests: XCTestCase {
    func testLiveBatchPreparesCapturedChromeTargetBeforePhysicalInput() async throws {
        let before = try makeFrame(gray: 0.1, targetProcessID: 4242)
        let after = try makeFrame(gray: 0.9, targetProcessID: 4242)
        let log = FocusEventLog()
        let capture = FocusQueueCapture(frames: [before, after, after], log: log)
        let agent = FocusQueueVisionAgent(decisions: [
            ExamDecision(summary: "select", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50)]),
            ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = FocusRecordingDriver(log: log)
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: false,
            prepareForInput: { frame in
                XCTAssertEqual(frame.targetProcessID, 4242)
                log.events.append("focus")
            },
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(Array(log.events.prefix(3)), ["capture", "focus", "click"])
    }

    func testDryRunDoesNotPrepareOrFocusInputTarget() async throws {
        let frame = try makeFrame(gray: 0.5, targetProcessID: 4242)
        let log = FocusEventLog()
        let capture = FocusQueueCapture(frames: [frame], log: log)
        let agent = FocusQueueVisionAgent(decisions: [
            ExamDecision(summary: "plan", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50)])
        ])
        let driver = FocusRecordingDriver(log: log)
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: true,
            prepareForInput: { _ in log.events.append("focus") }
        )

        _ = await loop.run()

        XCTAssertEqual(log.events, ["capture"])
    }

    private func makeFrame(gray: CGFloat, targetProcessID: Int32) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "tests", code: 21)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else { throw NSError(domain: "tests", code: 22) }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetProcessID: targetProcessID
        )
    }
}

private final class FocusEventLog {
    var events: [String] = []
}

private final class FocusQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]
    private let log: FocusEventLog

    init(frames: [ScreenFrame], log: FocusEventLog) {
        self.frames = frames
        self.log = log
    }

    func capture() async throws -> ScreenFrame {
        log.events.append("capture")
        guard !frames.isEmpty else { throw NSError(domain: "tests", code: 23) }
        return frames.removeFirst()
    }
}

private final class FocusQueueVisionAgent: VisionAgent {
    private var decisions: [ExamDecision]

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        guard !decisions.isEmpty else { throw NSError(domain: "tests", code: 24) }
        return decisions.removeFirst()
    }
}

private final class FocusRecordingDriver: InputDriving {
    private let log: FocusEventLog

    init(log: FocusEventLog) {
        self.log = log
    }

    func moveAndClick(x: Double, y: Double) async throws { log.events.append("click") }
    func typeText(_ text: String) async throws { log.events.append("type") }
    func pressKey(_ key: String) async throws { log.events.append("key") }
    func scroll(amount: Int) async throws { log.events.append("scroll") }
    func wait(milliseconds: Int) async throws { log.events.append("wait") }
}
