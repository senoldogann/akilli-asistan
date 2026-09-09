import CoreGraphics
import XCTest
@testable import ExamPilotCore

final class ExtractionCharacterizationTests: XCTestCase {
    func testSessionAdvancesStateVersionAfterObservation() {
        let session = ComputerAgentSession(
            id: "extraction-session",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(stateVersion: 7)
        )
        let oldVersion = session.runtimeState.stateVersion

        session.acceptObservation()

        XCTAssertGreaterThan(session.runtimeState.stateVersion, oldVersion)
    }

    func testExamNavigationStillRequiresVerifiedAnswer() throws {
        var state = ExamRuntimeState(stateVersion: 10)
        let decision = ExamDecision(
            summary: "navigate",
            expectsVisualChange: true,
            actions: [.moveClick(x: 100, y: 100, boundary: true)]
        )
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let policy = ActionBatchPolicy()

        XCTAssertFalse(state.navigationAllowed)
        XCTAssertThrowsError(
            try policy.validate(
                decision,
                screenBounds: bounds,
                context: ActionPolicyContext(
                    stateVersion: state.stateVersion,
                    navigationAllowed: state.navigationAllowed
                )
            )
        ) { error in
            XCTAssertEqual(error as? ActionValidationError, .protectedBoundaryBeforeAnswer)
        }

        state.recordAnswerVerified()
        XCTAssertTrue(state.navigationAllowed)

        let batch = try policy.validate(
            decision,
            screenBounds: bounds,
            context: ActionPolicyContext(
                stateVersion: state.stateVersion,
                navigationAllowed: state.navigationAllowed
            )
        )
        XCTAssertEqual(batch.expectedOutcome, .navigation)
    }

    func testProviderContinuationSurvivesProviderTurnAndSnapshot() {
        let session = ComputerAgentSession(
            id: "continuation-session",
            goal: "Run",
            initialRuntimeState: ExamRuntimeState(stateVersion: 12)
        )
        session.applyProviderTurn(
            ComputerAgentProviderTurn(
                responseID: "resp-1",
                computerCallID: "call-1",
                actions: [NativeComputerAction(kind: .screenshot)],
                finalText: nil
            )
        )

        let state = session.computerProviderState()

        XCTAssertEqual(state.previousResponseID, "resp-1")
        XCTAssertEqual(state.pendingComputerCallID, "call-1")
        XCTAssertEqual(state.stateVersion, 12)
    }

    func testRepeatedIntentRecoveryBudgetIsBounded() {
        let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
        let intent = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "retry",
                expectsVisualChange: true,
                actions: [.moveClick(x: 120, y: 160)]
            ),
            questionGeneration: 1
        )

        XCTAssertEqual(
            engine.handle(failure: .noVisibleEffect, intent: intent),
            .recover(strategy: .reobserveAndReplan, attempt: 1)
        )
        XCTAssertEqual(
            engine.handle(failure: .noVisibleEffect, intent: intent),
            .recover(strategy: .reobserveAndReplan, attempt: 2)
        )
        XCTAssertEqual(
            engine.handle(failure: .noVisibleEffect, intent: intent),
            .exhausted(reason: .repeatedIntentLoop)
        )
    }

    func testNavigationVerificationWaitsForStableUI() throws {
        let before = try makeImage(gray: 0.1)
        let after = try makeImage(gray: 0.9)

        XCTAssertEqual(
            OutcomeVerifier().verify(
                expected: .navigation,
                before: before,
                after: after,
                uiStable: false
            ),
            .pending(.uiTransitioning)
        )
    }

    func testStopRequestIsMonotonic() {
        let session = ComputerAgentSession(id: "stop-session", goal: "Run")

        session.requestStop()
        XCTAssertEqual(session.stopState, .stopRequested)

        session.markStopped()
        session.requestStop()

        XCTAssertEqual(session.stopState, .stopped)
    }

    private func makeImage(gray: CGFloat) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "ExtractionCharacterizationTests", code: 1)
        }

        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "ExtractionCharacterizationTests", code: 2)
        }
        return image
    }
}
