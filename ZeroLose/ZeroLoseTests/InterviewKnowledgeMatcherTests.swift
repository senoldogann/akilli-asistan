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

        XCTAssertGreaterThanOrEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.record.category, "Frontend")
        if matches.count > 1 {
            XCTAssertGreaterThan(matches[0].score, matches[1].score)
        }
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

    func testTopMatchesUsesIntentAliasesForSelfIntroParaphrase() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Intro",
                question: "Kerrotko vähän itsestäsi?",
                answer: "Olen full stack kehittäjä, jolla on yli seitsemän vuoden kokemus.",
                keyPoints: ["itsestäsi", "kokemus"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Kerrotko vähän itsestäsi?",
                    answer: "Olen full stack kehittäjä, jolla on yli seitsemän vuoden kokemus.",
                    translation: "Biraz kendinden bahseder misin?",
                    keyPoints: ["itsestäsi", "kokemus"],
                    category: "Intro"
                )
            ),
            InterviewKnowledgeRecord(
                category: "Compensation",
                question: "Millainen palkkatoive sinulla on?",
                answer: "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.",
                keyPoints: ["palkka"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Millainen palkkatoive sinulla on?",
                    answer: "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.",
                    keyPoints: ["palkka"],
                    category: "Compensation"
                )
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Kuka sinä olet?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Intro")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.22)
    }

    func testTopMatchesUsesTranslationAndIntentForCompanyMotivationVariant() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Motivation",
                question: "Miksi hait juuri Loihteelle?",
                answer: "Loihteessa minua kiinnostaa monipuolinen asiakasympäristö ja pitkäjänteinen kehitys.",
                keyPoints: ["loihde", "motivaatio"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Miksi hait juuri Loihteelle?",
                    answer: "Loihteessa minua kiinnostaa monipuolinen asiakasympäristö ja pitkäjänteinen kehitys.",
                    translation: "Neden özellikle Loihde'ye başvurdun?",
                    keyPoints: ["loihde", "motivaatio"],
                    category: "Motivation"
                )
            ),
            InterviewKnowledgeRecord(
                category: "Career Change",
                question: "Miksi etsit uutta työpaikkaa juuri nyt?",
                answer: "Etsin vakaampaa roolia ja vahvaa tiimiä.",
                keyPoints: ["uusi työ"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Miksi etsit uutta työpaikkaa juuri nyt?",
                    answer: "Etsin vakaampaa roolia ja vahvaa tiimiä.",
                    translation: "Neden şu an yeni iş arıyorsun?",
                    keyPoints: ["uusi työ"],
                    category: "Career Change"
                )
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Neden Loihde'ye başvurdun?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Motivation")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.24)
    }

    func testTopMatchesHandlesEnglishAvailabilityVariant() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Availability",
                question: "Milloin voisit aloittaa?",
                answer: "Voin aloittaa melko joustavasti hyvällä aikataululla.",
                keyPoints: ["aloitus", "joustava"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Milloin voisit aloittaa?",
                    answer: "Voin aloittaa melko joustavasti hyvällä aikataululla.",
                    keyPoints: ["aloitus", "joustava"],
                    category: "Availability"
                )
            ),
            InterviewKnowledgeRecord(
                category: "Work Mode",
                question: "Haluatko työskennellä hybridinä vai etänä?",
                answer: "Hybridimalli sopii minulle hyvin.",
                keyPoints: ["hybridi"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Haluatko työskennellä hybridinä vai etänä?",
                    answer: "Hybridimalli sopii minulle hyvin.",
                    keyPoints: ["hybridi"],
                    category: "Work Mode"
                )
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "When could you start?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Availability")
    }

    func testTopMatchesSeparatesDisagreementFromWorkStyleIntent() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Disagreement",
                question: "Miten toimit, jos sinulla ja tiimikaverillasi on eriävä näkemys teknisestä ratkaisusta?",
                answer: "Keskustelen rauhallisesti vaihtoehtojen hyödyistä ja riskeistä.",
                keyPoints: ["eriävä näkemys", "ratkaisu"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Miten toimit, jos sinulla ja tiimikaverillasi on eriävä näkemys teknisestä ratkaisusta?",
                    answer: "Keskustelen rauhallisesti vaihtoehtojen hyödyistä ja riskeistä.",
                    keyPoints: ["eriävä näkemys", "ratkaisu"],
                    category: "Disagreement"
                )
            ),
            InterviewKnowledgeRecord(
                category: "Work Style",
                question: "Miten kuvailisit omaa työskentelytapaa?",
                answer: "Olen vastuullinen ja itsenäinen kehittäjä.",
                keyPoints: ["työskentelytapa"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Miten kuvailisit omaa työskentelytapaa?",
                    answer: "Olen vastuullinen ja itsenäinen kehittäjä.",
                    keyPoints: ["työskentelytapa"],
                    category: "Work Style"
                )
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Mitä teet, jos olet eri mieltä työkaverin kanssa?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Disagreement")
        XCTAssertNotEqual(matches.first?.record.category, "Work Style")
    }

    func testTopMatchesPreferConflictHandlingOverGenericClientWork() {
        let records = [
            InterviewKnowledgeRecord(
                category: "Client Work",
                question: "Oletko tehnyt asiakastyötä tai ollut suoraan asiakkaiden kanssa tekemisissä?",
                answer: "Kyllä, olen ollut suoraan tekemisissä asiakkaiden kanssa projekteissa.",
                keyPoints: ["asiakastyö", "liiketoiminta"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Oletko tehnyt asiakastyötä tai ollut suoraan asiakkaiden kanssa tekemisissä?",
                    answer: "Kyllä, olen ollut suoraan tekemisissä asiakkaiden kanssa projekteissa.",
                    keyPoints: ["asiakastyö", "liiketoiminta"],
                    category: "Client Work"
                )
            ),
            InterviewKnowledgeRecord(
                category: "Conflict Handling",
                question: "Miten toimit, jos asiakkaan kanssa tulee ongelmatilanne tai jokin asia ei mene odotetusti?",
                answer: "Selvitän tilanteen rauhallisesti, käyn faktat läpi ja ehdotan selkeitä seuraavia askelia.",
                keyPoints: ["ongelmatilanne", "asiakas", "rauhallinen"],
                aliases: InterviewKnowledgeMatcher.makeInterviewAliases(
                    question: "Miten toimit, jos asiakkaan kanssa tulee ongelmatilanne tai jokin asia ei mene odotetusti?",
                    answer: "Selvitän tilanteen rauhallisesti, käyn faktat läpi ja ehdotan selkeitä seuraavia askelia.",
                    keyPoints: ["ongelmatilanne", "asiakas", "rauhallinen"],
                    category: "Conflict Handling"
                )
            )
        ]

        let matches = InterviewKnowledgeMatcher.topMatches(
            query: "Mitä teet, kun sinulla on ongelmia työtovereiden tai asiakkaiden kanssa?",
            records: records,
            maxResults: 2,
            minimumScore: 0.10
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.category, "Conflict Handling")
        XCTAssertNotEqual(matches.first?.record.category, "Client Work")
    }
}
