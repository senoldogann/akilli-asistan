import Foundation
import XCTest
@testable import ZeroLose

final class OpenAIAPIProviderTests: XCTestCase {
    func testProviderAdvertisesOnlyCapabilitiesImplementedByCanonicalRequestSurface() {
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: "sk-test"),
            transport: RecordingOpenAITransport()
        )

        XCTAssertTrue(provider.capabilities.contains(.textStreaming))
        XCTAssertTrue(provider.capabilities.contains(.structuredTools))
        XCTAssertTrue(provider.capabilities.contains(.jsonOutput))
        XCTAssertFalse(provider.capabilities.contains(.vision))
        XCTAssertFalse(provider.capabilities.contains(.reasoningControl))
    }

    func testMissingKeyIsConfigurationRequired() async {
        let credentials = StubOpenAIKeyStore(value: nil)
        let provider = OpenAIAPIProvider(
            credentials: credentials,
            transport: RecordingOpenAITransport()
        )

        let status = await provider.status()

        XCTAssertEqual(status.availability, .configurationRequired)
    }

    func testProviderStatusNeverContainsStoredKey() async {
        let secret = "sk-test-do-not-render"
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: secret),
            transport: RecordingOpenAITransport()
        )

        let rendered = String(describing: await provider.status())

        XCTAssertFalse(rendered.contains(secret))
    }

    @MainActor
    func testKeychainStoreDoesNotCopySecretIntoUserDefaults() async throws {
        let secret = "sk-test-\(UUID().uuidString)"
        let service = "com.zerolose.tests.openai.\(UUID().uuidString)"
        let store = KeychainCredentialBrokerAdapter(openAIKeyService: service)
        let recovery = BooleanTestState()

        try await store.store(secret)
        let hasKey = await store.hasKey()
        try await store.withKey { value in
            await recovery.set(value == secret)
        }
        let recoveredMatches = await recovery.value
        let leakedToDefaults = UserDefaults.standard.dictionaryRepresentation().values.contains {
            String(describing: $0).contains(secret)
        }
        try await store.remove()

        XCTAssertTrue(hasKey)
        XCTAssertTrue(recoveredMatches)
        XCTAssertFalse(leakedToDefaults)
    }

    func testTransportEventsMapToCanonicalModelEvents() async throws {
        let arguments = Data(#"{"query":"swift concurrency"}"#.utf8)
        let transport = RecordingOpenAITransport(events: [
            .created,
            .textDelta("hello"),
            .functionCall(name: "web_search", argumentsJSON: arguments),
            .completed
        ])
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: "sk-test"),
            transport: transport
        )

        var events: [ModelEvent] = []
        for try await event in provider.stream(.fixture()) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .started,
                .textDelta("hello"),
                .toolCall(name: "web_search", argumentsJSON: arguments),
                .completed
            ]
        )
    }

    func testProviderMapsCanonicalRequestWithoutCredentialMaterial() async throws {
        let transport = RecordingOpenAITransport(events: [.created, .completed])
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: "sk-secret-never-in-request"),
            transport: transport
        )
        let request = ModelRequest(
            sessionID: ModelSessionID(rawValue: "openai-session"),
            conversation: [
                ModelMessage(role: .system, content: "system guidance"),
                ModelMessage(role: .user, content: "hello")
            ],
            modelID: "gpt-5.6",
            tools: [
                ModelToolSchema(
                    name: "web_search",
                    description: "Search the web",
                    inputSchemaJSON: Data(#"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#.utf8)
                )
            ],
            responseMode: .text
        )

        for try await _ in provider.stream(request) {}
        let requests = await transport.requests
        let recorded = try XCTUnwrap(requests.first)
        let serialized = String(describing: recorded)

        XCTAssertEqual(recorded.sessionID, request.sessionID)
        XCTAssertEqual(recorded.model, "gpt-5.6")
        XCTAssertEqual(recorded.input.map(\.role), [.system, .user])
        XCTAssertEqual(recorded.tools.map(\.name), ["web_search"])
        XCTAssertFalse(serialized.contains("sk-secret-never-in-request"))
        XCTAssertFalse(serialized.lowercased().contains("authorization"))
    }

    func testInvalidCredentialIsNormalizedWithoutSecretMaterial() async throws {
        let secret = "sk-invalid-secret"
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: secret),
            transport: RecordingOpenAITransport(
                terminalError: .httpStatus(statusCode: 401, code: "invalid_api_key")
            )
        )

        let error = await captureProviderError(from: provider)

        XCTAssertEqual(error, .invalidCredential(providerID: ModelProviderID(rawValue: "openai-api")))
        XCTAssertFalse(String(describing: error).contains(secret))
    }

    func testInsufficientQuotaIsNormalized() async throws {
        for code in ["insufficient_quota", "credit_balance_exhausted"] {
            let provider = OpenAIAPIProvider(
                credentials: StubOpenAIKeyStore(value: "sk-test"),
                transport: RecordingOpenAITransport(
                    terminalError: .httpStatus(statusCode: 429, code: code)
                )
            )

            let error = await captureProviderError(from: provider)

            XCTAssertEqual(error, .quotaExhausted(providerID: ModelProviderID(rawValue: "openai-api")))
        }
    }

    func testOtherRateLimitIsNormalized() async throws {
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: "sk-test"),
            transport: RecordingOpenAITransport(
                terminalError: .httpStatus(statusCode: 429, code: "rate_limit_exceeded")
            )
        )

        let error = await captureProviderError(from: provider)

        XCTAssertEqual(error, .rateLimited(providerID: ModelProviderID(rawValue: "openai-api")))
    }

    func testMalformedResponseIsNormalized() async throws {
        let provider = OpenAIAPIProvider(
            credentials: StubOpenAIKeyStore(value: "sk-test"),
            transport: RecordingOpenAITransport(terminalError: .malformedResponse)
        )

        let error = await captureProviderError(from: provider)

        XCTAssertEqual(error, .malformedOutput(providerID: ModelProviderID(rawValue: "openai-api")))
    }

    func testTransportRequestBodyMatchesResponsesAPIContractWithoutCredentialMaterial() throws {
        let request = OpenAITransportRequest(
            sessionID: ModelSessionID(rawValue: "transport-contract"),
            model: "gpt-5.6",
            input: [
                OpenAITransportInput(role: .system, content: "system guidance"),
                OpenAITransportInput(role: .user, content: "hello")
            ],
            tools: [
                OpenAITransportTool(
                    name: "web_search",
                    description: "Search the web",
                    parametersJSON: Data(
                        #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#.utf8
                    )
                )
            ],
            responseMode: .text
        )

        let body = try OpenAITransport.requestBody(for: request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first)

        XCTAssertEqual(object["model"] as? String, "gpt-5.6")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(input.compactMap { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, "web_search")
        XCTAssertNotNil(tool["parameters"] as? [String: Any])
        let rendered = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(rendered.lowercased().contains("authorization"))
        XCTAssertFalse(rendered.contains("sk-test"))
    }

    func testResponsesSSEParserMapsSemanticEvents() throws {
        var parser = OpenAISSEParser()
        let lines = [
            #"data: {"type":"response.created"}"#,
            "",
            #"data: {"type":"response.output_text.delta","delta":"hello"}"#,
            "",
            #"data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item_1","name":"web_search"}}"#,
            "",
            #"data: {"type":"response.function_call_arguments.done","item_id":"item_1","arguments":"{\"query\":\"swift concurrency\"}"}"#,
            "",
            #"data: {"type":"response.completed"}"#,
            ""
        ]

        var events: [OpenAITransportEvent] = []
        for line in lines {
            events += try parser.consume(line: line)
        }
        events += try parser.finish()

        XCTAssertEqual(
            events,
            [
                .created,
                .textDelta("hello"),
                .functionCall(
                    name: "web_search",
                    argumentsJSON: Data(#"{"query":"swift concurrency"}"#.utf8)
                ),
                .completed
            ]
        )
    }

    private func captureProviderError(
        from provider: OpenAIAPIProvider
    ) async -> ProviderError? {
        do {
            for try await _ in provider.stream(.fixture()) {}
            XCTFail("Expected provider stream to fail")
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            XCTFail("Unexpected error: \(error)")
            return nil
        }
    }
}

nonisolated struct StubOpenAIKeyStore: OpenAIKeyStoring {
    private let state: StubOpenAIKeyStoreState

    init(value: String?) {
        state = StubOpenAIKeyStoreState(value: value)
    }

    func hasKey() async -> Bool {
        await state.value != nil
    }

    func withKey(
        _ operation: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        guard let value = await state.value else {
            throw OpenAIKeyStoreError.missingKey
        }
        try await operation(value)
    }

    func store(_ value: String) async throws {
        await state.set(value)
    }

    func remove() async throws {
        await state.set(nil)
    }
}

private actor BooleanTestState {
    private(set) var value = false

    func set(_ value: Bool) {
        self.value = value
    }
}

private actor StubOpenAIKeyStoreState {
    private(set) var value: String?

    init(value: String?) {
        self.value = value
    }

    func set(_ value: String?) {
        self.value = value
    }
}

nonisolated struct RecordingOpenAITransport: OpenAITransporting {
    let events: [OpenAITransportEvent]
    let terminalError: OpenAITransportError?
    private let state: RecordingOpenAITransportState

    init(
        events: [OpenAITransportEvent] = [.created, .completed],
        terminalError: OpenAITransportError? = nil
    ) {
        self.events = events
        self.terminalError = terminalError
        state = RecordingOpenAITransportState()
    }

    var requests: [OpenAITransportRequest] {
        get async { await state.requests }
    }

    func stream(
        _ request: OpenAITransportRequest,
        credentials: any OpenAIKeyStoring
    ) async -> AsyncThrowingStream<OpenAITransportEvent, Error> {
        await state.record(request)
        let events = self.events
        let terminalError = self.terminalError
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {}
}

private actor RecordingOpenAITransportState {
    private(set) var requests: [OpenAITransportRequest] = []

    func record(_ request: OpenAITransportRequest) {
        requests.append(request)
    }
}
