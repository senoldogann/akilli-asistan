import XCTest
@testable import ZeroLose

final class ModelProviderFabricTests: XCTestCase {
    func testSelectedProviderNeverFallsBack() async throws {
        let codexID = ModelProviderID(rawValue: "codex")
        let codex = RecordingModelProvider(
            id: "codex",
            error: .loginRequired(providerID: codexID)
        )
        let claude = RecordingModelProvider(
            id: "claude",
            events: [.textDelta("wrong-provider"), .completed]
        )
        let fabric = ModelProviderFabric(
            providers: [codex, claude],
            selectedProviderID: codexID
        )

        var thrown: ProviderError?
        do {
            let stream = try await fabric.stream(.fixture())
            for try await _ in stream {}
        } catch let error as ProviderError {
            thrown = error
        }

        let codexRequestCount = await codex.requestCount
        let claudeRequestCount = await claude.requestCount
        XCTAssertEqual(thrown, .loginRequired(providerID: codexID))
        XCTAssertEqual(codexRequestCount, 1)
        XCTAssertEqual(claudeRequestCount, 0)
    }

    func testProviderStatusContainsNoCredentialMaterial() {
        let status = ProviderStatus(
            providerID: ModelProviderID(rawValue: "codex"),
            displayName: "Codex",
            availability: .ready
        )
        let rendered = String(describing: status).lowercased()

        XCTAssertFalse(rendered.contains("token"))
        XCTAssertFalse(rendered.contains("authorization"))
        XCTAssertFalse(rendered.contains("credential"))
    }

    func testSelectingProviderChangesAuthoritativeRoute() async throws {
        let codexID = ModelProviderID(rawValue: "codex")
        let claudeID = ModelProviderID(rawValue: "claude")
        let codex = RecordingModelProvider(id: "codex", events: [.completed])
        let claude = RecordingModelProvider(id: "claude", events: [.completed])
        let fabric = ModelProviderFabric(
            providers: [codex, claude],
            selectedProviderID: codexID
        )

        await fabric.select(claudeID)
        let stream = try await fabric.stream(.fixture())
        for try await _ in stream {}

        let codexRequestCount = await codex.requestCount
        let claudeRequestCount = await claude.requestCount
        XCTAssertEqual(codexRequestCount, 0)
        XCTAssertEqual(claudeRequestCount, 1)
    }
}
