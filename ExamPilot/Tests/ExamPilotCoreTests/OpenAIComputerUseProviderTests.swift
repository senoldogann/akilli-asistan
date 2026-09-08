import XCTest
import Foundation
import CoreGraphics
@testable import ExamPilotCore

final class OpenAIComputerUseProviderTests: XCTestCase {
    func testInitialRequestUsesComputerToolAndOriginalScreenshotDetail() async throws {
        let transport = ComputerUseRecordingTransport(responseData: terminalResponseData())
        let provider = OpenAIComputerUseProvider(
            apiKey: "test-key",
            model: "gpt-test",
            transport: transport
        )
        let state = ComputerAgentProviderState(
            sessionID: "session-initial",
            goal: "Complete authorized browser task",
            stateVersion: 7,
            questionGeneration: 3,
            answerVerified: false,
            uiPhase: .stable,
            workingMemory: AgentWorkingMemorySnapshot()
        )

        _ = try await provider.nextStep(frame: makeFrame(), state: state)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["previous_response_id"])

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "computer")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let textPart = try XCTUnwrap(content.first { $0["type"] as? String == "input_text" })
        let prompt = try XCTUnwrap(textPart["text"] as? String)
        XCTAssertTrue(prompt.contains("session_id=session-initial"))
        XCTAssertTrue(prompt.contains("state_version=7"))
        XCTAssertFalse(prompt.contains("test-key"))

        let imagePart = try XCTUnwrap(content.first { $0["type"] as? String == "input_image" })
        XCTAssertEqual(imagePart["detail"] as? String, "original")
        XCTAssertTrue((imagePart["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    func testContinuationRequestUsesPreviousResponseAndComputerCallOutput() async throws {
        let transport = ComputerUseRecordingTransport(responseData: terminalResponseData())
        let provider = OpenAIComputerUseProvider(
            apiKey: "test-key",
            model: "gpt-test",
            transport: transport
        )
        let state = ComputerAgentProviderState(
            sessionID: "session-continuation",
            goal: "Complete authorized browser task",
            stateVersion: 11,
            questionGeneration: 5,
            answerVerified: true,
            uiPhase: .stable,
            workingMemory: AgentWorkingMemorySnapshot(),
            previousResponseID: "resp_previous",
            pendingComputerCallID: "call_previous"
        )

        _ = try await provider.nextStep(frame: makeFrame(), state: state)

        let bodyData = try XCTUnwrap(transport.lastRequest?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_previous")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "computer")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "computer_call_output")
        XCTAssertEqual(input[0]["call_id"] as? String, "call_previous")
        XCTAssertNil(input[0]["role"])

        let output = try XCTUnwrap(input[0]["output"] as? [String: Any])
        XCTAssertEqual(output["type"] as? String, "computer_screenshot")
        XCTAssertEqual(output["detail"] as? String, "original")
        XCTAssertTrue((output["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    private func terminalResponseData() -> Data {
        Data(#"{"id":"resp_done","output":[{"type":"message","content":[{"type":"output_text","text":"done"}]}]}"#.utf8)
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
            throw NSError(domain: "OpenAIComputerUseProviderTests", code: 1)
        }
        return ScreenFrame(
            image: image,
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }
}

private final class ComputerUseRecordingTransport: HTTPTransport {
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
