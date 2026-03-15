import XCTest
@testable import ZeroLose

final class ResponseCacheServiceTests: XCTestCase {
    private static var retainedServices: [ResponseCacheService] = []

    private func makeCacheURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroLoseTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ResponseCache.json")
    }

    private func makeService() -> ResponseCacheService {
        let service = ResponseCacheService(cacheURL: makeCacheURL())
        Self.retainedServices.append(service)
        return service
    }

    func testPrimeInterviewVaultKeepsDistinctCategoryEntries() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("Kerro itsestäsi?", "Olen kokenut kehittäjä.", "Intro"),
            ("Kerro itsestäsi?", "Vahvuuteni on tiimityö.", "Culture")
        ]

        let count = service.primeInterviewVault(entries: entries)
        let coverage = service.interviewVaultCoverage(entries: entries)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(coverage.total, 2)
        XCTAssertEqual(coverage.cached, 2)
        XCTAssertEqual(coverage.missing, 0)
    }

    func testInterviewVaultCoverageReportsMissingEntries() {
        let service = makeService()
        let existing: [(question: String, answer: String, category: String)] = [
            ("Miksi haet meille?", "Rooli ja tiimi kiinnostavat.", "Motivation")
        ]
        let requested: [(question: String, answer: String, category: String)] = [
            ("Miksi haet meille?", "Rooli ja tiimi kiinnostavat.", "Motivation"),
            ("Millainen palkkatoive sinulla on?", "5 600 - 6 200 euroa.", "Compensation")
        ]

        _ = service.primeInterviewVault(entries: existing)
        let coverage = service.interviewVaultCoverage(entries: requested)

        XCTAssertEqual(coverage.total, 2)
        XCTAssertEqual(coverage.cached, 1)
        XCTAssertEqual(coverage.missing, 1)
    }

    func testGetResponseFindsFinnishSalaryVariant() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("Millainen palkkatoive sinulla on?", "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.", "Compensation")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Entä palkkatavoiteet?")

        XCTAssertNotNil(answer)
        XCTAssertEqual(answer, "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.")
    }

    func testGetResponseFindsFinnishSalaryColloquialSunVariant() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("Millainen palkkatoive sinulla on?", "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.", "Compensation")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Mitä sun palkkatoive?")

        XCTAssertNotNil(answer)
        XCTAssertEqual(answer, "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.")
    }

    func testGetResponseFindsSelfIntroParaphraseFromCache() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("Kerrotko vähän itsestäsi?", "Olen full stack kehittäjä, jolla on yli seitsemän vuoden kokemus.", "Intro")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Kuka sinä olet?")

        XCTAssertNotNil(answer)
        XCTAssertEqual(answer, "Olen full stack kehittäjä, jolla on yli seitsemän vuoden kokemus.")
    }

    func testGetResponseFindsProjectStartParaphraseFromCache() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("Miten aloitat uuden projektin?", "Aloitan aina ymmärtämällä tavoitteet, rajaukset ja tärkeimmät riskit ennen toteutusta.", "Project Delivery")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Mitä teet ensimmäisenä, kun aloitat projektin?")

        XCTAssertNotNil(answer)
        XCTAssertEqual(answer, "Aloitan aina ymmärtämällä tavoitteet, rajaukset ja tärkeimmät riskit ennen toteutusta.")
    }

    func testGetResponseFindsEnglishIncidentNearMatch() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("How do you solve a production incident quickly?", "I stabilize first, then root-cause and prevent recurrence.", "Incident")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "How do you solve production incidents quickly")

        XCTAssertNotNil(answer)
        XCTAssertEqual(answer, "I stabilize first, then root-cause and prevent recurrence.")
    }

    func testGetResponseFindsTechnicalDebtParaphraseAcrossLanguages() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("How do you handle technical debt in legacy projects?", "I rank debt by risk and fix it incrementally.", "Architecture")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Legacy kod tabanındaki borcu nasıl yönetiyorsun?")

        XCTAssertNotNil(answer)
        XCTAssertEqual(answer, "I rank debt by risk and fix it incrementally.")
    }

    func testGetResponseSkipsInterviewCacheForCodingRequests() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            ("Oletko enemmän frontend- vai backend-kehittäjä?", "Olen aidosti full stack -kehittäjä.", "Interview Notes")
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Voitko kirjoita authentication api with next.js?")

        XCTAssertNil(answer)
    }

    func testGetResponseAllowsExactCodingMatchForFastInterviewFlow() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            (
                "How do you debug memory leaks in Node.js services?",
                "I reproduce with controlled load, profile heap growth, identify retaining paths, and patch the leak with a regression test.",
                "Coding"
            )
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "How do you debug memory leaks in Node.js services?")

        XCTAssertEqual(
            answer,
            "I reproduce with controlled load, profile heap growth, identify retaining paths, and patch the leak with a regression test."
        )
    }

    func testGetResponseSkipsAmbiguousClientAndCoworkerConflictFromCache() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            (
                "Oletko tehnyt asiakastyötä tai ollut suoraan asiakkaiden kanssa tekemisissä?",
                "Kyllä, olen ollut suoraan tekemisissä asiakkaiden kanssa projekteissa.",
                "Client Work"
            ),
            (
                "Miten toimit, jos asiakkaan kanssa tulee ongelmatilanne tai jokin asia ei mene odotetusti?",
                "Selvitän tilanteen rauhallisesti, käyn faktat läpi ja ehdotan selkeitä seuraavia askelia.",
                "Conflict Handling"
            )
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Mitä teet, kun sinulla on ongelmia työtovereiden tai asiakkaiden kanssa?")

        XCTAssertNil(answer)
    }

    func testGetResponseFindsClientProblemHandlingWhenConceptsAlign() {
        let service = makeService()
        let entries: [(question: String, answer: String, category: String)] = [
            (
                "Miten toimit, jos asiakkaan kanssa tulee ongelmatilanne tai jokin asia ei mene odotetusti?",
                "Selvitän tilanteen rauhallisesti, käyn faktat läpi ja ehdotan selkeitä seuraavia askelia.",
                "Conflict Handling"
            )
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Miten toimit, jos asiakkaan kanssa tulee ongelmia?")

        XCTAssertEqual(
            answer,
            "Selvitän tilanteen rauhallisesti, käyn faktat läpi ja ehdotan selkeitä seuraavia askelia."
        )
    }

    func testGetResponseFindsEnglishQuestionFromFinnishCachedTranslationAlias() {
        let service = makeService()
        let entries = [
            ResponseCacheService.InterviewCacheEntry(
                question: "Millainen kokemus sinulla on Node.js:stä?",
                answer: "Node.js on ollut vahvin backend-stackini useissa asiakas- ja tuoteprojekteissa.",
                category: "Technical",
                translation: "Can you tell me about your Node.js experience? What kind of Node.js experience do you have?",
                keyPoints: ["Node.js", "backend", "REST API"]
            )
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Can you tell me about your Node.js experience?")

        XCTAssertEqual(
            answer,
            "Node.js on ollut vahvin backend-stackini useissa asiakas- ja tuoteprojekteissa."
        )
    }

    func testGetResponseSkipsComparisonQuestionWhenCacheOnlyMatchesOneSide() {
        let service = makeService()
        let entries = [
            ResponseCacheService.InterviewCacheEntry(
                question: "Mitä tarkoittaa hyvä REST API sinun mielestäsi?",
                answer: "Hyvä REST API on selkeä, johdonmukainen ja turvallinen käyttää.",
                category: "Technical",
                translation: "What makes a good REST API?",
                keyPoints: ["REST API", "API design", "security"]
            )
        ]

        _ = service.primeInterviewVault(entries: entries)
        let answer = service.getResponse(for: "Milloin Context API ja milloin rest api ?")

        XCTAssertNil(answer)
    }
}
