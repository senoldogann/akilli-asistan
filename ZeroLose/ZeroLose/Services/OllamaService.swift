import Foundation
import os

enum OllamaError: Error {
    case invalidURL
    case noData
    case decodingError
    case missingAPIKey(String)
    case serverError(String)
}

extension OllamaError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL."
        case .noData:
            return "No response data returned from the model."
        case .decodingError:
            return "Could not decode the model response."
        case .missingAPIKey(let message), .serverError(let message):
            return message
        }
    }
}

actor OllamaService {
    private enum Provider {
        case openAI
        case ollamaCloud
    }

    private let ollamaBaseURL = URL(string: "https://ollama.com/api")!
    private let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "LLMGateway")

    struct ChatMessage: Encodable, Sendable {
        let role: String
        let content: String
        let images: [String]?
    }

    private struct OllamaChatRequest: Encodable, Sendable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    private struct OllamaChatResponse: Decodable, Sendable {
        let model: String
        let message: ResponseMessage
        let done: Bool
    }

    private struct ResponseMessage: Decodable, Sendable {
        let role: String
        let content: String
    }

    private struct OpenAIChatCompletionRequest: Encodable, Sendable {
        let model: String
        let messages: [OpenAIChatMessage]
        let stream: Bool
    }

    private struct OpenAIChatMessage: Encodable, Sendable {
        let role: String
        let content: [OpenAIContentPart]
    }

    private struct OpenAIContentPart: Encodable, Sendable {
        let type: String
        let text: String?
        let imageURL: OpenAIImageURL?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        static func text(_ value: String) -> OpenAIContentPart {
            OpenAIContentPart(type: "text", text: value, imageURL: nil)
        }

        static func image(base64: String) -> OpenAIContentPart {
            OpenAIContentPart(
                type: "image_url",
                text: nil,
                imageURL: OpenAIImageURL(url: "data:image/jpeg;base64,\(base64)")
            )
        }
    }

    private struct OpenAIImageURL: Encodable, Sendable {
        let url: String
    }

    private struct OpenAIChatCompletionResponse: Decodable, Sendable {
        let choices: [Choice]

        struct Choice: Decodable, Sendable {
            let message: Message
        }

        struct Message: Decodable, Sendable {
            let content: String?
        }
    }

    private struct OpenAIResponseRequest: Encodable, Sendable {
        let model: String
        let input: [OpenAIResponseInputMessage]
        let stream: Bool
        let store: Bool
    }

    private struct OpenAIResponseInputMessage: Encodable, Sendable {
        let role: String
        let content: [OpenAIResponseInputContentPart]
    }

    private struct OpenAIResponseInputContentPart: Encodable, Sendable {
        let type: String
        let text: String?
        let imageURL: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        static func text(_ value: String) -> OpenAIResponseInputContentPart {
            OpenAIResponseInputContentPart(type: "input_text", text: value, imageURL: nil)
        }

        static func image(base64: String) -> OpenAIResponseInputContentPart {
            OpenAIResponseInputContentPart(
                type: "input_image",
                text: nil,
                imageURL: "data:image/jpeg;base64,\(base64)"
            )
        }
    }

    private struct OpenAIResponsesResponse: Decodable, Sendable {
        let output: [OutputItem]?

        struct OutputItem: Decodable, Sendable {
            let type: String?
            let role: String?
            let content: [ContentItem]?
        }

        struct ContentItem: Decodable, Sendable {
            let type: String?
            let text: String?
        }
    }

    private struct OpenAIStreamChunk: Decodable, Sendable {
        let choices: [Choice]

        struct Choice: Decodable, Sendable {
            let delta: Delta
        }

        struct Delta: Decodable, Sendable {
            let content: String?
        }
    }

    private struct OpenAIResponsesStreamEvent: Decodable, Sendable {
        let type: String
        let delta: String?
        let error: ResponseError?

        struct ResponseError: Decodable, Sendable {
            let message: String?
        }
    }

    func generate(messages: [ChatMessage], model: String? = nil) async throws -> String {
        let selectedModel = resolvedModel(from: messages, explicitModel: model)
        let provider = provider(for: selectedModel)
        logger.info("Sending request... Provider: \(self.providerLabel(provider), privacy: .public) Model: \(selectedModel, privacy: .public) (Messages: \(messages.count))")

        return try await withRetry {
            switch provider {
            case .openAI:
                return try await self.generateOpenAI(messages: messages, model: selectedModel)
            case .ollamaCloud:
                return try await self.generateOllama(messages: messages, model: selectedModel)
            }
        }
    }

    func generateStreaming(
        messages: [ChatMessage],
        model: String? = nil,
        onPartialResponse: @escaping (String) -> Void
    ) async throws {
        let selectedModel = resolvedModel(from: messages, explicitModel: model)
        let provider = provider(for: selectedModel)
        logger.info("Sending STREAMING request... Provider: \(self.providerLabel(provider), privacy: .public) Model: \(selectedModel, privacy: .public) (Messages: \(messages.count))")

        switch provider {
        case .openAI:
            try await generateStreamingOpenAI(messages: messages, model: selectedModel, onPartialResponse: onPartialResponse)
        case .ollamaCloud:
            try await generateStreamingOllama(messages: messages, model: selectedModel, onPartialResponse: onPartialResponse)
        }
    }

    // MARK: - Provider selection

    private func resolvedModel(from messages: [ChatMessage], explicitModel: String?) -> String {
        if let explicitModel, !explicitModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitModel
        }

        let hasImages = messages.contains { $0.images != nil && !($0.images?.isEmpty ?? true) }
        return hasImages ? AIModelNames.vision : AIModelNames.reasoning
    }

    private func provider(for model: String) -> Provider {
        let normalizedModel = model.lowercased()
        if normalizedModel.hasPrefix("gpt-") || normalizedModel.hasPrefix("o1") || normalizedModel.hasPrefix("o3") || normalizedModel.hasPrefix("o4") {
            return .openAI
        }
        return .ollamaCloud
    }

    nonisolated static func shouldUseResponsesAPI(for model: String) -> Bool {
        model.lowercased().contains("codex")
    }

    private func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .openAI: return "OpenAI"
        case .ollamaCloud: return "OllamaCloud"
        }
    }

    // MARK: - OpenAI chat completions

    private func generateOpenAI(messages: [ChatMessage], model: String) async throws -> String {
        if Self.shouldUseResponsesAPI(for: model) {
            return try await generateOpenAIResponses(messages: messages, model: model)
        }

        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenAI API key is missing.")
        }

        let url = openAIBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("OpenAI Error: \(httpResponse.statusCode, privacy: .public) | Body: \(errorBody, privacy: .public)")
            throw OllamaError.serverError("OpenAI API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        do {
            let result = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
            guard let content = result.choices.first?.message.content, !content.isEmpty else {
                throw OllamaError.noData
            }
            return content
        } catch {
            logger.error("OpenAI decode error: \(error.localizedDescription, privacy: .public)")
            throw OllamaError.decodingError
        }
    }

    private func generateStreamingOpenAI(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void
    ) async throws {
        if Self.shouldUseResponsesAPI(for: model) {
            try await generateStreamingOpenAIResponses(messages: messages, model: model, onPartialResponse: onPartialResponse)
            return
        }

        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenAI API key is missing.")
        }

        let url = openAIBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = try await Self.readAsyncErrorBody(from: asyncBytes)
            throw OllamaError.serverError("OpenAI API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        var buffer = ""
        for try await rawLine in asyncBytes.lines {
            try Task.checkCancellation()

            guard rawLine.hasPrefix("data: ") else { continue }
            let payloadLine = String(rawLine.dropFirst(6))
            if payloadLine == "[DONE]" {
                break
            }

            do {
                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(payloadLine.utf8))
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    buffer += content
                    onPartialResponse(buffer)
                }
            } catch {
                logger.error("OpenAI stream decode error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func generateOpenAIResponses(messages: [ChatMessage], model: String) async throws -> String {
        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenAI API key is missing.")
        }

        let url = openAIBaseURL.appendingPathComponent("responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OpenAIResponseRequest(
            model: model,
            input: messages.map(Self.toOpenAIResponseMessage),
            stream: false,
            store: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("OpenAI Responses Error: \(httpResponse.statusCode, privacy: .public) | Body: \(errorBody, privacy: .public)")
            throw OllamaError.serverError("OpenAI Responses API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        do {
            let result = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
            guard let content = Self.extractText(from: result), !content.isEmpty else {
                throw OllamaError.noData
            }
            return content
        } catch {
            logger.error("OpenAI responses decode error: \(error.localizedDescription, privacy: .public)")
            throw OllamaError.decodingError
        }
    }

    private func generateStreamingOpenAIResponses(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void
    ) async throws {
        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenAI API key is missing.")
        }

        let url = openAIBaseURL.appendingPathComponent("responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OpenAIResponseRequest(
            model: model,
            input: messages.map(Self.toOpenAIResponseMessage),
            stream: true,
            store: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = try await Self.readAsyncErrorBody(from: asyncBytes)
            logger.error("OpenAI Responses Stream Error: \(httpResponse.statusCode, privacy: .public) | Body: \(errorBody, privacy: .public)")
            throw OllamaError.serverError("OpenAI Responses API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        var buffer = ""
        for try await rawLine in asyncBytes.lines {
            try Task.checkCancellation()

            guard rawLine.hasPrefix("data: ") else { continue }
            let payloadLine = String(rawLine.dropFirst(6))
            if payloadLine == "[DONE]" {
                break
            }

            do {
                let event = try JSONDecoder().decode(OpenAIResponsesStreamEvent.self, from: Data(payloadLine.utf8))
                switch event.type {
                case "response.output_text.delta":
                    if let delta = event.delta, !delta.isEmpty {
                        buffer += delta
                        onPartialResponse(buffer)
                    }
                case "error":
                    let message = event.error?.message ?? "Unknown OpenAI streaming error"
                    throw OllamaError.serverError("OpenAI Responses stream error: \(message)")
                default:
                    continue
                }
            } catch let error as OllamaError {
                throw error
            } catch {
                logger.error("OpenAI responses stream decode error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func toOpenAIMessage(_ message: ChatMessage) -> OpenAIChatMessage {
        var content: [OpenAIContentPart] = [.text(message.content)]
        if let images = message.images {
            content.append(contentsOf: images.map(OpenAIContentPart.image(base64:)))
        }
        return OpenAIChatMessage(role: message.role, content: content)
    }

    private static func toOpenAIResponseMessage(_ message: ChatMessage) -> OpenAIResponseInputMessage {
        var content: [OpenAIResponseInputContentPart] = [.text(message.content)]
        if let images = message.images {
            content.append(contentsOf: images.map(OpenAIResponseInputContentPart.image(base64:)))
        }
        return OpenAIResponseInputMessage(role: message.role, content: content)
    }

    private static func extractText(from response: OpenAIResponsesResponse) -> String? {
        let fragments = (response.output ?? []).flatMap { item in
            (item.content ?? []).compactMap { content -> String? in
                guard content.type == "output_text" else { return nil }
                return content.text
            }
        }

        let combined = fragments.joined()
        return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : combined
    }

    private static func readAsyncErrorBody(from asyncBytes: URLSession.AsyncBytes) async throws -> String {
        var lines: [String] = []
        for try await line in asyncBytes.lines {
            if !line.isEmpty {
                lines.append(line)
            }
            if lines.count >= 24 {
                break
            }
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Unknown" : body
    }

    // MARK: - Legacy Ollama Cloud

    private func generateOllama(messages: [ChatMessage], model: String) async throws -> String {
        let apiKey = Secrets.ollamaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("Ollama Cloud API key is missing.")
        }

        let url = ollamaBaseURL.appendingPathComponent("chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OllamaChatRequest(model: model, messages: messages, stream: false)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("Ollama Cloud Error: \(httpResponse.statusCode, privacy: .public) | Body: \(errorBody, privacy: .public)")
            throw OllamaError.serverError("API Error: \(httpResponse.statusCode)")
        }

        do {
            let result = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return result.message.content
        } catch {
            logger.error("Ollama decode error: \(error.localizedDescription, privacy: .public)")
            throw OllamaError.decodingError
        }
    }

    private func generateStreamingOllama(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void
    ) async throws {
        let apiKey = Secrets.ollamaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("Ollama Cloud API key is missing.")
        }

        let url = ollamaBaseURL.appendingPathComponent("chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OllamaChatRequest(model: model, messages: messages, stream: true)
        request.httpBody = try JSONEncoder().encode(payload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            throw OllamaError.serverError("API Error: \(httpResponse.statusCode)")
        }

        var buffer = ""
        for try await line in asyncBytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty else { continue }

            do {
                let chunk = try JSONDecoder().decode(OllamaChatResponse.self, from: Data(line.utf8))
                let content = chunk.message.content
                buffer += content
                onPartialResponse(buffer)
            } catch {
                logger.error("Ollama stream decode error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Resilience

    private func withRetry<T>(
        maxAttempts: Int = 3,
        baseDelay: Double = 0.8,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = baseDelay * pow(2.0, Double(attempt - 1))
                    let jitter = Double.random(in: 0...(delay * 0.1))
                    logger.warning("Attempt \(attempt) failed, retrying in \(String(format: "%.2f", delay + jitter))s")
                    try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                }
            }
        }

        throw lastError ?? OllamaError.serverError("Max attempts reached")
    }
}
