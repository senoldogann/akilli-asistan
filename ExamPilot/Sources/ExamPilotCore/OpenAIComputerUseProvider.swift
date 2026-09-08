import Foundation

public enum ComputerAgentProviderError: Error, LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case missingResponseID
    case missingOutput
    case malformedComputerCall
    case unknownAction(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The Responses API returned an invalid response."
        case .httpStatus(let status):
            return "The Responses API returned HTTP \(status)."
        case .missingResponseID:
            return "The Responses API response did not contain an id."
        case .missingOutput:
            return "The Responses API response did not contain a computer call or output text."
        case .malformedComputerCall:
            return "The Responses API returned a malformed computer call."
        case .unknownAction(let action):
            return "The Responses API returned an unsupported computer action: \(action)."
        }
    }
}

public final class OpenAIComputerUseProvider: ComputerAgentProvider {
    private let apiKey: String
    private let model: String
    private let transport: HTTPTransport
    private let endpoint: URL

    public init(
        apiKey: String,
        model: String = "gpt-5.6-sol",
        transport: HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.endpoint = URL(string: "https://api.openai.com/v1/responses")!
    }

    public func nextStep(
        frame: ScreenFrame,
        state: ComputerAgentProviderState
    ) async throws -> ComputerAgentProviderTurn {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(frame: frame, state: state)
        )

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ComputerAgentProviderError.httpStatus(response.statusCode)
        }
        return try Self.decodeTurn(from: data)
    }

    private func requestBody(
        frame: ScreenFrame,
        state: ComputerAgentProviderState
    ) -> [String: Any] {
        let imageURL = "data:image/jpeg;base64,\(frame.jpegData.base64EncodedString())"
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "tools": [["type": "computer"]],
        ]

        if let previousResponseID = state.previousResponseID,
           let pendingComputerCallID = state.pendingComputerCallID {
            body["previous_response_id"] = previousResponseID
            body["input"] = [[
                "type": "computer_call_output",
                "call_id": pendingComputerCallID,
                "output": [
                    "type": "computer_screenshot",
                    "image_url": imageURL,
                    "detail": "original",
                ],
            ]]
            return body
        }

        body["input"] = [[
            "role": "user",
            "content": [
                [
                    "type": "input_text",
                    "text": initialPrompt(state: state),
                ],
                [
                    "type": "input_image",
                    "image_url": imageURL,
                    "detail": "original",
                ],
            ],
        ]]
        return body
    }

    private func initialPrompt(state: ComputerAgentProviderState) -> String {
        let memory = state.workingMemory
        let failures = memory.failures.map(\.reason.rawValue).joined(separator: ",")
        let evidence = memory.evidence.map(\.outcome.rawValue).joined(separator: ",")
        return """
        Operate only within the user's authorized computer-use task. Propose computer actions from the visible screenshot. Do not assume hidden DOM state. The host runtime remains authoritative for safety, focus, stale-state rejection, semantic verification, and protected navigation.

        Goal: \(state.goal)
        Runtime: session_id=\(state.sessionID), state_version=\(state.stateVersion), question_generation=\(state.questionGeneration), answer_verified=\(state.answerVerified), ui_phase=\(state.uiPhase.rawValue).
        Bounded memory: recent_failures=[\(failures)], verified_evidence=[\(evidence)].
        """
    }

    public static func decodeTurn(from data: Data) throws -> ComputerAgentProviderTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComputerAgentProviderError.invalidResponse
        }
        guard let responseID = root["id"] as? String, !responseID.isEmpty else {
            throw ComputerAgentProviderError.missingResponseID
        }
        guard let output = root["output"] as? [[String: Any]] else {
            throw ComputerAgentProviderError.missingOutput
        }

        for item in output where item["type"] as? String == "computer_call" {
            guard let callID = item["call_id"] as? String, !callID.isEmpty,
                  let rawActions = item["actions"] as? [[String: Any]] else {
                throw ComputerAgentProviderError.malformedComputerCall
            }
            guard rawActions.isEmpty else {
                throw ComputerAgentProviderError.malformedComputerCall
            }
            return ComputerAgentProviderTurn(
                responseID: responseID,
                computerCallID: callID,
                actions: [],
                finalText: nil
            )
        }

        for item in output where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String {
                    return ComputerAgentProviderTurn(
                        responseID: responseID,
                        computerCallID: nil,
                        actions: [],
                        finalText: text
                    )
                }
            }
        }

        throw ComputerAgentProviderError.missingOutput
    }
}
