import XCTest
import Foundation
import CoreGraphics
@testable import ExamPilotCore

final class OpenAIResponsesVisionAgentAccessibilityTests: XCTestCase {
    func testPromptIncludesBoundedAccessibilityHintsWithoutRawTextFields() async throws {
        let transport = AccessibilityPromptTransport(responseData: Data(responseFixture.utf8))
        let agent = OpenAIResponsesVisionAgent(apiKey: "test-key", model: "gpt-test", transport: transport)
        let observation = AccessibilityObservation(
            stateVersion: 7,
            processID: 42,
            windowBounds: AccessibilityBounds(x: 100, y: 50, width: 1200, height: 800),
            elements: [
                AccessibilityElementHint(
                    role: .radioButton,
                    bounds: AccessibilityBounds(x: 150, y: 180, width: 20, height: 20),
                    isFocused: false,
                    isSelected: true,
                    isEnabled: true
                ),
                AccessibilityElementHint(
                    role: .button,
                    bounds: AccessibilityBounds(x: 1100, y: 780, width: 120, height: 36),
                    isFocused: true,
                    isSelected: nil,
                    isEnabled: true
                )
            ]
        )
        let state = ExamObservationState(
            cycle: 1,
            nonProgressCount: 0,
            lastSummary: nil,
            stateVersion: 7,
            accessibility: observation
        )

        _ = try await agent.decide(frame: makeFrame(), state: state)

        let bodyData = try XCTUnwrap(transport.lastRequest?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let textPart = try XCTUnwrap(content.first { $0["type"] as? String == "input_text" })
        let prompt = try XCTUnwrap(textPart["text"] as? String)

        XCTAssertTrue(prompt.contains("accessibility_hints="))
        XCTAssertTrue(prompt.contains("radio_button"))
        XCTAssertTrue(prompt.contains("selected=true"))
        XCTAssertTrue(prompt.contains("button"))
        XCTAssertTrue(prompt.contains("focused=true"))
        XCTAssertFalse(prompt.lowercased().contains("accessibility_label="))
        XCTAssertFalse(prompt.lowercased().contains("accessibility_value="))
    }

    private var responseFixture: String {
        #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"summary\":\"done\",\"expectsVisualChange\":false,\"actions\":[{\"kind\":\"finish\",\"boundary\":true}]}"}]}]}"#
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
            throw NSError(domain: "OpenAIResponsesVisionAgentAccessibilityTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            screenBounds: CGRect(x: 100, y: 50, width: 1200, height: 800),
            targetProcessID: 42
        )
    }
}

private final class AccessibilityPromptTransport: HTTPTransport {
    let responseData: Data
    var lastRequest: URLRequest?

    init(responseData: Data) {
        self.responseData = responseData
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}
