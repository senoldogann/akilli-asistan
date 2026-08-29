import XCTest
@testable import ZeroLose

@MainActor
final class ZeroLoseTests: XCTestCase {
    private static var retainedServices: [ResponseCacheService] = []

    private func makeService() -> ResponseCacheService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroLoseSmokeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = ResponseCacheService(cacheURL: directory.appendingPathComponent("ResponseCache.json"))
        Self.retainedServices.append(service)
        return service
    }

    func testResponseCacheSmokeExactMatch() {
        let service = makeService()
        _ = service.primeInterviewVault(entries: [
            (question: "Tell me about yourself", answer: "I am a senior frontend engineer.", category: "Intro")
        ])

        XCTAssertEqual(
            service.getResponse(for: "Tell me about yourself"),
            "I am a senior frontend engineer."
        )
    }

    func testActiveRoleProfileIgnoresImportedHeaderLines() {
        let description = """
        --- Imported Role (loihde.txt) ---
        Loihde

        Etsimme kokenutta fullstack-ohjelmistokehittäjää.
        Mitä odotamme sinulta:
        * Kokemusta Node.js:stä ja Reactista
        """

        let profile = ActiveRoleProfileService.profile(from: description)

        XCTAssertEqual(profile?.company, "Loihde")
        XCTAssertTrue(profile?.roleTitle.localizedCaseInsensitiveContains("fullstack") == true)
    }

    func testAIModelNamesProviderProfilesAreDeterministic() {
        XCTAssertFalse(AIModelNames.reasoning(forProvider: .openAI).isEmpty)
        XCTAssertFalse(AIModelNames.coding(forProvider: .openAI).isEmpty)
        XCTAssertFalse(AIModelNames.fast(forProvider: .openAI).isEmpty)
        XCTAssertFalse(AIModelNames.whisper(forProvider: .openAI).isEmpty)

        XCTAssertFalse(AIModelNames.reasoning(forProvider: .ollama).isEmpty)
        XCTAssertFalse(AIModelNames.coding(forProvider: .ollama).isEmpty)
        XCTAssertFalse(AIModelNames.fast(forProvider: .ollama).isEmpty)
        XCTAssertFalse(AIModelNames.whisper(forProvider: .ollama).isEmpty)

        XCTAssertFalse(AIModelNames.reasoning(forProvider: .deepSeek).isEmpty)
        XCTAssertFalse(AIModelNames.coding(forProvider: .deepSeek).isEmpty)
        XCTAssertFalse(AIModelNames.fast(forProvider: .deepSeek).isEmpty)
        XCTAssertFalse(AIModelNames.whisper(forProvider: .deepSeek).isEmpty)
    }

    func testReasoningEffortOptionsUseNativeProviderValues() {
        XCTAssertEqual(AIModelNames.reasoningEffortOptions(for: .openAI, model: "gpt-5"), ["none", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(AIModelNames.reasoningEffortOptions(for: .deepSeek, model: "deepseek-v4-pro"), ["low", "high", "max"])
        XCTAssertTrue(AIModelNames.reasoningEffortOptions(for: .ollama, model: "llama3.1:8b-cloud").isEmpty)
    }

    /// Konteks penceresi model bazlı olmalı: farklı modeller farklı pencere
    /// göstermeli, bilinmeyen modeller provider varsayılanına düşmeli.
    func testContextWindowIsModelAwareAcrossProviders() {
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .openAI, model: "gpt-5.2-codex"), 1_000_000)
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .openAI, model: "gpt-5"), 400_000)
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .deepSeek, model: "deepseek-v4-pro"), 128_000)
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .openCodeZen, model: "claude-sonnet-5"), 1_000_000)
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .openCodeGo, model: "qwen3.6-plus"), 256_000)
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .openCodeGo, model: "kimi-k2.7-code"), 128_000)
        // Bilinmeyen model -> provider seviyesi varsayılan
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .openCodeGo, model: "unknown-model-x"), 200_000)
        XCTAssertEqual(AIModelNames.contextWindow(forProvider: .ollama, model: "llama3.1:8b-cloud"), 32_000)
        // Aynı provider içinde farklı modeller farklı pencere döndürmeli
        XCTAssertNotEqual(
            AIModelNames.contextWindow(forProvider: .openCodeZen, model: "claude-sonnet-5"),
            AIModelNames.contextWindow(forProvider: .openCodeZen, model: "gpt-5")
        )
    }

    func testTranscriptionProviderPrefersOpenAIWhenKeyModeEnabled() {
        XCTAssertEqual(GroqService.transcriptionProvider(preferOpenAI: true), "openai")
        XCTAssertEqual(GroqService.transcriptionProvider(preferOpenAI: false), "groq")
    }

    func testTranscriptionResponseFormatMatchesProviderCapabilities() {
        XCTAssertEqual(GroqService.transcriptionResponseFormat(preferOpenAI: true), "json")
        XCTAssertEqual(GroqService.transcriptionResponseFormat(preferOpenAI: false), "verbose_json")
    }

    func testStructuredToolSchemasAreOpenAICompatible() throws {
        let tools = AgentCapabilityRegistry.structuredTools()
        XCTAssertFalse(tools.isEmpty)
        XCTAssertEqual(tools.first?.type, "function")
        XCTAssertEqual(tools.first?.function.name, "web_search")
        let data = try JSONEncoder().encode(tools.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "function")
        XCTAssertNotNil(object["function"] as? [String: Any])
    }

    func testNativeToolCallDecodingFromChatCompletionPayload() throws {
        let json = #"""
        {
          "choices": [{
            "message": {
              "role": "assistant",
              "content": null,
              "tool_calls": [{
                "id": "call_abc",
                "type": "function",
                "function": {"name": "web_search", "arguments": "{\"query\":\"Swift 6\"}"}
              }]
            }
          }]
        }
        """#
        let calls = OllamaService.decodeNativeToolCalls(from: Data(json.utf8))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "call_abc")
        XCTAssertEqual(calls.first?.name, "web_search")
        XCTAssertEqual(calls.first?.arguments?["query"] as? String, "Swift 6")
    }

    func testStructuredToolsCoverEveryCapability() {
        let tools = AgentCapabilityRegistry.structuredTools()
        let names = Set(tools.map { $0.function.name })
        for capability in AgentCapabilityRegistry.all {
            XCTAssertTrue(names.contains(capability.actionType), "Missing tool schema for \(capability.actionType)")
        }
    }

    func testAgentToolCallDecodesJSONObjectArguments() {
        let call = AgentToolCall(name: "web_search", argumentsJSON: "{\"query\":\"Swift 6\"}")
        XCTAssertEqual(call.arguments?["query"] as? String, "Swift 6")
    }

    func testCodexModelsPreferOpenAIResponsesAPI() {
        XCTAssertTrue(OllamaService.shouldUseResponsesAPI(for: "gpt-5.2-codex"))
        XCTAssertFalse(OllamaService.shouldUseResponsesAPI(for: "gpt-5-mini"))
        XCTAssertFalse(OllamaService.shouldUseResponsesAPI(for: "gpt-4o-mini"))
    }

    func testOllamaErrorsExposeReadableDescriptions() {
        let error = OllamaError.serverError("OpenAI Responses API Error (400): bad request")
        XCTAssertEqual(error.localizedDescription, "OpenAI Responses API Error (400): bad request")
    }

    func testGhostViewModelUserDefaultsBoolUsesDefaultWhenKeyMissing() {
        let key = "ZeroLoseTests.autoAnalyze.missing.\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: key)

        XCTAssertTrue(GhostViewModel.userDefaultsBool(key, defaultValue: true))
        XCTAssertFalse(GhostViewModel.userDefaultsBool(key, defaultValue: false))
    }

    func testInstantInterviewCacheDoesNotDisableForStrongRoleSignal() {
        XCTAssertTrue(
            IntelligenceService.canUseInstantInterviewCache(
                isInterviewConcise: true,
                requiresWebSearch: false,
                isCodingQuery: false,
                isFollowUpQuery: false,
                strongestRoleScore: 0.91,
                cacheIsWarm: true
            )
        )
    }

    func testInterviewNoteCacheEntriesExtractQuestionBlocks() {
        let notes = """
        1. Kerrotko vähän itsestäsi?

        Olen full stack -kehittäjä, jolla on yli seitsemän vuoden kokemus.

        2. Miksi hait juuri Loihteelle?

        Loihteessa minua kiinnostaa asiakasprojektien monipuolisuus.
        """

        let entries = IntelligenceService.interviewNoteCacheEntries(from: notes)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].question, "Kerrotko vähän itsestäsi?")
        XCTAssertTrue(entries[0].answer.contains("full stack"))
        XCTAssertEqual(entries[1].question, "Miksi hait juuri Loihteelle?")
    }

    func testVaultExportSnapshotIncludesCountsAndAllCategories() {
        let categories = [
            VaultInterviewCategory(
                title: "Intro",
                icon: "person.fill",
                items: [
                    VaultInterviewItem(
                        question: "Kerrotko vähän itsestäsi?",
                        answerFinnish: "Olen full stack -kehittäjä.",
                        translationTr: "Biraz kendinden bahseder misin?",
                        keyPoints: ["intro"]
                    )
                ]
            ),
            VaultInterviewCategory(
                title: "Clients",
                icon: "person.2.fill",
                items: [
                    VaultInterviewItem(
                        question: "Miten toimit asiakkaan kanssa ongelmatilanteessa?",
                        answerFinnish: "Pysyn rauhallisena ja selvitän faktat.",
                        translationTr: "Müşteriyle problem olursa nasıl davranırsın?",
                        keyPoints: ["client", "problem"]
                    ),
                    VaultInterviewItem(
                        question: "Oletko tehnyt asiakastyötä?",
                        answerFinnish: "Kyllä, useissa projekteissa.",
                        translationTr: "Müşteriyle çalıştın mı?",
                        keyPoints: ["client"]
                    )
                ]
            )
        ]

        let snapshot = VaultService.exportSnapshot(
            for: categories,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.totalCategories, 2)
        XCTAssertEqual(snapshot.totalQuestions, 3)
        XCTAssertEqual(snapshot.categories.count, 2)
        XCTAssertEqual(snapshot.categories[1].items.count, 2)
    }

    func testVaultExportDataEncodesCleanJSONEnvelope() throws {
        let categories = [
            VaultInterviewCategory(
                title: "Intro",
                icon: "person.fill",
                items: [
                    VaultInterviewItem(
                        question: "Kerrotko vähän itsestäsi?",
                        answerFinnish: "Olen full stack -kehittäjä.",
                        translationTr: "Biraz kendinden bahseder misin?",
                        keyPoints: ["intro"]
                    )
                ]
            )
        ]

        let data = try VaultService.exportData(
            for: categories,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VaultExportSnapshot.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded.totalCategories, 1)
        XCTAssertEqual(decoded.totalQuestions, 1)
        XCTAssertTrue(json.contains("\"categories\""))
        XCTAssertTrue(json.contains("\"totalQuestions\""))
        XCTAssertTrue(json.contains("Kerrotko vähän itsestäsi?"))
    }

    func testVaultImportCategoriesSupportsExportEnvelope() throws {
        let categories = [
            VaultInterviewCategory(
                title: "Intro",
                icon: "person.fill",
                items: [
                    VaultInterviewItem(
                        question: "Kerrotko vähän itsestäsi?",
                        answerFinnish: "Olen full stack -kehittäjä.",
                        translationTr: "Biraz kendinden bahseder misin?",
                        keyPoints: ["intro"]
                    )
                ]
            )
        ]

        let data = try VaultService.exportData(
            for: categories,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let imported = try VaultService.importCategories(from: data)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.items.count, 1)
        XCTAssertEqual(imported.first?.items.first?.question, "Kerrotko vähän itsestäsi?")
    }

    func testVaultImportCategoriesSupportsLegacyArrayFormat() throws {
        let categories = [
            VaultInterviewCategory(
                title: "Clients",
                icon: "person.2.fill",
                items: [
                    VaultInterviewItem(
                        question: "Oletko tehnyt asiakastyötä?",
                        answerFinnish: "Kyllä, useissa projekteissa.",
                        translationTr: "Müşteriyle çalıştın mı?",
                        keyPoints: ["client"]
                    )
                ]
            )
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(categories)
        let imported = try VaultService.importCategories(from: data)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.title, "Clients")
        XCTAssertEqual(imported.first?.items.first?.answerFinnish, "Kyllä, useissa projekteissa.")
    }

    func testVaultImportCategoriesSupportsEnvelopeWithFractionalSecondTimestamp() throws {
        let json = """
        {
          "exportedAt": "2026-03-14T15:51:07.218605Z",
          "totalCategories": 1,
          "totalQuestions": 1,
          "categories": [
            {
              "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "title": "Intro",
              "icon": "person.fill",
              "items": [
                {
                  "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                  "question": "Kerrotko vähän itsestäsi?",
                  "answerFinnish": "Olen full stack -kehittäjä.",
                  "translationTr": "Can you tell me about yourself?",
                  "keyPoints": ["intro"]
                }
              ]
            }
          ]
        }
        """

        let imported = try VaultService.importCategories(from: Data(json.utf8))

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.items.count, 1)
        XCTAssertEqual(imported.first?.items.first?.question, "Kerrotko vähän itsestäsi?")
    }

    func testVaultImportCategoriesRecoversFromInvalidIDs() throws {
        let json = """
        {
          "exportedAt": "2026-03-14T15:51:07.218605Z",
          "totalCategories": 1,
          "totalQuestions": 1,
          "categories": [
            {
              "id": "A1B2C3D4-E5F6-4A7B-8C9D-MONITORING",
              "title": "Tekninen",
              "icon": "gearshape.fill",
              "items": [
                {
                  "id": "A1B2C3D4-E5F6-4A7B-8C9D-TROUBLESHOOT",
                  "question": "Miten debuggaat tuotanto-ongelman?",
                  "answerFinnish": "Aloitan vaikutuksen rajaamisesta ja lokien analyysistä.",
                  "translationTr": "How do you debug a production issue?",
                  "keyPoints": ["debug", "logs"]
                }
              ]
            }
          ]
        }
        """

        let imported = try VaultService.importCategories(from: Data(json.utf8))

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.items.count, 1)
        XCTAssertEqual(imported.first?.title, "Tekninen")
        XCTAssertNotEqual(imported.first?.id.uuidString, "A1B2C3D4-E5F6-4A7B-8C9D-MONITORING")
        XCTAssertNotEqual(imported.first?.items.first?.id.uuidString, "A1B2C3D4-E5F6-4A7B-8C9D-TROUBLESHOOT")
    }

    func testVaultMergeCategoriesMergesByTitleAndQuestion() {
        let existing = [
            VaultInterviewCategory(
                id: UUID(),
                title: "Clients",
                icon: "person.2.fill",
                items: [
                    VaultInterviewItem(
                        id: UUID(),
                        question: "Oletko tehnyt asiakastyötä?",
                        answerFinnish: "Vanha vastaus",
                        translationTr: "Eski cevap",
                        keyPoints: ["old"]
                    )
                ]
            )
        ]
        let imported = [
            VaultInterviewCategory(
                title: "Clients",
                icon: "briefcase.fill",
                items: [
                    VaultInterviewItem(
                        question: "Oletko tehnyt asiakastyötä?",
                        answerFinnish: "Uusi vastaus",
                        translationTr: "Yeni cevap",
                        keyPoints: ["new"]
                    ),
                    VaultInterviewItem(
                        question: "Miten toimit ongelmatilanteessa asiakkaan kanssa?",
                        answerFinnish: "Pysyn rauhallisena ja ratkaisukeskeisenä.",
                        translationTr: "Müşteri problemi olursa sakin kalırım.",
                        keyPoints: ["client", "problem"]
                    )
                ]
            )
        ]

        let merged = VaultService.mergeCategories(existing: existing, imported: imported)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].icon, "briefcase.fill")
        XCTAssertEqual(merged[0].items.count, 2)
        XCTAssertEqual(merged[0].items[0].answerFinnish, "Uusi vastaus")
        XCTAssertEqual(merged[0].items[1].question, "Miten toimit ongelmatilanteessa asiakkaan kanssa?")
    }

    func testVaultImportCategoriesRejectsUnsupportedFormat() {
        let data = Data("not a vault json".utf8)

        XCTAssertThrowsError(try VaultService.importCategories(from: data)) { error in
            XCTAssertEqual(
                (error as? VaultImportError)?.localizedDescription,
                VaultImportError.unsupportedFormat.localizedDescription
            )
        }
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
