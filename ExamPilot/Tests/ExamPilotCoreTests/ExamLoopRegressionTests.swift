import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ExamLoopRegressionTests: XCTestCase {
    func testUnansweredQuestionCannotBeSkippedAfterNavigatingFromAnsweredQuestion() async throws {
        let ui = SimulatedExamUI()
        let capture = SimulatedExamCapture(ui: ui)
        let driver = SimulatedExamDriver(ui: ui)
        let agent = RegressionVisionAgent(decisions: [
            ExamDecision(
                summary: "answer Q1 then next",
                expectsVisualChange: true,
                actions: [
                    .moveClick(x: 10, y: 10),
                    .moveClick(x: 90, y: 90, boundary: true),
                ]
            ),
            ExamDecision(
                summary: "navigate from verified Q1",
                expectsVisualChange: true,
                actions: [.moveClick(x: 90, y: 90, boundary: true)]
            ),
            ExamDecision(
                summary: "incorrectly try to skip unanswered Q2",
                expectsVisualChange: true,
                actions: [.moveClick(x: 90, y: 90, boundary: true)]
            ),
            ExamDecision(
                summary: "answer Q2",
                expectsVisualChange: true,
                actions: [.moveClick(x: 10, y: 10)]
            ),
            ExamDecision(
                summary: "navigate from verified Q2",
                expectsVisualChange: true,
                actions: [.moveClick(x: 90, y: 90, boundary: true)]
            ),
            ExamDecision(summary: "complete", expectsVisualChange: false, actions: [.finish()]),
        ])

        let loop = ExamLoop(
            capture: capture,
            visionAgent: agent,
            executor: ActionBatchExecutor(driver: driver),
            dryRun: false,
            intermediateClickSettler: {},
            postActionSettler: {}
        )

        let result = await loop.run()

        XCTAssertEqual(result, .finished(cycles: 6))
        XCTAssertEqual(driver.calls, ["answer", "next", "answer", "next"])
        XCTAssertEqual(ui.questionGeneration, 3)
    }
}

private final class SimulatedExamUI {
    private let lock = NSLock()
    private var question = 1
    private var answered = false

    var questionGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return question
    }

    func snapshot() -> (question: Int, answered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (question, answered)
    }

    func answer() {
        lock.lock()
        answered = true
        lock.unlock()
    }

    func navigate() {
        lock.lock()
        question += 1
        answered = false
        lock.unlock()
    }
}

private final class SimulatedExamCapture: ScreenCapturing {
    private let ui: SimulatedExamUI

    init(ui: SimulatedExamUI) {
        self.ui = ui
    }

    func capture() async throws -> ScreenFrame {
        let state = ui.snapshot()
        let base = 0.10 + (Double(state.question - 1) * 0.20)
        let gray = CGFloat(min(0.95, base + (state.answered ? 0.04 : 0.0)))
        return try makeSimulatedFrame(gray: gray)
    }
}

private final class SimulatedExamDriver: InputDriving {
    private let ui: SimulatedExamUI
    private(set) var calls: [String] = []

    init(ui: SimulatedExamUI) {
        self.ui = ui
    }

    func moveAndClick(x: Double, y: Double) async throws {
        if x < 50 {
            calls.append("answer")
            ui.answer()
        } else {
            calls.append("next")
            ui.navigate()
        }
    }

    func typeText(_ text: String) async throws {
        calls.append("type")
        ui.answer()
    }

    func pressKey(_ key: String) async throws {
        calls.append("key")
    }

    func scroll(amount: Int) async throws {
        calls.append("scroll")
    }

    func wait(milliseconds: Int) async throws {
        calls.append("wait")
    }
}

private final class RegressionVisionAgent: VisionAgent {
    private var decisions: [ExamDecision]

    init(decisions: [ExamDecision]) {
        self.decisions = decisions
    }

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        guard !decisions.isEmpty else {
            throw NSError(domain: "ExamLoopRegressionTests", code: 1)
        }
        return decisions.removeFirst()
    }
}

private func makeSimulatedFrame(gray: CGFloat) throws -> ScreenFrame {
    guard let context = CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "ExamLoopRegressionTests", code: 2)
    }

    context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    guard let image = context.makeImage() else {
        throw NSError(domain: "ExamLoopRegressionTests", code: 3)
    }

    return ScreenFrame(
        image: image,
        jpegData: Data([1, 2, 3]),
        screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
}
