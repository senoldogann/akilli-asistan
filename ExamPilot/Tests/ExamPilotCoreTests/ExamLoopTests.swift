import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopTests: XCTestCase {
    func testProgressBatchContinuesUntilFinish() async throws {
        let dark = try makeFrame(gray: 0.1)
        let bright = try makeFrame(gray: 0.9)
        let capture = QueueCapture(frames: [dark, bright, bright])
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(summary: "click answer", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50)]),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = LoopRecordingDriver()
        let executor = ActionBatchExecutor(driver: driver)
        let loop = ExamLoop(capture: capture, visionAgent: agent, executor: executor, dryRun: false)

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(driver.calls, ["click"])
    }

    func testThreeConsecutiveNoChangeBatchesAbort() async throws {
        let same = try makeFrame(gray: 0.4)
        let capture = QueueCapture(frames: Array(repeating: same, count: 6))
        let agent = QueueVisionAgent(decisions: (0..<3).map { _ in
            ExamDecision(summary: "try", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50)])
        })
        let driver = LoopRecordingDriver()
        let loop = ExamLoop(capture: capture, visionAgent: agent, executor: ActionBatchExecutor(driver: driver), dryRun: false)

        let result = await loop.run()

        XCTAssertEqual(result, .nonProgress(cycles: 3))
        XCTAssertEqual(driver.calls.count, 3)
    }

    func testNoProgressReobservesWithoutReplayingStaleBoundaryClick() async throws {
        let before = try makeFrame(gray: 0.1)
        let unchanged = try makeFrame(gray: 0.1)
        let capture = QueueCapture(frames: [before, unchanged, unchanged])
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(summary: "go next", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50, boundary: true)]),
            ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = LoopRecordingDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: false,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(driver.calls, ["click"])
    }

    func testInvalidBatchReobservesWithoutInput() async throws {
        let frame = try makeFrame(gray: 0.3)
        let capture = QueueCapture(frames: [frame, frame])
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(summary: "bad coordinate", expectsVisualChange: true, actions: [.moveClick(x: 5000, y: 5000)]),
            ExamDecision(summary: "finish", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = LoopRecordingDriver()
        let loop = ExamLoop(capture: capture, visionAgent: agent, executor: ActionBatchExecutor(driver: driver), dryRun: false)

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertTrue(driver.calls.isEmpty)
    }

    func testDryRunPlansOnceWithoutPhysicalInput() async throws {
        let frame = try makeFrame(gray: 0.5)
        let capture = QueueCapture(frames: [frame])
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(summary: "would select B", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50), .pressKey("return", boundary: true)])
        ])
        let driver = LoopRecordingDriver()
        let loop = ExamLoop(capture: capture, visionAgent: agent, executor: ActionBatchExecutor(driver: driver), dryRun: true)

        let result = await loop.run()

        XCTAssertEqual(result, .dryRunPlanned(summary: "would select B", actionCount: 2))
        XCTAssertTrue(driver.calls.isEmpty)
    }

    func testStopSignalExitsBeforeObservation() async throws {
        let frame = try makeFrame(gray: 0.5)
        let capture = QueueCapture(frames: [frame])
        let agent = QueueVisionAgent(decisions: [])
        let driver = LoopRecordingDriver()
        let loop = ExamLoop(capture: capture, visionAgent: agent, executor: ActionBatchExecutor(driver: driver), dryRun: false, shouldStop: { true })

        let result = await loop.run()

        XCTAssertEqual(result, .stopped(cycles: 0))
        XCTAssertEqual(capture.captureCount, 0)
    }

    func testExpectedVisualChangeSettlesBeforeVerificationCapture() async throws {
        let dark = try makeFrame(gray: 0.1)
        let bright = try makeFrame(gray: 0.9)
        let log = LoopEventLog()
        let capture = EventQueueCapture(frames: [dark, bright, bright], log: log)
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(summary: "go next", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50, boundary: true)]),
            ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = EventRecordingDriver(log: log)
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: false,
            postActionSettler: {
                log.events.append("settle")
            }
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(Array(log.events.prefix(4)), ["capture", "click", "settle", "capture"])
    }

    func testMisclassifiedNavigationClickInterruptsRemainingBatchForReobservation() async throws {
        let before = try makeFrame(gray: 0.1)
        let navigated = try makeFrame(gray: 0.9)
        let capture = QueueCapture(frames: [before, navigated, navigated])
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(
                summary: "misclassified next",
                expectsVisualChange: true,
                actions: [
                    .moveClick(x: 50, y: 50, boundary: false),
                    .typeText("SHOULD_NOT_RUN"),
                ]
            ),
            ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = LoopRecordingDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: false,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(driver.calls, ["click"])
    }

    func testUnansweredSecondQuestionCannotPhysicallyNavigate() async throws {
        let frame = try makeFrame(gray: 0.4)
        let capture = QueueCapture(frames: Array(repeating: frame, count: 16))
        let agent = QueueVisionAgent(decisions: [
            ExamDecision(summary: "answer q1", expectsVisualChange: true, actions: [.moveClick(x: 10, y: 10)]),
            ExamDecision(summary: "next from q1", expectsVisualChange: true, actions: [.moveClick(x: 20, y: 20, boundary: true)]),
            ExamDecision(summary: "premature next on q2", expectsVisualChange: true, actions: [.moveClick(x: 30, y: 30, boundary: true)]),
            ExamDecision(summary: "answer q2", expectsVisualChange: true, actions: [.moveClick(x: 40, y: 40)]),
            ExamDecision(summary: "next from q2", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50, boundary: true)]),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = CoordinateRecordingDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            detector: VisualChangeDetector(threshold: 0),
            dryRun: false,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 6))
        XCTAssertEqual(
            driver.clicks,
            [
                CGPoint(x: 10, y: 10),
                CGPoint(x: 20, y: 20),
                CGPoint(x: 40, y: 40),
                CGPoint(x: 50, y: 50),
            ]
        )
        XCTAssertFalse(driver.clicks.contains(CGPoint(x: 30, y: 30)))
    }

    private func makeFrame(gray: CGFloat) throws -> ScreenFrame {
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "tests", code: 1)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else { throw NSError(domain: "tests", code: 2) }
        return ScreenFrame(image: image, jpegData: Data([1, 2, 3]), screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    }
}

