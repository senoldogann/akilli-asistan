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

    func testSelectedModelCapabilityFollowsAuthoritativeProviderSelection() async {
        let codexID = ModelProviderID(rawValue: "codex")
        let openAIID = ModelProviderID(rawValue: "openai")
        let codex = RecordingModelProvider(
            id: "codex",
            capabilities: [.textStreaming]
        )
        let openAI = RecordingModelProvider(
            id: "openai",
            capabilities: [.textStreaming, .jsonOutput]
        )
        let fabric = ModelProviderFabric(
            providers: [codex, openAI],
            selectedProviderID: codexID
        )

        let codexSupportsJSON = await fabric.selectedModelSupports(
            .jsonOutput,
            modelID: "default"
        )
        XCTAssertFalse(codexSupportsJSON)

        await fabric.select(openAIID)
        let openAISupportsJSON = await fabric.selectedModelSupports(
            .jsonOutput,
            modelID: "default"
        )
        let unknownModelSupportsJSON = await fabric.selectedModelSupports(
            .jsonOutput,
            modelID: "unknown-model"
        )
        XCTAssertTrue(openAISupportsJSON)
        XCTAssertFalse(unknownModelSupportsJSON)
    }

    func testExplicitModelCapabilityCheckIgnoresMutableSelection() async {
        let textOnlyID = ModelProviderID(rawValue: "text-only")
        let jsonID = ModelProviderID(rawValue: "json")
        let textOnly = RecordingModelProvider(
            id: "text-only",
            capabilities: [.textStreaming]
        )
        let json = RecordingModelProvider(
            id: "json",
            capabilities: [.textStreaming, .jsonOutput]
        )
        let fabric = ModelProviderFabric(
            providers: [textOnly, json],
            selectedProviderID: textOnlyID
        )

        let explicitJSONSupport = await fabric.modelSupports(
            .jsonOutput,
            modelID: "default",
            using: jsonID
        )
        let explicitTextOnlySupport = await fabric.modelSupports(
            .jsonOutput,
            modelID: "default",
            using: textOnlyID
        )

        XCTAssertTrue(explicitJSONSupport)
        XCTAssertFalse(explicitTextOnlySupport)
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

    func testExplicitProviderStreamIgnoresMutableSelection() async throws {
        let codexID = ModelProviderID(rawValue: "codex")
        let claudeID = ModelProviderID(rawValue: "claude")
        let codex = RecordingModelProvider(id: "codex", events: [.completed])
        let claude = RecordingModelProvider(id: "claude", events: [.completed])
        let fabric = ModelProviderFabric(
            providers: [codex, claude],
            selectedProviderID: codexID
        )

        await fabric.select(claudeID)
        let stream = try await fabric.stream(.fixture(), using: codexID)
        for try await _ in stream {}

        let codexRequestCount = await codex.requestCount
        let claudeRequestCount = await claude.requestCount
        XCTAssertEqual(codexRequestCount, 1)
        XCTAssertEqual(claudeRequestCount, 0)
    }

    func testExplicitProviderCancellationUsesBoundProviderAfterSelectionChanges() async {
        let codexID = ModelProviderID(rawValue: "codex")
        let claudeID = ModelProviderID(rawValue: "claude")
        let codex = RecordingModelProvider(id: "codex")
        let claude = RecordingModelProvider(id: "claude")
        let fabric = ModelProviderFabric(
            providers: [codex, claude],
            selectedProviderID: codexID
        )
        let sessionID = ModelSessionID(rawValue: "bound-session")

        await fabric.select(claudeID)
        await fabric.cancel(sessionID: sessionID, using: codexID)

        let codexCancelled = await codex.cancelledSessions
        let claudeCancelled = await claude.cancelledSessions
        XCTAssertEqual(codexCancelled, [sessionID])
        XCTAssertEqual(claudeCancelled, [])
    }

    func testExplicitProviderStreamFailsClosedForUnknownProvider() async {
        let codexID = ModelProviderID(rawValue: "codex")
        let missingID = ModelProviderID(rawValue: "missing")
        let codex = RecordingModelProvider(id: "codex")
        let fabric = ModelProviderFabric(
            providers: [codex],
            selectedProviderID: codexID
        )

        do {
            _ = try await fabric.stream(.fixture(), using: missingID)
            XCTFail("Expected unknown explicit provider to fail closed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .providerUnavailable(providerID: missingID))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegisteredProviderIDsAreDeterministicAndSorted() async {
        let fabric = ModelProviderFabric(
            providers: [
                RecordingModelProvider(id: "opencode"),
                RecordingModelProvider(id: "claude"),
                RecordingModelProvider(id: "codex")
            ],
            selectedProviderID: ModelProviderID(rawValue: "codex")
        )

        let ids = await fabric.registeredProviderIDs()

        XCTAssertEqual(ids.map(\.rawValue), ["claude", "codex", "opencode"])
    }

    func testCapabilitiesReturnRegisteredProviderCapabilities() async throws {
        let codexID = ModelProviderID(rawValue: "codex")
        let fabric = ModelProviderFabric(
            providers: [
                RecordingModelProvider(
                    id: "codex",
                    capabilities: [.textStreaming, .jsonOutput]
                )
            ],
            selectedProviderID: codexID
        )

        let capabilities = try await fabric.capabilities(for: codexID)

        XCTAssertTrue(capabilities.contains(.textStreaming))
        XCTAssertTrue(capabilities.contains(.jsonOutput))
    }

    func testCapabilitiesFailClosedForUnknownProvider() async {
        let codexID = ModelProviderID(rawValue: "codex")
        let missingID = ModelProviderID(rawValue: "missing")
        let fabric = ModelProviderFabric(
            providers: [RecordingModelProvider(id: "codex")],
            selectedProviderID: codexID
        )

        do {
            _ = try await fabric.capabilities(for: missingID)
            XCTFail("Expected unknown provider capabilities to fail closed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .providerUnavailable(providerID: missingID))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
