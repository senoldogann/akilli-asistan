import XCTest
@testable import ZeroLose

/// Cross-cutting behaviour that is not specific to the V2 runtime packages:
/// transcription routing, tool-schema encoding, web-search query preparation and
/// chat message presentation contracts.
@MainActor
final class ZeroLoseTests: XCTestCase {
    func testTranscriptionProviderPrefersOpenAIWhenKeyModeEnabled() {
        XCTAssertEqual(GroqService.transcriptionProvider(preferOpenAI: true), "openai")
        XCTAssertEqual(GroqService.transcriptionProvider(preferOpenAI: false), "groq")
    }

    func testTranscriptionResponseFormatMatchesProviderCapabilities() {
        XCTAssertEqual(GroqService.transcriptionResponseFormat(preferOpenAI: true), "json")
        XCTAssertEqual(GroqService.transcriptionResponseFormat(preferOpenAI: false), "verbose_json")
    }

    /// Voice transcription is the one documented compatibility-only model name
    /// that is pinned locally instead of coming from a provider router.
    func testTranscriptionModelsArePinnedPerEndpoint() {
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZeroLose/Services/GroqService.swift"),
            encoding: .utf8
        )
        XCTAssertNotNil(source)
        XCTAssertTrue(source?.contains("gpt-4o-mini-transcribe") == true)
        XCTAssertTrue(source?.contains("whisper-large-v3-turbo") == true)
        XCTAssertFalse(source?.contains("AIModelNames") == true)
    }

    func testStructuredToolSchemasAreOpenAICompatible() throws {
        let tool = AgentFunctionTool(
            type: "function",
            function: .init(
                name: "builtin.echo",
                description: "Echo a bounded string",
                parameters: .init(
                    type: "object",
                    properties: ["message": .string("Text to echo")],
                    required: ["message"],
                    additionalProperties: false
                )
            )
        )

        let data = try JSONEncoder().encode(tool)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "function")
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "builtin.echo")
        XCTAssertNotNil(function["parameters"] as? [String: Any])
    }

    func testAgentToolCallDecodesJSONObjectArguments() {
        let call = AgentToolCall(name: "web_search", argumentsJSON: "{\"query\":\"Swift 6\"}")
        XCTAssertEqual(call.arguments?["query"] as? String, "Swift 6")
    }

    func testV2ShellRuntimeUserDefaultsBoolUsesDefaultWhenKeyMissing() {
        let key = "ZeroLoseTests.autoAnalyze.missing.\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: key)

        XCTAssertTrue(V2ShellRuntimeController.userDefaultsBool(key, defaultValue: true))
        XCTAssertFalse(V2ShellRuntimeController.userDefaultsBool(key, defaultValue: false))
    }

    func testTavilyPreferredQueryExtractsNaturalQuestionFromCodeHeavyPrompt() {
        let query = """
        type User = {
          id: string;
          email: string;
          balance: number;
        };

        async function transferMoney() {
          await db.save();
        }

        Mikä vikaa on koodissa?
        """

        let prepared = TavilyService.preferredQuery(from: query, maxLength: 120)

        XCTAssertLessThanOrEqual(prepared.count, 120)
        XCTAssertTrue(prepared.localizedCaseInsensitiveContains("Mikä vikaa on koodissa"))
        XCTAssertFalse(prepared.localizedCaseInsensitiveContains("type User"))
    }

    func testTavilyPreferredQueryRespectsProviderLengthLimit() {
        let query = String(repeating: "latest react release benchmark results ", count: 30)

        let prepared = TavilyService.preferredQuery(from: query, maxLength: 180)

        XCTAssertLessThanOrEqual(prepared.count, 180)
    }

    func testMessageContentEquatableUsesTextAndRoleOnly() {
        let a = MessageContent(text: "Hei maailma", isUser: false, thinking: nil)
        let b = MessageContent(text: "Hei maailma", isUser: false, thinking: nil)
        let c = MessageContent(text: "Hei maailma", isUser: true, thinking: nil)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMessageParserKeepsCodeBlockAsDedicatedSegment() {
        let text = """
        Tässä ongelma lyhyesti.

        ```ts
        const value = 42;
        ```
        """

        let segments = MessageParser.parse(text)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue({
            if case .paragraph(let content) = segments[0].type {
                return content.contains("Tässä ongelma")
            }
            return false
        }())
        XCTAssertTrue({
            if case .code(let language, let code) = segments[1].type {
                return language == "ts" && code.contains("const value = 42;")
            }
            return false
        }())
    }

    func testChatMessageAllowsAIRefinementForCacheOrigin() {
        let message = ChatMessage(
            text: "Cached answer",
            isUser: false,
            type: .text,
            assistantOrigin: .cache,
            relatedQuery: "Can you tell me about your Node.js experience?"
        )

        XCTAssertTrue(message.allowsAIRefinement)
        XCTAssertEqual(message.assistantBadgeText, "CACHE")
    }

    func testChatMessageDoesNotAllowAIRefinementForAIGeneratedOrigin() {
        let message = ChatMessage(
            text: "AI generated answer",
            isUser: false,
            type: .text,
            assistantOrigin: .aiGenerated,
            relatedQuery: "Can you tell me about your Node.js experience?"
        )

        XCTAssertFalse(message.allowsAIRefinement)
        XCTAssertNil(message.assistantBadgeText)
    }
}
