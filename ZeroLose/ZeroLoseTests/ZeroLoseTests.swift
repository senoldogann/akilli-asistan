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

    func testAIModelNamesPreferOpenAIProfilesWhenEnabled() {
        XCTAssertEqual(AIModelNames.reasoning(forProvider: .openAI), "gpt-5-mini")
        XCTAssertEqual(AIModelNames.coding(forProvider: .openAI), "gpt-5.2-codex")
        XCTAssertEqual(AIModelNames.fast(forProvider: .openAI), "gpt-4o-mini")
        XCTAssertEqual(AIModelNames.whisper(forProvider: .openAI), "gpt-4o-mini-transcribe")
    }

    func testAIModelNamesFallbackToLegacyProfilesForOllama() {
        XCTAssertEqual(AIModelNames.reasoning(forProvider: .ollama), "llama3.1:8b-cloud")
        XCTAssertEqual(AIModelNames.coding(forProvider: .ollama), "qwen2.5-coder:7b-cloud")
        XCTAssertEqual(AIModelNames.fast(forProvider: .ollama), "qwen2.5:7b-cloud")
        XCTAssertEqual(AIModelNames.whisper(forProvider: .ollama), "whisper-large-v3-turbo")
    }

    func testAIModelNamesDeepSeekProfiles() {
        XCTAssertEqual(AIModelNames.reasoning(forProvider: .deepSeek), "deepseek-v4-pro")
        XCTAssertEqual(AIModelNames.coding(forProvider: .deepSeek), "deepseek-v4-pro")
        XCTAssertEqual(AIModelNames.fast(forProvider: .deepSeek), "deepseek-v4-flash")
        XCTAssertEqual(AIModelNames.whisper(forProvider: .deepSeek), "deepseek-v4-flash-vision-exp")
    }

    func testTranscriptionProviderPrefersOpenAIWhenKeyModeEnabled() {
        XCTAssertEqual(GroqService.transcriptionProvider(preferOpenAI: true), "openai")
        XCTAssertEqual(GroqService.transcriptionProvider(preferOpenAI: false), "groq")
    }

    func testTranscriptionResponseFormatMatchesProviderCapabilities() {
        XCTAssertEqual(GroqService.transcriptionResponseFormat(preferOpenAI: true), "json")
        XCTAssertEqual(GroqService.transcriptionResponseFormat(preferOpenAI: false), "verbose_json")
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