private final class QueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]
    private(set) var captureCount = 0

    init(frames: [ScreenFrame]) { self.frames = frames }

    func capture() async throws -> ScreenFrame {
        captureCount += 1
        guard !frames.isEmpty else { throw NSError(domain: "tests", code: 9) }
        return frames.removeFirst()
    }
}

private final class QueueVisionAgent: VisionAgent {
    private var decisions: [ExamDecision]
    init(decisions: [ExamDecision]) { self.decisions = decisions }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        guard !decisions.isEmpty else { throw NSError(domain: "tests", code: 10) }
        return decisions.removeFirst()
    }
}

private final class LoopRecordingDriver: InputDriving {
    var calls: [String] = []
    func moveAndClick(x: Double, y: Double) async throws { calls.append("click") }
    func typeText(_ text: String) async throws { calls.append("type") }
    func pressKey(_ key: String) async throws { calls.append("key") }
    func scroll(amount: Int) async throws { calls.append("scroll") }
    func wait(milliseconds: Int) async throws { calls.append("wait") }
}

private final class CoordinateRecordingDriver: InputDriving {
    var clicks: [CGPoint] = []

    func moveAndClick(x: Double, y: Double) async throws {
        clicks.append(CGPoint(x: x, y: y))
    }

    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}

private final class LoopEventLog {
    var events: [String] = []
}

private final class EventQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]
    private let log: LoopEventLog

    init(frames: [ScreenFrame], log: LoopEventLog) {
        self.frames = frames
        self.log = log
    }

    func capture() async throws -> ScreenFrame {
        log.events.append("capture")
        guard !frames.isEmpty else { throw NSError(domain: "tests", code: 11) }
        return frames.removeFirst()
    }
}

private final class EventRecordingDriver: InputDriving {
    private let log: LoopEventLog

    init(log: LoopEventLog) {
        self.log = log
    }

    func moveAndClick(x: Double, y: Double) async throws { log.events.append("click") }
    func typeText(_ text: String) async throws { log.events.append("type") }
    func pressKey(_ key: String) async throws { log.events.append("key") }
    func scroll(amount: Int) async throws { log.events.append("scroll") }
    func wait(milliseconds: Int) async throws { log.events.append("wait") }
}
