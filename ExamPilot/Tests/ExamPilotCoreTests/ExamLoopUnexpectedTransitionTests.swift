import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopUnexpectedTransitionTests: XCTestCase {
    func testMisclassifiedNavigationFromVerifiedQuestionStartsFreshUnansweredGeneration() async throws {
        let questionA = try makeFrame(gray: 0.1)
        let questionB = try makeFrame(gray: 0.9)
        let capture = UnexpectedTransitionCapture(
            frames: [questionA, questionB, questionB, questionB, questionB]
        )
        let agent = UnexpectedTransitionAgent(decisions: [
            ExamDecision(
                summary: "misclassified next from verified q1",
                expectsVisualChange: true,
                actions: [
                    .moveClick(x: 10, y: 10, boundary: false),
                    .typeText("SHOULD_NOT_RUN"),
                ]
            ),
            ExamDecision(
                summary: "premature next on fresh q2",
                expectsVisualChange: true,
                actions: [.moveClick(x: 90, y: 90, boundary: true)]
            ),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = UnexpectedTransitionDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            initialRuntimeState: ExamRuntimeState(answerState: .verified),
            dryRun: false,
            intermediateClickSettler: {},
            postActionSettler: {},
            stabilitySettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 3))
        XCTAssertEqual(driver.clicks, [CGPoint(x: 10, y: 10)])
        XCTAssertEqual(agent.states.count, 3)
        XCTAssertEqual(agent.states[1].questionGeneration, 2)
        XCTAssertFalse(agent.states[1].answerVerified)
        XCTAssertEqual(agent.states[1].uiPhase, .stable)
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
            throw NSError(domain: "ExamLoopUnexpectedTransitionTests", code: 1)
        }

        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ExamLoopUnexpectedTransitionTests", code: 2)
        }

        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class UnexpectedTransitionCapture: ScreenCapturing {
    private var frames: [ScreenFrame]

    init(frames: [ScreenFrame]) {
        self.frames = frames
    }

    func capture() async throws -> ScreenFrame {
        guard !frames.isEmpty else {
            throw NSError(domain: "ExamLoopUnexpectedTransitionTests", code: 3)
        }
        return frames.removeFirst()
    }
}

private final class UnexpectedTransitionAgent: VisionAgent {
    private var decisions: [ExamDecision]
    private(set) var states: [ExamObservationState] = []

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        states.append(state)
        guard !decisions.isEmpty else {
            throw NSError(domain: "ExamLoopUnexpectedTransitionTests", code: 4)
        }
        return decisions.removeFirst()
    }
}

private final class UnexpectedTransitionDriver: InputDriving {
    private(set) var clicks: [CGPoint] = []

    func moveAndClick(x: Double, y: Double) async throws {
        clicks.append(CGPoint(x: x, y: y))
    }

    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}
