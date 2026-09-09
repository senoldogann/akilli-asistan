import XCTest
@testable import ExamPilotCore

final class ChromeDevToolsEndpointTests: XCTestCase {
    func testAcceptsLoopbackHTTPHosts() throws {
        XCTAssertNoThrow(try ChromeDevToolsEndpoint(url: URL(string: "http://127.0.0.1:9222")!))
        XCTAssertNoThrow(try ChromeDevToolsEndpoint(url: URL(string: "http://localhost:9333")!))
        XCTAssertNoThrow(try ChromeDevToolsEndpoint(url: URL(string: "http://[::1]:9444")!))
    }

    func testRejectsNonLoopbackOrCredentialedEndpoints() {
        XCTAssertThrowsError(try ChromeDevToolsEndpoint(url: URL(string: "http://example.com:9222")!))
        XCTAssertThrowsError(try ChromeDevToolsEndpoint(url: URL(string: "https://127.0.0.1:9222")!))
        XCTAssertThrowsError(try ChromeDevToolsEndpoint(url: URL(string: "http://user:pass@127.0.0.1:9222")!))
        XCTAssertThrowsError(try ChromeDevToolsEndpoint(url: URL(string: "http://127.0.0.1:9222/some/path")!))
    }

    func testBuildsOnlyKnownReadOnlyDiscoveryURLs() throws {
        let endpoint = try ChromeDevToolsEndpoint(url: URL(string: "http://127.0.0.1:9222")!)

        XCTAssertEqual(endpoint.versionURL.absoluteString, "http://127.0.0.1:9222/json/version")
        XCTAssertEqual(endpoint.targetsURL.absoluteString, "http://127.0.0.1:9222/json/list")
    }
}
