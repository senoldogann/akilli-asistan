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
    // Shared model catalog cache so the input picker and the settings editor
    // agree on the live provider model lists (populated by fetchAvailableModels).
    nonisolated(unsafe) private static var modelCache: [String: [String]] = [:]

    nonisolated static func cachedModels(for provider: String) -> [String] {
        let key = provider.lowercased()
        return modelCache[key] ?? []
    }

    nonisolated private static func storeModels(_ models: [String], for provider: String) {
        modelCache[provider.lowercased()] = models
    }

    private enum Provider {
        case openAI
        case deepSeek
        case openCodeZen
        case openCodeGo
        case ollamaCloud
    }

    // Ollama Cloud now uses an OpenAI-compatible endpoint — /api/chat is 410 Gone.
    private let ollamaCloudBaseURL = URL(string: "https://ollama.com/v1")!
    private let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    private let deepSeekBaseURL = URL(string: "https://api.deepseek.com/v1")!
    private let openCodeZenBaseURL = URL(string: "https://opencode.ai/zen/v1")!
    private let openCodeGoBaseURL = URL(string: "https://opencode.ai/zen/go/v1")!
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
        let tools: [AgentFunctionTool]?
        let thinking: ThinkingParam?
        let reasoning_effort: String?

        init(
            model: String,
            messages: [OpenAIChatMessage],
            stream: Bool,
            tools: [AgentFunctionTool]? = nil,
            thinking: ThinkingParam? = nil,
            reasoning_effort: String? = nil
        ) {
            self.model = model
            self.messages = messages
            self.stream = stream
            self.tools = tools
            self.thinking = thinking
            self.reasoning_effort = reasoning_effort
        }

        // Omit nil optional fields so OpenAI/DeepSeek do not receive null params.
        private enum CodingKeys: String, CodingKey {
            case model, messages, stream, tools, thinking, reasoning_effort
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(stream, forKey: .stream)
            try container.encodeIfPresent(tools, forKey: .tools)
            try container.encodeIfPresent(thinking, forKey: .thinking)
            try container.encodeIfPresent(reasoning_effort, forKey: .reasoning_effort)
        }
    }

    private struct ThinkingParam: Encodable, Sendable {
        let type: String
    }

    private struct OpenAIReasoning: Encodable, Sendable {
        let effort: String
    }

    nonisolated private static func selectedReasoningEffort(for provider: LLMProvider, model: String) -> String? {
        let options = AIModelNames.reasoningEffortOptions(for: provider, model: model)
        guard !options.isEmpty else { return nil }
        let stored = UserDefaults.standard.string(forKey: AIModelNames.reasoningEffortStorageKey(for: provider)) ?? ""
        return options.contains(stored) ? stored : AIModelNames.defaultReasoningEffort(for: provider, model: model)
    }

    private struct OpenAIChatMessage: Encodable, Sendable {
        let role: String
        let content: [OpenAIContentPart]?
        let toolCalls: [ToolCallPayload]?
        let toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        init(
            role: String,
            content: [OpenAIContentPart]?,
            toolCalls: [ToolCallPayload]? = nil,
            toolCallID: String? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        }
    }

    /// Assistant tool_calls payload sent back to the API in the next round.
    private struct ToolCallPayload: Encodable, Sendable {
        let id: String
        let type: String
        let function: Function

        struct Function: Encodable, Sendable {
            let name: String
            let arguments: String
        }
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
            let reasoning_content: String?
            let tool_calls: [ToolCall]?

            struct ToolCall: Decodable, Sendable {
                let id: String?
                let function: Function

                struct Function: Decodable, Sendable {
                    let name: String
                    let arguments: String
                }
            }
        }
    }

    private struct OpenAIResponseRequest: Encodable, Sendable {
        let model: String
        let input: [OpenAIResponseInputMessage]
        let stream: Bool
        let store: Bool
        let reasoning: OpenAIReasoning?
        let tools: [AgentFunctionTool]?
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
            let reasoning_content: String?
            let tool_calls: [ToolCallDelta]?

            struct ToolCallDelta: Decodable, Sendable {
                let index: Int?
                let id: String?
                let function: FunctionDelta?

                struct FunctionDelta: Decodable, Sendable {
                    let name: String?
                    let arguments: String?
                }
            }
            // OpenCode / Kimi models stream the trace under `reasoning`.
            let reasoning: String?

            var thinking: String? {
                if let rc = reasoning_content, !rc.isEmpty { return rc }
                if let r = reasoning, !r.isEmpty { return r }
                return nil
            }
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

    func generate(
        messages: [ChatMessage],
        model: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws -> String {
        let selectedModel = resolvedModel(from: messages, explicitModel: model)
        let selectedEffort = Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: selectedModel)
        let provider = provider(for: selectedModel)
        logger.info("Sending request... Provider: \(self.providerLabel(provider), privacy: .public) Model: \(selectedModel, privacy: .public) (Messages: \(messages.count))")

        return try await withRetry {
            switch provider {
            case .openAI:
                return try await self.generateOpenAI(messages: messages, model: selectedModel, reasoningEffort: selectedEffort, enableNativeTools: enableNativeTools, toolExecutor: toolExecutor)
            case .deepSeek:
                return try await self.generateDeepSeek(messages: messages, model: selectedModel, reasoningEffort: selectedEffort, enableNativeTools: enableNativeTools, toolExecutor: toolExecutor)
            case .openCodeZen:
                return try await self.generateOpenCodeZen(messages: messages, model: selectedModel, reasoningEffort: selectedEffort, enableNativeTools: enableNativeTools, toolExecutor: toolExecutor)
            case .openCodeGo:
                return try await self.generateOpenCodeGo(messages: messages, model: selectedModel, reasoningEffort: selectedEffort, enableNativeTools: enableNativeTools, toolExecutor: toolExecutor)
            case .ollamaCloud:
                return try await self.generateOllama(messages: messages, model: selectedModel)
            }
        }
    }

    func generateStreaming(
        messages: [ChatMessage],
        model: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil
    ) async throws {
        let selectedModel = resolvedModel(from: messages, explicitModel: model)
        let provider = provider(for: selectedModel)
        logger.info("Sending STREAMING request... Provider: \(self.providerLabel(provider), privacy: .public) Model: \(selectedModel, privacy: .public) (Messages: \(messages.count))")

        switch provider {
        case .openAI:
            try await generateStreamingOpenAI(
                messages: messages,
                model: selectedModel,
                onPartialResponse: onPartialResponse,
                onPartialThinking: onPartialThinking,
                enableNativeTools: enableNativeTools,
                toolExecutor: toolExecutor
            )
        case .deepSeek:
            try await generateStreamingDeepSeek(
                messages: messages,
                model: selectedModel,
                onPartialResponse: onPartialResponse,
                onPartialThinking: onPartialThinking,
                enableNativeTools: enableNativeTools,
                toolExecutor: toolExecutor
            )
        case .openCodeZen:
            try await generateStreamingOpenCodeZen(
                messages: messages,
                model: selectedModel,
                onPartialResponse: onPartialResponse,
                onPartialThinking: onPartialThinking,
                enableNativeTools: enableNativeTools,
                toolExecutor: toolExecutor
            )
        case .openCodeGo:
            try await generateStreamingOpenCodeGo(
                messages: messages,
                model: selectedModel,
                onPartialResponse: onPartialResponse,
                onPartialThinking: onPartialThinking,
                enableNativeTools: enableNativeTools,
                toolExecutor: toolExecutor
            )
        case .ollamaCloud:
            try await generateStreamingOllama(
                messages: messages,
                model: selectedModel,
                onPartialResponse: onPartialResponse,
                onPartialThinking: onPartialThinking
            )
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
        switch AIModelNames.currentProvider() {
        case .openAI:
            return .openAI
        case .deepSeek:
            return .deepSeek
        case .openCodeZen:
            // Respect the selected OpenCode Zen provider even for DeepSeek-named
            // models; OpenCode Zen hosts its own copy of these models.
            return Secrets.isOpenCodeZenKeyValid ? .openCodeZen : .ollamaCloud
        case .openCodeGo:
            return Secrets.isOpenCodeGoKeyValid ? .openCodeGo : .ollamaCloud
        case .ollama:
            return .ollamaCloud
        }
    }

    nonisolated static func shouldUseResponsesAPI(for model: String) -> Bool {
        model.lowercased().contains("codex")
    }

    private func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .openCodeZen: return "OpenCode Zen"
        case .openCodeGo: return "OpenCode Go"
        case .ollamaCloud: return "OllamaCloud"
        }
    }

    // MARK: - OpenAI chat completions

    private func generateOpenAI(
        messages: [ChatMessage],
        model: String,
        reasoningEffort: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws -> String {
        if Self.shouldUseResponsesAPI(for: model) {
            return try await generateOpenAIResponses(messages: messages, model: model, reasoningEffort: reasoningEffort)
        }

        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenAI API key is missing.")
        }
        let effort = reasoningEffort ?? Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model)

        if enableNativeTools, let toolExecutor {
            do {
                return try await generateWithNativeToolLoop(
                    model: model,
                    messages: messages,
                    reasoningEffort: effort,
                    thinking: nil,
                    executor: toolExecutor,
                    send: { payload in
                        try await self.sendOpenAICompatibleRound(
                            baseURL: self.openAIBaseURL,
                            apiKey: apiKey,
                            label: "OpenAI",
                            payload: payload
                        )
                    }
                )
            } catch OllamaError.serverError(let message) {
                logger.warning("OpenAI native tool loop failed; falling back to single-shot: \(message, privacy: .public)")
            }
        }

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: false,
            reasoning_effort: effort
        )
        let result = try await sendOpenAICompatibleRound(baseURL: openAIBaseURL, apiKey: apiKey, label: "OpenAI", payload: payload)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw OllamaError.noData
        }
        return content
    }

    private func generateStreamingOpenAI(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws {
        if Self.shouldUseResponsesAPI(for: model) {
            try await generateStreamingOpenAIResponses(messages: messages, model: model, onPartialResponse: onPartialResponse)
            return
        }

        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenAI API key is missing.")
        }
        let effort = Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model)

        if enableNativeTools, let toolExecutor {
            do {
                try await generateStreamingWithNativeToolLoop(
                    model: model,
                    messages: messages,
                    reasoningEffort: effort,
                    thinking: nil,
                    executor: toolExecutor,
                    onPartialThinking: onPartialThinking,
                    stream: { payload in
                        try await self.streamOpenAICompatibleRound(
                            baseURL: self.openAIBaseURL,
                            apiKey: apiKey,
                            label: "OpenAI",
                            payload: payload,
                            onPartialResponse: onPartialResponse,
                            onPartialThinking: onPartialThinking
                        )
                    }
                )
                return
            } catch OllamaError.serverError(let message) {
                logger.warning("OpenAI native tool streaming failed; falling back to legacy: \(message, privacy: .public)")
            }
        }

        _ = try await streamOpenAICompatibleRound(
            baseURL: openAIBaseURL,
            apiKey: apiKey,
            label: "OpenAI",
            payload: OpenAIChatCompletionRequest(
                model: model,
                messages: messages.map(Self.toOpenAIMessage),
                stream: true,
                reasoning_effort: effort
            ),
            onPartialResponse: onPartialResponse,
            onPartialThinking: onPartialThinking
        )
    }

    private func generateOpenAIResponses(messages: [ChatMessage], model: String, reasoningEffort: String? = nil) async throws -> String {
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
            store: false,
            reasoning: reasoningEffort.map { OpenAIReasoning(effort: $0) },
            tools: nil
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
            store: false,
            reasoning: Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model).map { OpenAIReasoning(effort: $0) },
            tools: nil
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

    /// DeepSeek V4 exposes thinking traces via `delta.reasoning_content` before
    /// the final answer (`delta.content`). Both are consumed as separate buffers
    /// so the UI can render a collapsible thinking panel per model.
    private func generateStreamingDeepSeek(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws {
        let apiKey = Secrets.deepSeekApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("DeepSeek API key is missing.")
        }
        let effort = Self.selectedReasoningEffort(for: .deepSeek, model: model) ?? "high"

        if enableNativeTools, let toolExecutor {
            do {
                try await generateStreamingWithNativeToolLoop(
                    model: model,
                    messages: messages,
                    reasoningEffort: effort,
                    thinking: ThinkingParam(type: "enabled"),
                    executor: toolExecutor,
                    onPartialThinking: onPartialThinking,
                    stream: { payload in
                        try await self.streamOpenAICompatibleRound(
                            baseURL: self.deepSeekBaseURL,
                            apiKey: apiKey,
                            label: "DeepSeek",
                            payload: payload,
                            onPartialResponse: onPartialResponse,
                            onPartialThinking: onPartialThinking
                        )
                    }
                )
                return
            } catch OllamaError.serverError(let message) {
                logger.warning("DeepSeek native tool streaming failed; falling back to legacy: \(message, privacy: .public)")
            }
        }

        _ = try await streamOpenAICompatibleRound(
            baseURL: deepSeekBaseURL,
            apiKey: apiKey,
            label: "DeepSeek",
            payload: OpenAIChatCompletionRequest(
                model: model,
                messages: messages.map(Self.toOpenAIMessage),
                stream: true,
                thinking: ThinkingParam(type: "enabled"),
                reasoning_effort: effort
            ),
            onPartialResponse: onPartialResponse,
            onPartialThinking: onPartialThinking
        )
    }

    private func generateDeepSeek(
        messages: [ChatMessage],
        model: String,
        reasoningEffort: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws -> String {
        let apiKey = Secrets.deepSeekApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("DeepSeek API key is missing.")
        }
        let effort = reasoningEffort ?? Self.selectedReasoningEffort(for: .deepSeek, model: model) ?? "high"

        if enableNativeTools, let toolExecutor {
            do {
                return try await generateWithNativeToolLoop(
                    model: model,
                    messages: messages,
                    reasoningEffort: effort,
                    thinking: ThinkingParam(type: "enabled"),
                    executor: toolExecutor,
                    send: { payload in
                        try await self.sendOpenAICompatibleRound(
                            baseURL: self.deepSeekBaseURL,
                            apiKey: apiKey,
                            label: "DeepSeek",
                            payload: payload
                        )
                    }
                )
            } catch OllamaError.serverError(let message) {
                logger.warning("DeepSeek native tool loop failed; falling back to single-shot: \(message, privacy: .public)")
            }
        }

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: false,
            thinking: ThinkingParam(type: "enabled"),
            reasoning_effort: effort
        )
        let result = try await sendOpenAICompatibleRound(baseURL: deepSeekBaseURL, apiKey: apiKey, label: "DeepSeek", payload: payload)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw OllamaError.noData
        }
        return content
    }

    // MARK: - OpenCode Zen / Go (OpenAI-compatible)

    private func generateOpenCodeZen(
        messages: [ChatMessage],
        model: String,
        reasoningEffort: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws -> String {
        let apiKey = Secrets.openCodeZenApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenCode Zen API key is missing. Generate one at https://opencode.ai/auth")
        }
        return try await generateOpenAICompatible(
            messages: messages,
            model: model,
            baseURL: openCodeZenBaseURL,
            apiKey: apiKey,
            label: "OpenCode Zen",
            reasoningEffort: reasoningEffort,
            enableNativeTools: enableNativeTools,
            toolExecutor: toolExecutor
        )
    }

    private func generateOpenCodeGo(
        messages: [ChatMessage],
        model: String,
        reasoningEffort: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws -> String {
        let apiKey = Secrets.openCodeGoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenCode Go API key is missing. Generate one at https://opencode.ai/auth")
        }
        return try await generateOpenAICompatible(
            messages: messages,
            model: model,
            baseURL: openCodeGoBaseURL,
            apiKey: apiKey,
            label: "OpenCode Go",
            reasoningEffort: reasoningEffort,
            enableNativeTools: enableNativeTools,
            toolExecutor: toolExecutor
        )
    }

    private func generateStreamingOpenCodeZen(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws {
        let apiKey = Secrets.openCodeZenApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenCode Zen API key is missing. Generate one at https://opencode.ai/auth")
        }
        try await generateStreamingOpenAICompatible(
            messages: messages,
            model: model,
            baseURL: openCodeZenBaseURL,
            apiKey: apiKey,
            label: "OpenCode Zen",
            onPartialResponse: onPartialResponse,
            onPartialThinking: onPartialThinking,
            enableNativeTools: enableNativeTools,
            toolExecutor: toolExecutor
        )
    }

    private func generateStreamingOpenCodeGo(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws {
        let apiKey = Secrets.openCodeGoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("OpenCode Go API key is missing. Generate one at https://opencode.ai/auth")
        }
        try await generateStreamingOpenAICompatible(
            messages: messages,
            model: model,
            baseURL: openCodeGoBaseURL,
            apiKey: apiKey,
            label: "OpenCode Go",
            onPartialResponse: onPartialResponse,
            onPartialThinking: onPartialThinking,
            enableNativeTools: enableNativeTools,
            toolExecutor: toolExecutor
        )
    }

    /// Shared OpenAI-compatible chat-completions request used by OpenCode Zen / Go.
    private func generateOpenAICompatible(
        messages: [ChatMessage],
        model: String,
        baseURL: URL,
        apiKey: String,
        label: String,
        reasoningEffort: String? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws -> String {
        let effort = reasoningEffort ?? Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model)

        if enableNativeTools, let toolExecutor {
            do {
                return try await generateWithNativeToolLoop(
                    model: model,
                    messages: messages,
                    reasoningEffort: effort,
                    thinking: nil,
                    executor: toolExecutor,
                    send: { payload in
                        try await self.sendOpenAICompatibleRound(
                            baseURL: baseURL,
                            apiKey: apiKey,
                            label: label,
                            payload: payload
                        )
                    }
                )
            } catch OllamaError.serverError(let message) {
                logger.warning("\(label) native tool loop failed; falling back to single-shot: \(message, privacy: .public)")
            }
        }

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: false,
            reasoning_effort: effort
        )
        let result = try await sendOpenAICompatibleRound(baseURL: baseURL, apiKey: apiKey, label: label, payload: payload)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw OllamaError.noData
        }
        return content
    }

    private func generateStreamingOpenAICompatible(
        messages: [ChatMessage],
        model: String,
        baseURL: URL,
        apiKey: String,
        label: String,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil,
        enableNativeTools: Bool = false,
        toolExecutor: AgentToolExecutor? = nil
    ) async throws {
        let effort = Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model)

        if enableNativeTools, let toolExecutor {
            do {
                try await generateStreamingWithNativeToolLoop(
                    model: model,
                    messages: messages,
                    reasoningEffort: effort,
                    thinking: nil,
                    executor: toolExecutor,
                    onPartialThinking: onPartialThinking,
                    stream: { payload in
                        try await self.streamOpenAICompatibleRound(
                            baseURL: baseURL,
                            apiKey: apiKey,
                            label: label,
                            payload: payload,
                            onPartialResponse: onPartialResponse,
                            onPartialThinking: onPartialThinking
                        )
                    }
                )
                return
            } catch OllamaError.serverError(let message) {
                logger.warning("\(label) native tool streaming failed; falling back to legacy: \(message, privacy: .public)")
            }
        }

        _ = try await streamOpenAICompatibleRound(
            baseURL: baseURL,
            apiKey: apiKey,
            label: label,
            payload: OpenAIChatCompletionRequest(
                model: model,
                messages: messages.map(Self.toOpenAIMessage),
                stream: true,
                reasoning_effort: effort
            ),
            onPartialResponse: onPartialResponse,
            onPartialThinking: onPartialThinking
        )
    }

    nonisolated static func decodeNativeToolCalls(from data: Data) -> [AgentToolCall] {
        guard let response = try? JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data),
              let calls = response.choices.first?.message.tool_calls else { return [] }
        return calls.map {
            AgentToolCall(
                id: $0.id ?? UUID().uuidString,
                name: $0.function.name,
                argumentsJSON: $0.function.arguments
            )
        }
    }

    nonisolated private static func mergeNativeToolCallDelta(
        _ delta: OpenAIStreamChunk.Delta.ToolCallDelta,
        into calls: inout [AgentToolCall]
    ) {
        let index = delta.index ?? calls.count
        while calls.count <= index {
            calls.append(AgentToolCall(name: "", argumentsJSON: ""))
        }
        let current = calls[index]
        let name = current.name.isEmpty ? (delta.function?.name ?? "") : current.name
        let arguments = current.argumentsJSON + (delta.function?.arguments ?? "")
        calls[index] = AgentToolCall(id: delta.id ?? current.id, name: name, argumentsJSON: arguments)
    }

    // MARK: - Native structured tool calling

    /// Maximum number of model↔tool rounds before giving up. Prevents runaway
    /// agent loops while still allowing multi-step tool chains.
    private static let maxNativeToolRounds = 4

    /// One non-streaming OpenAI-compatible round. Used both by the native tool
    /// loop and by the legacy single-shot path.
    private func sendOpenAICompatibleRound(
        baseURL: URL,
        apiKey: String,
        label: String,
        payload: OpenAIChatCompletionRequest
    ) async throws -> OpenAIChatCompletionResponse {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("\(label) Error: \(httpResponse.statusCode, privacy: .public) | Body: \(errorBody, privacy: .public)")
            throw OllamaError.serverError("\(label) API Error (\(httpResponse.statusCode)): \(errorBody)")
        }
        return try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
    }

    /// One streaming OpenAI-compatible round trip. Streams answer deltas to
    /// `onPartialResponse` and accumulates any native tool-call deltas.
    private func streamOpenAICompatibleRound(
        baseURL: URL,
        apiKey: String,
        label: String,
        payload: OpenAIChatCompletionRequest,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)?
    ) async throws -> (text: String, toolCalls: [AgentToolCall]) {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(payload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }
        if httpResponse.statusCode != 200 {
            let errorBody = try await Self.readAsyncErrorBody(from: asyncBytes)
            throw OllamaError.serverError("\(label) API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        var buffer = ""
        var toolCalls: [AgentToolCall] = []
        for try await rawLine in asyncBytes.lines {
            try Task.checkCancellation()
            guard rawLine.hasPrefix("data: ") else { continue }
            let payloadLine = String(rawLine.dropFirst(6))
            if payloadLine == "[DONE]" { break }

            do {
                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(payloadLine.utf8))
                if let thinking = chunk.choices.first?.delta.thinking, !thinking.isEmpty {
                    onPartialThinking?(thinking)
                }
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    buffer += content
                    onPartialResponse(buffer)
                }
                for delta in chunk.choices.first?.delta.tool_calls ?? [] {
                    Self.mergeNativeToolCallDelta(delta, into: &toolCalls)
                }
            } catch {
                logger.error("\(label) stream decode error: \(error.localizedDescription, privacy: .public)")
            }
        }
        let complete = toolCalls.filter { !$0.name.isEmpty && !$0.argumentsJSON.isEmpty }
        return (buffer, complete)
    }

    /// Bounded multi-round native tool loop (non-streaming). Executes tool
    /// calls through the executor, feeds results back as `tool` messages, and
    /// returns the final model answer.
    private func generateWithNativeToolLoop(
        model: String,
        messages: [ChatMessage],
        reasoningEffort: String?,
        thinking: ThinkingParam?,
        executor: AgentToolExecutor,
        send: (OpenAIChatCompletionRequest) async throws -> OpenAIChatCompletionResponse
    ) async throws -> String {
        var openAIMessages = messages.map(Self.toOpenAIMessage)
        for _ in 0..<Self.maxNativeToolRounds {
            let payload = OpenAIChatCompletionRequest(
                model: model,
                messages: openAIMessages,
                stream: false,
                tools: AgentCapabilityRegistry.structuredTools(),
                thinking: thinking,
                reasoning_effort: reasoningEffort
            )
            let result = try await send(payload)
            if let rawCalls = result.choices.first?.message.tool_calls, !rawCalls.isEmpty {
                let toolCalls = rawCalls.map {
                    AgentToolCall(id: $0.id ?? UUID().uuidString, name: $0.function.name, argumentsJSON: $0.function.arguments)
                }
                var toolOutputs: [(id: String, output: String)] = []
                for call in toolCalls {
                    let output = await executor(call)
                    toolOutputs.append((call.id, output))
                }
                openAIMessages.append(Self.assistantToolCallMessage(from: toolCalls))
                for (id, output) in toolOutputs {
                    openAIMessages.append(Self.toolResultMessage(callID: id, content: output))
                }
                continue
            }
            guard let content = result.choices.first?.message.content, !content.isEmpty else {
                throw OllamaError.noData
            }
            return content
        }
        throw OllamaError.serverError("Native tool loop exceeded \(Self.maxNativeToolRounds) rounds")
    }

    /// Bounded multi-round native tool loop (streaming). Each round streams
    /// deltas live; tool rounds execute through the executor and the final
    /// round streams the answer.
    private func generateStreamingWithNativeToolLoop(
        model: String,
        messages: [ChatMessage],
        reasoningEffort: String?,
        thinking: ThinkingParam?,
        executor: AgentToolExecutor,
        onPartialThinking: ((String) -> Void)?,
        stream: (OpenAIChatCompletionRequest) async throws -> (text: String, toolCalls: [AgentToolCall])
    ) async throws {
        var openAIMessages = messages.map(Self.toOpenAIMessage)
        for _ in 0..<Self.maxNativeToolRounds {
            let payload = OpenAIChatCompletionRequest(
                model: model,
                messages: openAIMessages,
                stream: true,
                tools: AgentCapabilityRegistry.structuredTools(),
                thinking: thinking,
                reasoning_effort: reasoningEffort
            )
            let (_, calls) = try await stream(payload)
            if calls.isEmpty { return }

            var toolOutputs: [(id: String, output: String)] = []
            for call in calls {
                let output = await executor(call)
                toolOutputs.append((call.id, output))
            }
            openAIMessages.append(Self.assistantToolCallMessage(from: calls))
            for (id, output) in toolOutputs {
                openAIMessages.append(Self.toolResultMessage(callID: id, content: output))
            }
        }
        throw OllamaError.serverError("Native tool loop exceeded \(Self.maxNativeToolRounds) rounds")
    }

    /// Assistant message carrying the tool_calls so the API can correlate them
    /// with the following `tool` result messages.
    private static func assistantToolCallMessage(from calls: [AgentToolCall]) -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: "assistant",
            content: nil,
            toolCalls: calls.map {
                ToolCallPayload(id: $0.id, type: "function", function: .init(name: $0.name, arguments: $0.argumentsJSON))
            }
        )
    }

    /// `tool` role result message paired to a specific tool call id.
    private static func toolResultMessage(callID: String, content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "tool", content: [.text(content)], toolCallID: callID)
    }

    private static func toOpenAIMessage(_ message: ChatMessage) -> OpenAIChatMessage {
        var content: [OpenAIContentPart] = [.text(message.content)]
        if let images = message.images {
            content.append(contentsOf: images.map(OpenAIContentPart.image(base64:)))
        }
        return OpenAIChatMessage(role: message.role, content: content)
    }

    private static func toOpenAIResponseMessage(_ message: ChatMessage) -> OpenAIResponseInputMessage {
        let isAssistant = message.role.lowercased() == "assistant"
        let type = isAssistant ? "output_text" : "input_text"
        
        var content: [OpenAIResponseInputContentPart] = [
            OpenAIResponseInputContentPart(type: type, text: message.content, imageURL: nil)
        ]
        
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

    // MARK: - Ollama Cloud (OpenAI-compatible)
    //
    // Ollama Cloud dropped the native /api/chat endpoint (HTTP 410).
    // It now exposes an OpenAI-compatible interface at /v1/chat/completions.
    // We reuse the existing OpenAI request/response structs to avoid duplication.

    private func generateOllama(messages: [ChatMessage], model: String) async throws -> String {
        let apiKey = Secrets.ollamaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("Ollama Cloud API key is missing. Generate one at https://ollama.com/settings/keys")
        }

        let url = ollamaCloudBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: false,
            reasoning_effort: Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("Ollama Cloud Error: \(httpResponse.statusCode, privacy: .public) | Body: \(errorBody, privacy: .public)")
            throw OllamaError.serverError("Ollama Cloud API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        do {
            let result = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
            if let toolCalls = result.choices.first?.message.tool_calls, !toolCalls.isEmpty {
                let encoded = toolCalls.compactMap { call -> String? in
                    guard let data = try? JSONSerialization.data(withJSONObject: [
                        "id": call.id ?? UUID().uuidString,
                        "name": call.function.name,
                        "arguments": call.function.arguments
                    ]) else { return nil }
                    return "[NATIVE_TOOL_CALL: \(String(data: data, encoding: .utf8) ?? "")]"
                }.joined(separator: "\n")
                return encoded
            }
            guard let content = result.choices.first?.message.content, !content.isEmpty else {
                throw OllamaError.noData
            }
            return content
        } catch {
            logger.error("Ollama Cloud decode error: \(error.localizedDescription, privacy: .public)")
            throw OllamaError.decodingError
        }
    }

    private func generateStreamingOllama(
        messages: [ChatMessage],
        model: String,
        onPartialResponse: @escaping (String) -> Void,
        onPartialThinking: ((String) -> Void)? = nil
    ) async throws {
        let apiKey = Secrets.ollamaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OllamaError.missingAPIKey("Ollama Cloud API key is missing. Generate one at https://ollama.com/settings/keys")
        }

        let url = ollamaCloudBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        let payload = OpenAIChatCompletionRequest(
            model: model,
            messages: messages.map(Self.toOpenAIMessage),
            stream: true,
            reasoning_effort: Self.selectedReasoningEffort(for: AIModelNames.currentProvider(), model: model)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = try await Self.readAsyncErrorBody(from: asyncBytes)
            throw OllamaError.serverError("Ollama Cloud API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Ollama Cloud streams SSE identical to OpenAI format: "data: {...}" lines
        var buffer = ""
        for try await rawLine in asyncBytes.lines {
            try Task.checkCancellation()

            guard rawLine.hasPrefix("data: ") else { continue }
            let payloadLine = String(rawLine.dropFirst(6))
            if payloadLine == "[DONE]" { break }

            do {
                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(payloadLine.utf8))
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    buffer += content
                    onPartialResponse(buffer)
                }
                if let thinking = chunk.choices.first?.delta.thinking, !thinking.isEmpty {
                    onPartialThinking?(thinking)
                }
            } catch {
                logger.error("Ollama Cloud stream decode error: \(error.localizedDescription, privacy: .public)")
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
    
    nonisolated func fetchAvailableModels(provider: String, apiKey: String) async -> [String] {
        let providerID = provider.lowercased()
        let baseURL: URL
        switch providerID {
        case "openai":
            baseURL = openAIBaseURL
        case "deepseek":
            baseURL = deepSeekBaseURL
        case "opencode_zen", "opencode":
            baseURL = openCodeZenBaseURL
        case "opencode_go":
            baseURL = openCodeGoBaseURL
        default:
            baseURL = ollamaCloudBaseURL
        }
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenCode is fronted by Cloudflare which returns HTTP 403 (error 1010)
        // for non-browser super thin clients. A real browser UA is required.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            
            // Try to decode OpenAI format
            struct ModelsResponse: Decodable {
                struct ModelItem: Decodable {
                    let id: String
                }
                let data: [ModelItem]
            }
            
            if let result = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
                let rawIDs = result.data.map { $0.id }
                let normalized = Self.normalizeModelIDs(rawIDs)
                Self.storeModels(normalized, for: providerID)
                return normalized
            }
            
            // Try to decode Ollama format
            struct TagsResponse: Decodable {
                struct TagItem: Decodable {
                    let name: String
                }
                let models: [TagItem]
            }
            if let tags = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                let normalized = Self.normalizeModelIDs(tags.models.map { $0.name })
                Self.storeModels(normalized, for: providerID)
                return normalized
            }
            
            let fallback = Self.openCodeCatalogFallback(for: providerID)
            Self.storeModels(fallback, for: providerID)
            return fallback
        } catch {
            // Network failure: still give the user a usable, curated catalog so
            // the model picker is never empty for OpenCode memberships.
            let fallback = Self.openCodeCatalogFallback(for: providerID)
            Self.storeModels(fallback, for: providerID)
            return fallback
        }
    }

    /// Some providers return `provider/model` prefixed IDs. Strip the prefix so
    /// the picker shows clean, directly-sendable model names.
    private nonisolated static func normalizeModelIDs(_ ids: [String]) -> [String] {
        let normalized = ids.map { id -> String in
            guard let slash = id.lastIndex(of: "/") else { return id }
            let providerPart = id[..<slash]
            // Only strip well-known provider prefixes; leave slashes in custom names.
            let known = ["opencode-go", "opencode-zen", "deepseek", "openai"]
            let isKnownPrefix = known.contains { providerPart == $0 || id.hasPrefix($0 + "/") }
            return isKnownPrefix ? String(id[id.index(after: slash)...]) : id
        }
        return Array(Set(normalized)).sorted()
    }

    private nonisolated static func openCodeCatalogFallback(for providerID: String) -> [String] {
        switch providerID {
        case "opencode_zen", "opencode":
            return AIModelNames.openCodeZenCatalog
        case "opencode_go":
            return AIModelNames.openCodeGoCatalog
        default:
            return []
        }
    }
}
