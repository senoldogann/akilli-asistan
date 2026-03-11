import XCTest
@testable import ZeroLose

final class InterviewKnowledgeMatcherTests: XCTestCase {
    func testTopMatchesPrioritizesAnswerSentenceMatch() {
        let records = [
            InterviewKnowledgeRecord(
                category: "System Design",
                question: "How do you handle monolith migration?",
                answer: "Use Strangler Fig pattern and split bounded contexts gradually.",
                keyPoints: ["strangler", "incremental migration"]
            ),
            InterviewKnowledgeRecord(
                category: "Communication",
                question: "How do you run stakeholder updates?",
                answer: "Give weekly brief updates with risk and ETA.",
                keyPoints: ["clarity", "risk"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "strangler fig pattern ile migration nasıl yapılır",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "System Design")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.30)
    }

    func testTopMatchesReturnsOrderedRelevance() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Frontend",
                question: "How do you optimize React rendering?",
                answer: "Use memoization, split state boundaries, and profile bottlenecks.",
                keyPoints: ["react", "memoization", "profiling"]
            ),
            InterviewKnowledgeRecord(
                category: "Backend",
                question: "How do you scale PostgreSQL?",
                answer: "Use indexing and partitioning after query profiling.",
                keyPoints: ["postgres", "indexing", "partitioning"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "React render performansını nasıl optimize edersin?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.record.category, "Frontend")
    }

    func testTopMatchesHandlesQuestionVariants() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Architecture",
                question: "How do you handle technical debt in legacy systems?",
                answer: "I prioritize impact, create a remediation backlog, and execute incrementally.",
                keyPoints: ["technical debt", "legacy", "prioritization"]
            ),
            InterviewKnowledgeRecord(
                category: "Leadership",
                question: "How do you mentor junior developers?",
                answer: "I pair-program and give clear feedback loops.",
                keyPoints: ["mentoring", "growth"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Legacy kodda biriken borcu nasıl yönetiyorsun?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Architecture")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.28)
    }

    func testTopMatchesFinnishIntroDoesNotDriftToSalary() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Intro",
                question: "Kerrotko vähän itsestäsi?",
                answer: "Olen full stack kehittäjä ja minulla on yli seitsemän vuoden kokemus.",
                keyPoints: ["itsestäsi", "kokemus"]
            ),
            InterviewKnowledgeRecord(
                category: "Compensation",
                question: "Millainen palkkatoive sinulla on?",
                answer: "Palkkatoiveeni on noin 5600-6200 euroa kuukaudessa.",
                keyPoints: ["palkkatoive", "palkka"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Puhu sinusta",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Intro")
    }

    func testTopMatchesFinnishAskBackVariant() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Closing",
                question: "Haluatko kysyä meiltä jotain?",
                answer: "Kyllä, haluaisin kysyä tiimin työskentelystä ja projektien rakenteesta.",
                keyPoints: ["kysyä", "meiltä"]
            ),
            InterviewKnowledgeRecord(
                category: "Compensation",
                question: "Millainen palkkatoive sinulla on?",
                answer: "Palkkatoive riippuu roolista ja vastuista.",
                keyPoints: ["palkkatoive"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Onko kysymyksiä minulle?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Closing")
    }

    func testTopMatchesShortQueryNeedsQuestionEvidence() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Compensation",
                question: "Millainen palkkatoive sinulla on?",
                answer: "Taustani on React- ja Node.js-kehityksessä.",
                keyPoints: ["palkkatoive"]
            ),
            InterviewKnowledgeRecord(
                category: "Intro",
                question: "Kerro vähän itsestäsi?",
                answer: "Olen kokenut full stack kehittäjä.",
                keyPoints: ["itsestäsi", "kokemus"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Puhu sinusta",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Intro")
        XCTAssertNotEqual(matches.first?.record.category, "Compensation")
    }

    func testTopMatchesFinnishSalaryVariantWithTypo() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Compensation",
                question: "Millainen palkkatoive sinulla on?",
                answer: "Palkkatoiveeni on noin 5600-6200 euroa kuukaudessa.",
                keyPoints: ["palkkatoive", "salary", "compensation"]
            ),
            InterviewKnowledgeRecord(
                category: "Intro",
                question: "Kerrotko vähän itsestäsi?",
                answer: "Olen kokenut full stack kehittäjä.",
                keyPoints: ["itsestäsi", "kokemus"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Entä palkkatavoiteet?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Compensation")
    }

    func testTopMatchesFinnishSalaryColloquialSunVariant() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Compensation",
                question: "Millainen palkkatoive sinulla on?",
                answer: "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.",
                keyPoints: ["palkkatoive", "salary", "compensation"]
            ),
            InterviewKnowledgeRecord(
                category: "Intro",
                question: "Kerrotko vähän itsestäsi?",
                answer: "Olen kokenut full stack kehittäjä.",
                keyPoints: ["itsestäsi", "kokemus"]
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Mitä sun palkkatoive?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Compensation")
    }
}
