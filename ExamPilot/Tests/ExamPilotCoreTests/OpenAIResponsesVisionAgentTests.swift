import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class OpenAIResponsesVisionAgentTests: XCTestCase {
    func testDecodesStructuredDecisionFromOutputText() throws {
        let data = Data(fixtureResponse(decisionJSON: #"{"summary":"choose B","expectsVisualChange":true,"actions":[{"kind":"move_click","x":500,"y":400,"boundary":true}]}"#).utf8)

        let decision = try OpenAIResponsesVisionAgent.decodeDecision(from: data)

        XCTAssertEqual(decision.summary, "choose B")
        XCTAssertEqual(decision.actions, [.moveClick(x: 500, y: 400, boundary: true)])
    }

    func testMissingOutputTextThrows() {
        let data = Data(#"{"output":[{"type":"message","content":[]}]}"#.utf8)
        XCTAssertThrowsError(try OpenAIResponsesVisionAgent.decodeDecision(from: data)) { error in
            XCTAssertEqual(error as? VisionAgentError, .missingOutputText)
        }
    }

    func testMalformedDecisionThrows() {
        let data = Data(fixtureResponse(decisionJSON: "not-json").utf8)
        XCTAssertThrowsError(try OpenAIResponsesVisionAgent.decodeDecision(from: data)) { error in
            XCTAssertEqual(error as? VisionAgentError, .invalidDecision)
        }
    }

    func testDecideBuildsResponsesRequestWithImageDataURL() async throws {
        let transport = RecordingTransport(responseData: Data(fixtureResponse(decisionJSON: #"{"summary":"done","expectsVisualChange":false,"actions":[{"kind":"finish","boundary":true}]}"#).utf8))
        let agent = OpenAIResponsesVisionAgent(apiKey: "test-key", model: "gpt-test", transport: transport)
        let frame = try makeFrame()

        _ = try await agent.decide(frame: frame, state: ExamObservationState(cycle: 2, nonProgressCount: 1, lastSummary: "previous"))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("gpt-test"))
        XCTAssertTrue(body.contains("input_image"))
        XCTAssertTrue(body.contains("data:image/jpeg;base64,"))
        XCTAssertTrue(body.contains("json_schema"))
    }

    private func fixtureResponse(decisionJSON: String) -> String {
        let escaped = decisionJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"output":[{"type":"message","content":[{"type":"output_text","text":""# + escaped + #""}]}]}"#
    }

    private func makeFrame() throws -> ScreenFrame {
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            throw NSError(domain: "tests", code: 1)
        }
        return ScreenFrame(image: image, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), screenBounds: CGRect(x: 100, y: 50, width: 1200, height: 800))
    }
}

private final class RecordingTransport: HTTPTransport {
    let responseData: Data
    var lastRequest: URLRequest?

    init(responseData: Data) { self.responseData = responseData }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}
