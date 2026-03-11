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
}
