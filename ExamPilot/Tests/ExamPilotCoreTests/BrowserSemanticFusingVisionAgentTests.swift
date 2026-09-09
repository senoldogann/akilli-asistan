import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class BrowserSemanticFusingVisionAgentTests: XCTestCase {
    func testMatchingSnapshotIsForwardedWithoutChangingRuntimeAuthority() async throws {
        let frame = try makeFrame(processID: 42)
        let base = RecordingBrowserSemanticVisionAgent()
        let observer = StubBrowserSemanticObserver(result: .success(
            BrowserSemanticSnapshot(
                stateVersion: 9,
                processID: 42,
                windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
                viewportWidth: 760,
                viewportHeight: 470,
                elements: [
                    BrowserSemanticElementHint(
                        role: .radioButton,
                        bounds: BrowserSemanticNormalizedBounds(x: 0.4, y: 0.5, width: 0.1, height: 0.05),
                        isFocused: false,
                        isSelected: true,
                        isEnabled: true
                    )
                ]
            )
        ))
        let accessibility = AccessibilityObservation(
            stateVersion: 9,
            processID: 42,
            windowBounds: AccessibilityBounds(x: 10, y: 20, width: 800, height: 600),
            elements: []
        )
        let original = ExamObservationState(
            cycle: 3,
            nonProgressCount: 1,
            lastSummary: "previous",
            stateVersion: 9,
            questionGeneration: 4,
            answerVerified: false,
            uiPhase: .stable,
            accessibility: accessibility
        )
        let agent = BrowserSemanticFusingVisionAgent(base: base, observer: observer)

        _ = try await agent.decide(frame: frame, state: original)

        let forwarded = try XCTUnwrap(base.lastState)
        XCTAssertEqual(forwarded.stateVersion, 9)
        XCTAssertEqual(forwarded.questionGeneration, 4)
        XCTAssertFalse(forwarded.answerVerified)
        XCTAssertEqual(forwarded.uiPhase, .stable)
        XCTAssertEqual(forwarded.accessibility, accessibility)
        XCTAssertEqual(forwarded.browserSemantics?.elements.first?.role, .radioButton)
        XCTAssertEqual(forwarded.browserSemantics?.elements.first?.isSelected, true)
    }

    func testObserverFailureFallsBackWithoutBrowserHints() async throws {
        let frame = try makeFrame(processID: 42)
        let base = RecordingBrowserSemanticVisionAgent()
        let observer = StubBrowserSemanticObserver(result: .failure(TestError.failed))
        let agent = BrowserSemanticFusingVisionAgent(base: base, observer: observer)

        _ = try await agent.decide(
            frame: frame,
            state: ExamObservationState(cycle: 1, nonProgressCount: 0, lastSummary: nil, stateVersion: 2)
        )

        XCTAssertNil(base.lastState?.browserSemantics)
        XCTAssertEqual(base.callCount, 1)
    }

    func testStaleSnapshotFallsBackWithoutBrowserHints() async throws {
        let frame = try makeFrame(processID: 42)
        let base = RecordingBrowserSemanticVisionAgent()
        let observer = StubBrowserSemanticObserver(result: .success(
            BrowserSemanticSnapshot(
                stateVersion: 1,
                processID: 42,
                windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
                viewportWidth: 760,
                viewportHeight: 470,
                elements: []
            )
        ))
        let agent = BrowserSemanticFusingVisionAgent(base: base, observer: observer)

        _ = try await agent.decide(
            frame: frame,
            state: ExamObservationState(cycle: 1, nonProgressCount: 0, lastSummary: nil, stateVersion: 2)
        )

        XCTAssertNil(base.lastState?.browserSemantics)
        XCTAssertEqual(base.lastState?.stateVersion, 2)
    }

    private func makeFrame(processID: Int32) throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "BrowserSemanticFusingVisionAgentTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            targetProcessID: processID
        )
    }
}

private final class RecordingBrowserSemanticVisionAgent: VisionAgent {
    var lastState: ExamObservationState?
    var callCount = 0

    func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        callCount += 1
        lastState = state
        return ExamDecision(summary: "done", expectsVisualChange: false, actions: [.finish()])
    }
}

private final class StubBrowserSemanticObserver: BrowserSemanticObserving {
    let result: Result<BrowserSemanticSnapshot?, Error>

    init(result: Result<BrowserSemanticSnapshot?, Error>) {
        self.result = result
    }

    func observe(target: ScreenFrame, stateVersion: UInt64) async throws -> BrowserSemanticSnapshot? {
        try result.get()
    }
}

private enum TestError: Error {
    case failed
}
