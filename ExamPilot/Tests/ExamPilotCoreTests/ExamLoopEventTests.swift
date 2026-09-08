import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopEventTests: XCTestCase {
    func testDeniedNavigationEmitsStructuredPolicyEventWithoutPhysicalInput() async throws {
        let frame = try makeFrame(gray: 0.4)
        let capture = EventTestQueueCapture(frames: [frame, frame])
        let agent = EventTestVisionAgent(decisions: [
            ExamDecision(
                summary: "premature next",
                expectsVisualChange: true,
                actions: [.moveClick(x: 50, y: 50, boundary: true)]
            ),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = EventTestRecordingDriver()
        let sink = RecordingAgentEventSink()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            initialRuntimeState: ExamRuntimeState(questionGeneration: 2),
            eventSink: sink,
            dryRun: false
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(driver.clickCount, 0)
        XCTAssertTrue(
            sink.events.contains {
                $0.kind == .policyDenied &&
                $0.detail == "protected_boundary_before_answer" &&
                $0.questionGeneration == 2
            }
        )
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
            throw NSError(domain: "ExamLoopEventTests", code: 1)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ExamLoopEventTests", code: 2)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class EventTestQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]

    init(frames: [ScreenFrame]) {
        self.frames = frames
    }

    func capture() async throws -> ScreenFrame {
        guard !frames.isEmpty else {
            throw NSError(domain: "ExamLoopEventTests", code: 3)
        }
        return frames.removeFirst()
    }
}

private final class EventTestVisionAgent: VisionAgent {
    private var decisions: [ExamDecision]

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        guard !decisions.isEmpty else {
            throw NSError(domain: "ExamLoopEventTests", code: 4)
        }
        return decisions.removeFirst()
    }
}

private final class EventTestRecordingDriver: InputDriving {
    private(set) var clickCount = 0

    func moveAndClick(x: Double, y: Double) async throws { clickCount += 1 }
    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}

private final class RecordingAgentEventSink: AgentEventSinking {
    private(set) var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        events.append(event)
    }
}
