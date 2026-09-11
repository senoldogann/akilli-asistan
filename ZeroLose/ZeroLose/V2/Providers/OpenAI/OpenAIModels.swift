import Foundation

nonisolated enum OpenAIKeyStoreError: Error, Sendable, Equatable {
    case missingKey
    case invalidKey
    case keychainFailure(status: Int32)
}

nonisolated protocol OpenAIKeyStoring: Sendable {
    func hasKey() async -> Bool
    func withKey(
        _ operation: @escaping @Sendable (String) async throws -> Void
    ) async throws
    func store(_ value: String) async throws
    func remove() async throws
}

nonisolated struct OpenAITransportInput: Sendable, Equatable {
    let role: ModelRole
    let content: String
}

nonisolated struct OpenAITransportTool: Sendable, Equatable {
    let name: String
    let description: String
    let parametersJSON: Data
}

nonisolated struct OpenAITransportRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let model: String
    let input: [OpenAITransportInput]
    let tools: [OpenAITransportTool]
    let responseMode: ResponseMode
}

nonisolated enum OpenAITransportEvent: Sendable, Equatable {
    case created
    case textDelta(String)
    case functionCall(name: String, argumentsJSON: Data)
    case completed
}

nonisolated enum OpenAITransportError: Error, Sendable, Equatable {
    case httpStatus(statusCode: Int, code: String?)
    case apiError(code: String?)
    case malformedResponse
    case transportFailure
    case cancelled
}

nonisolated protocol OpenAITransporting: Sendable {
    func stream(
        _ request: OpenAITransportRequest,
        credentials: any OpenAIKeyStoring
    ) async -> AsyncThrowingStream<OpenAITransportEvent, Error>
    func cancel(sessionID: ModelSessionID) async
}
