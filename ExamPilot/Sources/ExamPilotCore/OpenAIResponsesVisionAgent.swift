import Foundation

public protocol HTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VisionAgentError.invalidResponse
        }
        return (data, http)
    }
}

public final class OpenAIResponsesVisionAgent: VisionAgent {
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

    public func decide(frame: ScreenFrame, state: ExamObservationState) async throws -> ExamDecision {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 3_000,
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": prompt(frame: frame, state: state),
                        ],
                        [
                            "type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(frame.jpegData.base64EncodedString())",
                            "detail": "high",
                        ],
                    ],
                ],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "exam_decision",
                    "strict": true,
                    "schema": Self.decisionSchema,
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw VisionAgentError.httpStatus(response.statusCode)
        }
        return try Self.decodeDecision(from: data)
    }

    public static func decodeDecision(from data: Data) throws -> ExamDecision {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw VisionAgentError.missingOutputText
        }

        var outputText: String?
        outer: for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String {
                    outputText = text
                    break outer
                }
            }
        }

        guard let outputText, let decisionData = outputText.data(using: .utf8) else {
            throw VisionAgentError.missingOutputText
        }
        guard let decision = try? JSONDecoder().decode(ExamDecision.self, from: decisionData) else {
            throw VisionAgentError.invalidDecision
        }
        return decision
    }

    private func prompt(frame: ScreenFrame, state: ExamObservationState) -> String {
        let last = state.lastSummary ?? "none"
        return """
        You are the visual planner for ExamPilot, a macOS computer-use agent operating only in an authorized quiz or exam environment owned or permitted by the user.

        Inspect ONLY the visible screenshot. Do not assume DOM access, browser extensions, clipboard access, JavaScript, hidden page state, or keyboard paste. Return JSON matching the supplied schema.

        Goal: understand the visible question or navigation state, solve it, then propose the largest SAFE batch of physical actions that can be executed from this single screenshot.

        Supported actions:
        - move_click: move the real cursor to a visible point and left-click it.
        - type_text: type text or code with real keyboard events.
        - key: press return, tab, escape, space, delete, arrows, home/end/pageup/pagedown.
        - scroll: vertical native scroll in pixels. Negative scrolls downward; positive scrolls upward.
        - wait: short UI settling delay.
        - finish: use only when the exam/session is visibly complete.

        Batching rules:
        1. You MAY return multiple actions when their targets all belong to the current visible UI state, for example selecting several checkboxes and then clicking Next.
        2. The first action that can materially replace/reflow the page or reveal a new state MUST have boundary=true. Typical boundaries: Next, Continue, Proceed, Seuraava, Jatka, İleri, Run, Test, Submit, Finish, pagination, opening a question, or any equivalent control in any language.
        3. Never plan actions after that first boundary. The runtime will re-screenshot after it.
        4. For a multi-select question, include all confidently correct visible selections before navigation.
        5. If an answer or navigation target is not visible, scroll by a moderate amount and make that the batch; re-observation will follow.
        6. If a code/text editor is visible, click/focus it first and then type the complete answer when it is safe to do so. Never request paste.
        7. Set expectsVisualChange=true whenever the executed batch should visibly alter selection, text, scroll position, test output, or navigation.
        8. Do not invent coordinates outside the captured Chrome window.

        Coordinate mapping:
        - Screenshot pixels: width=\(frame.pixelWidth), height=\(frame.pixelHeight).
        - Chrome window global macOS point bounds: x=\(frame.screenBounds.minX), y=\(frame.screenBounds.minY), width=\(frame.screenBounds.width), height=\(frame.screenBounds.height).
        - If a visual target is at screenshot pixel (px, py), convert to global point:
          x = bounds.x + (px / screenshotWidth) * bounds.width
          y = bounds.y + (py / screenshotHeight) * bounds.height

        Runtime state: cycle=\(state.cycle), consecutive_non_progress=\(state.nonProgressCount), previous_summary=\(last).

        Keep summary concise and action-oriented. Return JSON only through the structured output schema.
        """
    }

    private static let decisionSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "summary": ["type": "string"],
            "expectsVisualChange": ["type": "boolean"],
            "actions": [
                "type": "array",
                "maxItems": 12,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "kind": [
                            "type": "string",
                            "enum": ExamActionKind.allCases.map(\.rawValue),
                        ],
                        "x": ["type": ["number", "null"]],
                        "y": ["type": ["number", "null"]],
                        "text": ["type": ["string", "null"]],
                        "key": [
                            "type": ["string", "null"],
                            "enum": SupportedInputKey.allCases.map { $0.rawValue as Any } + [NSNull()],
                        ],
                        "amount": ["type": ["integer", "null"]],
                        "milliseconds": ["type": ["integer", "null"]],
                        "boundary": ["type": "boolean"],
                    ],
                    "required": ["kind", "x", "y", "text", "key", "amount", "milliseconds", "boundary"],
                ],
            ],
        ],
        "required": ["summary", "expectsVisualChange", "actions"],
    ]
}
