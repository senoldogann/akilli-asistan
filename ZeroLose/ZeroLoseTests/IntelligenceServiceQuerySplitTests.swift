import XCTest
@testable import ZeroLose

final class IntelligenceServiceQuerySplitTests: XCTestCase {
    func testSplitQuestionSegmentsHandlesTwoFinnishQuestions() {
        let query = "Voitko kertoa itsestäsi? Miksi Loihde?"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], "Voitko kertoa itsestäsi?")
        XCTAssertEqual(segments[1], "Miksi Loihde?")
    }

    func testSplitQuestionSegmentsReturnsEmptyWithoutQuestionMark() {
        let query = "Kerro itsestäsi ja miksi Loihde"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertTrue(segments.isEmpty)
    }

    func testSplitQuestionSegmentsDeduplicatesAndCapsToThree() {
        let query = "Miksi Loihde? Miksi Loihde? Voitko kertoa itsestäsi? Milloin voit aloittaa? Paljonko palkka?"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], "Miksi Loihde?")
        XCTAssertEqual(segments[1], "Voitko kertoa itsestäsi?")
        XCTAssertEqual(segments[2], "Milloin voit aloittaa?")
    }
}
