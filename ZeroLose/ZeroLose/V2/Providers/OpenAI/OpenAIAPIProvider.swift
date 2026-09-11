import Foundation

nonisolated struct OpenAIAPIProvider: ModelProvider {
    let id = ModelProviderID(rawValue: "openai-api")
    let displayName = "OpenAI API"
    let capabilities: ModelCapabilities = [
        .textStreaming,
        .structuredTools,
        .jsonOutput
    ]

    private let credentials: any OpenAIKeyStoring
    private let transport: any OpenAITransporting

    init(
        credentials: any OpenAIKeyStoring,
        transport: any OpenAITransporting
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: await credentials.hasKey() ? .ready : .configurationRequired
        )
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        [
            ModelDescriptor(
                id: "gpt-5.6",
                displayName: "GPT-5.6",
                providerID: id,
                capabilities: capabilities
            )
        ]
    }

    func stream(
        _ request: ModelRequest
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let transportRequest = OpenAITransportRequest(
            sessionID: request.sessionID,
            model: request.modelID.isEmpty || request.modelID == "default" ? "gpt-5.6" : request.modelID,
            input: request.conversation.map {
                OpenAITransportInput(role: $0.role, content: $0.content)
            },
            tools: request.tools.map {
                OpenAITransportTool(
                    name: $0.name,
                    description: $0.description,
                    parametersJSON: $0.inputSchemaJSON
                )
            },
            responseMode: request.responseMode
        )

        return AsyncThrowingStream { continuation in
            Task {
                let stream = await transport.stream(
                    transportRequest,
                    credentials: credentials
                )
                do {
                    for try await event in stream {
                        switch event {
                        case .created:
                            continuation.yield(.started)
                        case .textDelta(let text):
                            continuation.yield(.textDelta(text))
                        case .functionCall(let name, let argumentsJSON):
                            continuation.yield(
                                .toolCall(name: name, argumentsJSON: argumentsJSON)
                            )
                        case .completed:
                            continuation.yield(.completed)
                        }
                    }
                    continuation.finish()
                } catch let error as OpenAITransportError {
                    continuation.finish(throwing: normalize(error))
                } catch let error as OpenAIKeyStoreError {
                    continuation.finish(throwing: normalize(error))
                } catch {
                    continuation.finish(
                        throwing: ProviderError.providerUnavailable(providerID: id)
                    )
                }
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        await transport.cancel(sessionID: sessionID)
    }

    private func normalize(_ error: OpenAITransportError) -> ProviderError {
        switch error {
        case .httpStatus(let statusCode, let code):
            if statusCode == 401 || code == "invalid_api_key" {
                return .invalidCredential(providerID: id)
            }
            if statusCode == 429 {
                return normalizeRateLimit(code: code)
            }
            return .providerUnavailable(providerID: id)

        case .apiError(let code):
            if code == "invalid_api_key" {
                return .invalidCredential(providerID: id)
            }
            if code == "insufficient_quota" || code == "credit_balance_exhausted" {
                return .quotaExhausted(providerID: id)
            }
            if code == "rate_limit_exceeded" {
                return .rateLimited(providerID: id)
            }
            return .providerUnavailable(providerID: id)

        case .malformedResponse:
            return .malformedOutput(providerID: id)
        case .transportFailure:
            return .providerUnavailable(providerID: id)
        case .cancelled:
            return .cancelled(providerID: id)
        }
    }

    private func normalize(_ error: OpenAIKeyStoreError) -> ProviderError {
        switch error {
        case .missingKey, .invalidKey:
            return .configurationRequired(providerID: id)
        case .keychainFailure:
            return .providerUnavailable(providerID: id)
        }
    }

    private func normalizeRateLimit(code: String?) -> ProviderError {
        if code == "insufficient_quota" || code == "credit_balance_exhausted" {
            return .quotaExhausted(providerID: id)
        }
        return .rateLimited(providerID: id)
    }
}
