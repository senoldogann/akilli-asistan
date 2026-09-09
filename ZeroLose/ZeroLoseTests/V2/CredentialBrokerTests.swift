import XCTest
@testable import ZeroLose

final class CredentialBrokerTests: XCTestCase {
    func testAvailabilityExposesOnlyScopeMetadata() async {
        let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])

        let availability = await broker.availability(
            for: CredentialScope(rawValue: "openai.responses")
        )

        XCTAssertTrue(availability.available)
        XCTAssertEqual(availability.scope, CredentialScope(rawValue: "openai.responses"))
    }

    func testRevocationInvalidatesHandle() async throws {
        let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])
        let scope = CredentialScope(rawValue: "openai.responses")

        let handle = try await broker.issueHandle(for: scope)
        await broker.revoke(scope: scope)
        let isValid = await broker.isValid(handle)

        XCTAssertFalse(isValid)
    }
}
