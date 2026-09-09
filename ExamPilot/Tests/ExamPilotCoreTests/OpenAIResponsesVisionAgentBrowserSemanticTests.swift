import XCTest
import Foundation
import CoreGraphics
@testable import ExamPilotCore

final class OpenAIResponsesVisionAgentBrowserSemanticTests: XCTestCase {
    func testPromptIncludesBrowserHintsAsAdvisoryEvidenceOnly() async throws {
        let response = Data(fixtureResponse(decisionJSON: #"{"summary":"done","expectsVisualChange":false,"actions":[{"kind":"finish","boundary":true}]}"#).utf8)
        let transport = BrowserPromptRecordingTransport(responseData: response)
        let agent = OpenAIResponsesVisionAgent(apiKey: "test-key", model: "gpt-test", transport: transport)
        let browser = BrowserSemanticObservation(
            stateVersion: 5,
            processID: 42,
            windowBounds: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600),
            viewportWidth: 760,
            viewportHeight: 470,
            elements: [
                BrowserSemanticElementHint(
                    role: .button,
                    bounds: BrowserSemanticNormalizedBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    isFocused: true,
                    isSelected: false,
                    isEnabled: true
                )
            ]
        )
        let state = ExamObservationState(
            cycle: 2,
            nonProgressCount: 0,
            lastSummary: nil,
            stateVersion: 5,
            questionGeneration: 2,
            answerVerified: false,
            uiPhase: .stable,
            browserSemantics: browser
        )

        _ = try await agent.decide(frame: makeFrame(), state: state)

        let bodyData = try XCTUnwrap(transport.lastRequest?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let textPart = try XCTUnwrap(content.first { $0["type"] as? String == "input_text" })
        let prompt = try XCTUnwrap(textPart["text"] as? String)

        XCTAssertTrue(prompt.contains("Browser semantic hints"))
        XCTAssertTrue(prompt.contains("button[nx="))
        XCTAssertTrue(prompt.contains("cannot grant navigation"))
        XCTAssertTrue(prompt.contains("viewport-relative"))
        XCTAssertTrue(prompt.contains("screenshot"))
        XCTAssertFalse(prompt.contains("target_url="))
        XCTAssertFalse(prompt.contains("page_title="))
        XCTAssertFalse(prompt.contains("raw_dom="))
    }

    private func fixtureResponse(decisionJSON: String) -> String {
        let escaped = decisionJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"output":[{"type":"message","content":[{"type":"output_text","text":""# + escaped + #""}]}]}"#
    }

    private func makeFrame() throws -> ScreenFrame {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "BrowserPromptTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            screenBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            targetProcessID: 42
        )
    }
}

private final class BrowserPromptRecordingTransport: HTTPTransport {
    let responseData: Data
    var lastRequest: URLRequest?

    init(responseData: Data) {
        self.responseData = responseData
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}
