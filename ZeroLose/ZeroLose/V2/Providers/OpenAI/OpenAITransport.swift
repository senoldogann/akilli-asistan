import Foundation

actor OpenAITransport: OpenAITransporting {
    private let endpoint: URL
    private var sessions: [ModelSessionID: Task<Void, Never>] = [:]

    init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.endpoint = endpoint
    }

    func stream(
        _ request: OpenAITransportRequest,
        credentials: any OpenAIKeyStoring
    ) async -> AsyncThrowingStream<OpenAITransportEvent, Error> {
        sessions[request.sessionID]?.cancel()

        let pair = AsyncThrowingStream<OpenAITransportEvent, Error>.makeStream()
        let endpoint = self.endpoint
        let sessionID = request.sessionID
        let task = Task {
            do {
                try await credentials.withKey { key in
                    try await Self.performStreamingRequest(
                        request,
                        endpoint: endpoint,
                        key: key,
                        continuation: pair.continuation
                    )
                }
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish(throwing: OpenAITransportError.cancelled)
            } catch let error as OpenAITransportError {
                pair.continuation.finish(throwing: error)
            } catch let error as OpenAIKeyStoreError {
                pair.continuation.finish(throwing: error)
            } catch {
                pair.continuation.finish(throwing: OpenAITransportError.transportFailure)
            }
            sessionDidFinish(sessionID)
        }

        sessions[sessionID] = task
        pair.continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return pair.stream
    }

    func cancel(sessionID: ModelSessionID) async {
        sessions.removeValue(forKey: sessionID)?.cancel()
    }

    private func sessionDidFinish(_ sessionID: ModelSessionID) {
        sessions.removeValue(forKey: sessionID)
    }

    private nonisolated static func performStreamingRequest(
        _ request: OpenAITransportRequest,
        endpoint: URL,
        key: String,
        continuation: AsyncThrowingStream<OpenAITransportEvent, Error>.Continuation
    ) async throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIKeyStoreError.invalidKey
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try requestBody(for: request)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch is CancellationError {
            throw OpenAITransportError.cancelled
        } catch {
            throw OpenAITransportError.transportFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITransportError.malformedResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = try await collect(bytes)
            throw OpenAITransportError.httpStatus(
                statusCode: httpResponse.statusCode,
                code: errorCode(from: data)
            )
        }

        var parser = OpenAISSEParser()
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                for event in try parser.consume(line: line) {
                    continuation.yield(event)
                }
            }
            for event in try parser.finish() {
                continuation.yield(event)
            }
        } catch is CancellationError {
            throw OpenAITransportError.cancelled
        } catch let error as OpenAITransportError {
            throw error
        } catch {
            throw OpenAITransportError.transportFailure
        }
    }

    nonisolated static func requestBody(
        for request: OpenAITransportRequest
    ) throws -> Data {
        let input: [[String: Any]] = request.input.map {
            [
                "role": $0.role.rawValue,
                "content": $0.content
            ]
        }

        var tools: [[String: Any]] = []
        tools.reserveCapacity(request.tools.count)
        for tool in request.tools {
            let parameters = try JSONSerialization.jsonObject(with: tool.parametersJSON)
            guard parameters is [String: Any] else {
                throw OpenAITransportError.malformedResponse
            }
            tools.append([
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters
            ])
        }

        var payload: [String: Any] = [
            "model": request.model,
            "input": input,
            "stream": true
        ]
        if !tools.isEmpty {
            payload["tools"] = tools
        }
        if request.responseMode == .json {
            payload["text"] = [
                "format": ["type": "json_object"]
            ]
        }

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw OpenAITransportError.malformedResponse
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private nonisolated static func collect(
        _ bytes: URLSession.AsyncBytes
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private nonisolated static func errorCode(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return nil
        }
        return error["code"] as? String
    }
}

nonisolated struct OpenAISSEParser {
    private var dataLines: [String] = []
    private var functionNamesByItemID: [String: String] = [:]
    private var emittedFunctionItemIDs: Set<String> = []

    mutating func consume(line: String) throws -> [OpenAITransportEvent] {
        if line.isEmpty {
            return try drainEvent()
        }
        guard line.hasPrefix("data:") else {
            return []
        }
        var value = String(line.dropFirst(5))
        if value.first == " " {
            value.removeFirst()
        }
        dataLines.append(value)
        return []
    }

    mutating func finish() throws -> [OpenAITransportEvent] {
        try drainEvent()
    }

    private mutating func drainEvent() throws -> [OpenAITransportEvent] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)

        if payload == "[DONE]" {
            return []
        }
        guard
            let data = payload.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            throw OpenAITransportError.malformedResponse
        }

        switch type {
        case "response.created":
            return [.created]

        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else {
                throw OpenAITransportError.malformedResponse
            }
            return delta.isEmpty ? [] : [.textDelta(delta)]

        case "response.output_item.added":
            guard
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "function_call",
                let itemID = item["id"] as? String,
                let name = item["name"] as? String
            else {
                return []
            }
            functionNamesByItemID[itemID] = name
            return []

        case "response.function_call_arguments.done":
            guard
                let itemID = object["item_id"] as? String,
                let arguments = object["arguments"] as? String,
                let argumentsJSON = arguments.data(using: .utf8)
            else {
                throw OpenAITransportError.malformedResponse
            }
            let name = (object["name"] as? String) ?? functionNamesByItemID[itemID]
            guard let name else {
                throw OpenAITransportError.malformedResponse
            }
            emittedFunctionItemIDs.insert(itemID)
            return [.functionCall(name: name, argumentsJSON: argumentsJSON)]

        case "response.output_item.done":
            guard
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "function_call",
                let itemID = item["id"] as? String,
                !emittedFunctionItemIDs.contains(itemID)
            else {
                return []
            }
            guard
                let name = item["name"] as? String,
                let arguments = item["arguments"] as? String,
                let argumentsJSON = arguments.data(using: .utf8)
            else {
                throw OpenAITransportError.malformedResponse
            }
            emittedFunctionItemIDs.insert(itemID)
            return [.functionCall(name: name, argumentsJSON: argumentsJSON)]

        case "response.completed":
            return [.completed]

        case "error":
            let nested = object["error"] as? [String: Any]
            throw OpenAITransportError.apiError(
                code: (object["code"] as? String) ?? (nested?["code"] as? String)
            )

        default:
            return []
        }
    }
}
