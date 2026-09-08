import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopStabilityTests: XCTestCase {
    func testProtectedBoundaryWaitsForStableFrameBeforeNextProviderTurn() async throws {
        let questionA = try makeFrame(gray: 0.10, marker: 1)
        let loading = try makeFrame(gray: 0.90, marker: 2)
        let partialB = try makeFrame(gray: 0.25, marker: 3)
        let stableB = try makeFrame(gray: 0.55, marker: 4)

        let capture = StabilityQueueCapture(frames: [
            questionA,
            loading,
            partialB,
            stableB,
            stableB,
        ])
        let agent = StabilityRecordingAgent(decisions: [
            ExamDecision(
                summary: "navigate from answered A",
                expectsVisualChange: true,
                actions: [.moveClick(x: 50, y: 50, boundary: true)]
            ),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = StabilityRecordingDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            initialRuntimeState: ExamRuntimeState(answerState: .verified),
            dryRun: false,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(agent.observedMarkers, [1, 4])
        XCTAssertEqual(driver.clickCount, 1)
    }

    private func makeFrame(gray: CGFloat, marker: UInt8) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "ExamLoopStabilityTests", code: 1)
        }

        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ExamLoopStabilityTests", code: 2)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([marker]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class StabilityQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]

    init(frames: [ScreenFrame]) {
        self.frames = frames
    }

    func capture() async throws -> ScreenFrame {
        guard !frames.isEmpty else {
            throw NSError(domain: "ExamLoopStabilityTests", code: 3)
        }
        return frames.removeFirst()
    }
}

private final class StabilityRecordingAgent: VisionAgent {
    private var decisions: [ExamDecision]
    private(set) var observedMarkers: [UInt8] = []

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        observedMarkers.append(frame.jpegData.first ?? 0)
        guard !decisions.isEmpty else {
            throw NSError(domain: "ExamLoopStabilityTests", code: 4)
        }
        return decisions.removeFirst()
    }
}

private final class StabilityRecordingDriver: InputDriving {
    private(set) var clickCount = 0

    func moveAndClick(x: Double, y: Double) async throws { clickCount += 1 }
    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}
