import XCTest
import Foundation
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

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-test")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let imagePart = try XCTUnwrap(content.first { $0["type"] as? String == "input_image" })
        let imageURL = try XCTUnwrap(imagePart["image_url"] as? String)
        XCTAssertTrue(imageURL.hasPrefix("data:image/jpeg;base64,"))

        let textConfig = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(textConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
    }

    func testStructuredSchemaRestrictsKeyActionsToDriverSupportedNames() async throws {
        let transport = RecordingTransport(responseData: Data(fixtureResponse(decisionJSON: #"{"summary":"done","expectsVisualChange":false,"actions":[{"kind":"finish","boundary":true}]}"#).utf8))
        let agent = OpenAIResponsesVisionAgent(apiKey: "test-key", model: "gpt-test", transport: transport)

        _ = try await agent.decide(frame: makeFrame(), state: ExamObservationState(cycle: 1, nonProgressCount: 0, lastSummary: nil))

        let bodyData = try XCTUnwrap(transport.lastRequest?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        let items = try XCTUnwrap(actions["items"] as? [String: Any])
        let actionProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let keySchema = try XCTUnwrap(actionProperties["key"] as? [String: Any])
        let allowed = try XCTUnwrap(keySchema["enum"] as? [Any])
        let allowedStrings = allowed.compactMap { $0 as? String }

        XCTAssertTrue(allowedStrings.contains("return"))
        XCTAssertTrue(allowedStrings.contains("arrow_left"))
        XCTAssertFalse(allowedStrings.contains("cmd+enter"))
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
