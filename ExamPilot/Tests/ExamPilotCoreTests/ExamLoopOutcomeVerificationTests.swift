import CoreGraphics
import XCTest
@testable import ExamPilotCore

final class ExamLoopOutcomeVerificationTests: XCTestCase {
    func testNoVisibleEffectNeverMarksAnswerVerified() async throws {
        let same = try makeFrame(gray: 0.40, marker: 1)
        let capture = OutcomeQueueCapture(frames: [same, same, same, same])
        let agent = OutcomeRecordingAgent(decisions: [
            ExamDecision(summary: "answer", expectsVisualChange: true, actions: [.moveClick(x: 10, y: 10)]),
            ExamDecision(summary: "next", expectsVisualChange: true, actions: [.moveClick(x: 90, y: 90, boundary: true)]),
            ExamDecision(summary: "finish", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = OutcomeRecordingDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: false,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 3))
        XCTAssertEqual(agent.states.count, 3)
        XCTAssertFalse(agent.states[1].answerVerified)
        XCTAssertEqual(driver.clicks, [CGPoint(x: 10, y: 10)])
    }

    func testStableNavigationIdentityUnchangedDoesNotAdvanceGeneration() async throws {
        let question = try makeFrame(gray: 0.40, marker: 1)
        let loading = try makeFrame(gray: 0.90, marker: 2)
        let capture = OutcomeQueueCapture(frames: [question, loading, question, question])
        let agent = OutcomeRecordingAgent(decisions: [
            ExamDecision(
                summary: "navigate",
                expectsVisualChange: true,
                actions: [.moveClick(x: 50, y: 50, boundary: true)]
            ),
            ExamDecision(summary: "finish", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = OutcomeRecordingDriver()
        let events = OutcomeEventSink()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            initialRuntimeState: ExamRuntimeState(answerState: .verified),
            eventSink: events,
            dryRun: false,
            postActionSettler: {},
            stabilitySettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(agent.states.count, 2)
        XCTAssertEqual(agent.states[1].questionGeneration, 1)
        XCTAssertTrue(agent.states[1].answerVerified)
        XCTAssertEqual(agent.states[1].uiPhase, .stable)
        XCTAssertTrue(events.events.contains { event in
            event.kind == .verificationFailed && event.detail == "navigation_identity_unchanged"
        })
    }

    func testSuccessfulStableNavigationAdvancesGenerationExactlyOnce() async throws {
        let questionA = try makeFrame(gray: 0.10, marker: 1)
        let loading = try makeFrame(gray: 0.90, marker: 2)
        let questionB = try makeFrame(gray: 0.50, marker: 3)
        let capture = OutcomeQueueCapture(frames: [questionA, loading, questionB, questionB])
        let agent = OutcomeRecordingAgent(decisions: [
            ExamDecision(
                summary: "navigate",
                expectsVisualChange: true,
                actions: [.moveClick(x: 50, y: 50, boundary: true)]
            ),
            ExamDecision(summary: "finish", expectsVisualChange: false, actions: [.finish()]),
        ])
        let driver = OutcomeRecordingDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            initialRuntimeState: ExamRuntimeState(answerState: .verified),
            dryRun: false,
            postActionSettler: {},
            stabilitySettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(agent.states.count, 2)
        XCTAssertEqual(agent.states[1].questionGeneration, 2)
        XCTAssertFalse(agent.states[1].answerVerified)
        XCTAssertEqual(agent.states[1].uiPhase, .stable)
        XCTAssertEqual(driver.clicks, [CGPoint(x: 50, y: 50)])
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
            throw NSError(domain: "ExamLoopOutcomeVerificationTests", code: 1)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ExamLoopOutcomeVerificationTests", code: 2)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([marker]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class OutcomeQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]

    init(frames: [ScreenFrame]) {
        self.frames = frames
    }

    func capture() async throws -> ScreenFrame {
        guard !frames.isEmpty else {
            throw NSError(domain: "ExamLoopOutcomeVerificationTests", code: 3)
        }
        return frames.removeFirst()
    }
}

private final class OutcomeRecordingAgent: VisionAgent {
    private var decisions: [ExamDecision]
    private(set) var states: [ExamObservationState] = []

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        states.append(state)
        guard !decisions.isEmpty else {
            throw NSError(domain: "ExamLoopOutcomeVerificationTests", code: 4)
        }
        return decisions.removeFirst()
    }
}

private final class OutcomeRecordingDriver: InputDriving {
    private(set) var clicks: [CGPoint] = []

    func moveAndClick(x: Double, y: Double) async throws {
        clicks.append(CGPoint(x: x, y: y))
    }
    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}

private final class OutcomeEventSink: AgentEventSinking {
    private(set) var events: [AgentEvent] = []
    func record(_ event: AgentEvent) { events.append(event) }
}
