import CoreGraphics
import XCTest
@testable import ExamPilotCore

final class OutcomeVerifierTests: XCTestCase {
    func testAnswerMutationRequiresVisibleButNonStructuralChange() throws {
        let before = try makeImage(gray: 0.40)
        let changed = try makeImage(gray: 0.44)

        let result = OutcomeVerifier().verify(
            expected: .answerMutation,
            before: before,
            after: changed,
            uiStable: true
        )

        guard case .success(.answerMutation(let score)) = result else {
            return XCTFail("Expected answer-mutation success, got \(result)")
        }
        XCTAssertEqual(score, 10.0 / 255.0, accuracy: 0.01)
    }

    func testAnswerMutationWithLargeStructuralShiftIsPendingTransition() throws {
        let before = try makeImage(gray: 0.10)
        let after = try makeImage(gray: 0.90)

        XCTAssertEqual(
            OutcomeVerifier().verify(
                expected: .answerMutation,
                before: before,
                after: after,
                uiStable: true
            ),
            .pending(.unexpectedStructuralChange)
        )
    }

    func testNavigationCannotSucceedUntilStable() throws {
        let before = try makeImage(gray: 0.10)
        let after = try makeImage(gray: 0.90)

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

    func testStableNavigationFailsWhenIdentityDidNotMateriallyChange() throws {
        let frame = try makeImage(gray: 0.40)

        XCTAssertEqual(
            OutcomeVerifier().verify(
                expected: .navigation,
                before: frame,
                after: frame,
                uiStable: true
            ),
            .failure(.navigationIdentityUnchanged)
        )
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
            throw NSError(domain: "OutcomeVerifierTests", code: 1)
        }

        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw NSError(domain: "OutcomeVerifierTests", code: 2)
        }
        return image
    }
}
