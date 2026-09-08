import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopSessionTests: XCTestCase {
    func testProvidedSessionCorrelatesEventsProviderStateAndPlannerSummary() async throws {
        let frame = try makeFrame(gray: 0.4)
        let session = ComputerAgentSession(
            id: "session-loop-1",
            goal: "Complete authorized task"
        )
        session.updatePreviousResponseID("resp_123")
        let capture = SessionTestQueueCapture(frames: [frame])
        let agent = SessionTestVisionAgent(decisions: [
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()])
        ])
        let sink = SessionTestEventSink()
        let driver = SessionTestDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            session: session,
            eventSink: sink,
            dryRun: false
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 1))
        XCTAssertFalse(sink.events.isEmpty)
        XCTAssertTrue(sink.events.allSatisfy { $0.sessionID == "session-loop-1" })
        XCTAssertEqual(agent.states.first?.sessionID, "session-loop-1")
        XCTAssertEqual(agent.states.first?.providerContinuationAvailable, true)
        XCTAssertEqual(agent.states.first?.workingMemory.actions.count, 0)
        XCTAssertEqual(session.workingMemory.snapshot().actions.count, 1)
        XCTAssertEqual(session.lastPlannerSummary, "complete")
    }

    func testRepeatedPrematureNavigationIsRememberedAndExhaustedWithoutPhysicalInput() async throws {
        let frame = try makeFrame(gray: 0.4)
        let session = ComputerAgentSession(
            id: "session-denial-1",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(questionGeneration: 2)
        )
        let denial = ExamDecision(
            summary: "premature next",
            expectsVisualChange: true,
            actions: [.moveClick(x: 50, y: 50, boundary: true)]
        )
        let capture = SessionTestQueueCapture(frames: [frame, frame, frame])
        let agent = SessionTestVisionAgent(decisions: [denial, denial, denial])
        let driver = SessionTestDriver()
        let sink = SessionTestEventSink()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            session: session,
            eventSink: sink,
            dryRun: false
        )

        let result = await loop.run()

        XCTAssertEqual(result, .nonProgress(cycles: 3))
        XCTAssertEqual(driver.clicks.count, 0)
        let failures = session.workingMemory.snapshot().failures
        XCTAssertEqual(failures.count, 3)
        XCTAssertEqual(failures.map(\.reason), [.invalidModelPlan, .invalidModelPlan, .invalidModelPlan])
        XCTAssertEqual(failures[0].recoveryStrategy, .reobserveAndReplan)
        XCTAssertEqual(failures[1].recoveryStrategy, .reobserveAndReplan)
        XCTAssertNil(failures[2].recoveryStrategy)
        XCTAssertTrue(sink.events.allSatisfy { $0.sessionID == "session-denial-1" })
    }

    func testVerifiedAnswerIsRecordedAsSessionEvidenceAndVisibleToNextProviderTurn() async throws {
        let before = try makeFrame(gray: 0.3)
        let after = try makeFrame(gray: 0.35)
        let next = try makeFrame(gray: 0.35)
        let session = ComputerAgentSession(id: "session-answer-1", goal: "Run")
        let capture = SessionTestQueueCapture(frames: [before, after, next])
        let agent = SessionTestVisionAgent(decisions: [
            ExamDecision(
                summary: "answer current question",
                expectsVisualChange: true,
                actions: [.moveClick(x: 20, y: 20)]
            ),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()])
        ])
        let driver = SessionTestDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            outcomeVerifier: SessionTestOutcomeVerifier { expected in
                expected == .answerMutation
                    ? .success(.answerMutation(score: 0.2))
                    : .success(.none)
            },
            session: session,
            dryRun: false,
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(driver.clicks.count, 1)
        XCTAssertEqual(session.runtimeState.answerState, .verified)
        XCTAssertEqual(session.workingMemory.snapshot().evidence.map(\.outcome), [.answerMutation])
        XCTAssertEqual(agent.states.count, 2)
        XCTAssertEqual(agent.states[1].workingMemory.evidence.map(\.outcome), [.answerMutation])
        XCTAssertEqual(agent.states[1].lastSummary, "answer current question")
    }

    func testVerifiedNavigationAdvancesSessionGenerationExactlyOnce() async throws {
        let before = try makeFrame(gray: 0.2)
        let transition = try makeFrame(gray: 0.8)
        let stable = try makeFrame(gray: 0.8)
        let session = ComputerAgentSession(
            id: "session-navigation-1",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(
                stateVersion: 5,
                questionGeneration: 4,
                answerState: .verified,
                uiPhase: .stable
            )
        )
        let capture = SessionTestQueueCapture(frames: [before, transition, stable])
        let agent = SessionTestVisionAgent(decisions: [
            ExamDecision(
                summary: "navigate",
                expectsVisualChange: true,
                actions: [.moveClick(x: 70, y: 70, boundary: true)]
            ),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()])
        ])
        let driver = SessionTestDriver()
        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            outcomeVerifier: SessionTestOutcomeVerifier { expected in
                expected == .navigation
                    ? .success(.navigation(score: 0.9))
                    : .success(.none)
            },
            stabilityDetector: UIStabilityDetector(threshold: 0.01),
            session: session,
            dryRun: false,
            postActionSettler: {},
            stabilitySettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 2))
        XCTAssertEqual(driver.clicks.count, 1)
        XCTAssertEqual(session.runtimeState.questionGeneration, 5)
        XCTAssertEqual(session.runtimeState.answerState, .unanswered)
        XCTAssertEqual(session.runtimeState.uiPhase, .stable)
        XCTAssertEqual(session.workingMemory.snapshot().evidence.map(\.outcome), [.navigation])
        XCTAssertEqual(agent.states.last?.questionGeneration, 5)
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
            throw NSError(domain: "ExamLoopSessionTests", code: 1)
        }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ExamLoopSessionTests", code: 2)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class SessionTestQueueCapture: ScreenCapturing {
    private var frames: [ScreenFrame]

    init(frames: [ScreenFrame]) {
        self.frames = frames
    }

    func capture() async throws -> ScreenFrame {
        guard !frames.isEmpty else {
            throw NSError(domain: "ExamLoopSessionTests", code: 3)
        }
        return frames.removeFirst()
    }
}

private final class SessionTestVisionAgent: VisionAgent {
    private var decisions: [ExamDecision]
    private(set) var states: [ExamObservationState] = []

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        states.append(state)
        guard !decisions.isEmpty else {
            throw NSError(domain: "ExamLoopSessionTests", code: 4)
        }
        return decisions.removeFirst()
    }
}

private final class SessionTestDriver: InputDriving {
    private(set) var clicks: [(Double, Double)] = []

    func moveAndClick(x: Double, y: Double) async throws { clicks.append((x, y)) }
    func typeText(_ text: String) async throws {}
    func pressKey(_ key: String) async throws {}
    func scroll(amount: Int) async throws {}
    func wait(milliseconds: Int) async throws {}
}

private struct SessionTestOutcomeVerifier: OutcomeVerifying {
    let resolve: (ExpectedOutcomeKind) -> OutcomeVerificationResult

    init(resolve: @escaping (ExpectedOutcomeKind) -> OutcomeVerificationResult) {
        self.resolve = resolve
    }

    func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult {
        resolve(expected)
    }
}

private final class SessionTestEventSink: AgentEventSinking {
    private(set) var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        events.append(event)
    }
}
