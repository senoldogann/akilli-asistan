import CoreGraphics
import XCTest
@testable import ExamPilotCore

final class ExamLoopRecoveryTests: XCTestCase {
    func testRepeatedPrematureNavigationStopsWithoutPhysicalInput() async throws {
        let frame = try makeFrame(gray: 0.4)
        let capture = RecoveryQueueCapture(frames: Array(repeating: frame, count: 5))
        let agent = RecoveryQueueAgent(decisions: (0..<3).map { _ in
            ExamDecision(
                summary: "next",
                expectsVisualChange: true,
                actions: [.moveClick(x: 90, y: 90, boundary: true)]
            )
        })
        let driver = RecoveryRecordingDriver()
        let events = RecoveryEventSink()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            eventSink: events,
            dryRun: false,
            maxCycles: 10,
            postActionSettler: {},
            stabilitySettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .nonProgress(cycles: 3, reason: .recoveryExhausted))
        XCTAssertTrue(driver.clicks.isEmpty)
        XCTAssertEqual(events.events.filter { $0.kind == .recoveryPlanned }.count, 2)
        XCTAssertTrue(events.events.contains {
            $0.kind == .recoveryExhausted && $0.detail == "repeated_intent_loop"
        })
    }

    func testRepeatedNoEffectIntentStopsBeforeFourthPhysicalAttempt() async throws {
        let frame = try makeFrame(gray: 0.4)
        let capture = RecoveryQueueCapture(frames: Array(repeating: frame, count: 7))
        let agent = RecoveryQueueAgent(decisions: (0..<4).map { _ in
            ExamDecision(
                summary: "same answer click",
                expectsVisualChange: true,
                actions: [.moveClick(x: 20, y: 20)]
            )
        })
        let driver = RecoveryRecordingDriver()
        let events = RecoveryEventSink()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            eventSink: events,
            dryRun: false,
            maxCycles: 10,
            maxNonProgress: 10,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .nonProgress(cycles: 3, reason: .recoveryExhausted))
        XCTAssertEqual(driver.clicks, [
            CGPoint(x: 20, y: 20),
            CGPoint(x: 20, y: 20),
            CGPoint(x: 20, y: 20),
        ])
        XCTAssertTrue(events.events.contains {
            $0.kind == .recoveryExhausted && $0.detail == "repeated_intent_loop"
        })
    }

    func testChangedTargetDoesNotCountAsSameIntentLoop() async throws {
        let frame = try makeFrame(gray: 0.4)
        let capture = RecoveryQueueCapture(frames: Array(repeating: frame, count: 6))
        let agent = RecoveryQueueAgent(decisions: [
            ExamDecision(summary: "try first", expectsVisualChange: true, actions: [.moveClick(x: 20, y: 20)]),
            ExamDecision(summary: "try first again", expectsVisualChange: true, actions: [.moveClick(x: 22, y: 22)]),
            ExamDecision(summary: "change target", expectsVisualChange: true, actions: [.moveClick(x: 80, y: 80)]),
        ])
        let driver = RecoveryRecordingDriver()
        let events = RecoveryEventSink()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            eventSink: events,
            dryRun: false,
            maxCycles: 3,
            maxNonProgress: 3,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .nonProgress(cycles: 3, reason: .maxNonProgressExceeded))
        XCTAssertEqual(driver.clicks.count, 3)
        XCTAssertEqual(events.events.filter { $0.kind == .recoveryPlanned }.count, 3)
        XCTAssertFalse(events.events.contains { $0.kind == .recoveryExhausted })
    }

    private func makeFrame(gray: CGFloat) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "recovery-tests", code: 1)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "recovery-tests", code: 2)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class RecoveryQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]

    init(frames: [ScreenFrame]) {
        self.frames = frames
    }

    func capture() async throws -> ScreenFrame {
        guard !frames.isEmpty else {
            throw NSError(domain: "recovery-tests", code: 3)
        }
        return frames.removeFirst()
    }
}

private final class RecoveryQueueAgent: VisionAgent {
    private var decisions: [ExamDecision]

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        guard !decisions.isEmpty else {
            throw NSError(domain: "recovery-tests", code: 4)
        }
        return decisions.removeFirst()
    }
}

private final class RecoveryRecordingDriver: InputDriving {
    var clicks: [CGPoint] = []

    func moveAndClick(x: Double, y: Double) async throws {
        clicks.append(CGPoint(x: x, y: y))
    }

    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}

private final class RecoveryEventSink: AgentEventSinking {
    var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        events.append(event)
    }
}
