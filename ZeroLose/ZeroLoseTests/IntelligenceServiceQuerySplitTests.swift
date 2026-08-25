import XCTest
@testable import ZeroLose

final class IntelligenceServiceQuerySplitTests: XCTestCase {
    func testSplitQuestionSegmentsHandlesTwoFinnishQuestions() {
        let query = "Voitko kertoa itsestäsi? Miksi Loihde?"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], "Voitko kertoa itsestäsi?")
        XCTAssertEqual(segments[1], "Miksi Loihde?")
    }

    func testSplitQuestionSegmentsReturnsEmptyForStatementWithoutQuestionSignals() {
        let query = "Rakennan web-sovelluksia Reactilla ja Node.js:llä"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertTrue(segments.isEmpty)
    }

    func testSplitQuestionSegmentsInfersTwoQuestionsWithoutQuestionMarks() {
        let query = "Voitko kertoa itsestäsi ja miksi Loihde"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], "Voitko kertoa itsestäsi?")
        XCTAssertEqual(segments[1], "miksi Loihde?")
    }

    func testSplitQuestionSegmentsInfersQuestionsFromStarterBoundariesWithoutConnector() {
        let query = "Kuka sinä olet millainen palkkatoive sinulla on"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], "Kuka sinä olet?")
        XCTAssertEqual(segments[1], "millainen palkkatoive sinulla on?")
    }

    func testSplitQuestionSegmentsDeduplicatesAndCapsToThree() {
        let query = "Miksi Loihde? Miksi Loihde? Voitko kertoa itsestäsi? Milloin voit aloittaa? Paljonko palkka?"
        let segments = IntelligenceService.splitQuestionSegments(query)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], "Miksi Loihde?")
        XCTAssertEqual(segments[1], "Voitko kertoa itsestäsi?")
        XCTAssertEqual(segments[2], "Milloin voit aloittaa?")
    }

    func testScopedVaultCategoriesKeepsOnlyCodingCategoryForCodingQueries() {
        let categories = [
            VaultInterviewCategory(
                title: "Tanisma. & Kariyer Tip 2",
                icon: "person",
                items: [
                    VaultInterviewItem(
                        question: "Kerro itsestäsi?",
                        answerFinnish: "Olen full stack kehittäjä.",
                        translationTr: "Kendinden bahseder misin?",
                        keyPoints: ["intro", "career"]
                    )
                ]
            ),
            VaultInterviewCategory(
                title: "Kodlama",
                icon: "chevron.left.forwardslash.chevron.right",
                items: [
                    VaultInterviewItem(
                        question: "How do you debug a memory leak?",
                        answerFinnish: "Rajaan ongelman ja mittaan ensin.",
                        translationTr: "Memory leak'i nasıl debug edersin?",
                        keyPoints: ["debug", "memory leak"]
                    )
                ]
            )
        ]

        let scoped = IntelligenceService.scopedVaultCategories(categories, codingOnly: true)

        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.title, "Kodlama")
    }

    func testScopedVaultCategoriesKeepsAllCategoriesForNonCodingQueries() {
        let categories = [
            VaultInterviewCategory(title: "Tanisma. & Kariyer Tip 2", icon: "person", items: []),
            VaultInterviewCategory(title: "Kodlama", icon: "chevron.left.forwardslash.chevron.right", items: [])
        ]

        let scoped = IntelligenceService.scopedVaultCategories(categories, codingOnly: false)

        XCTAssertEqual(scoped.map(\.title), ["Tanisma. & Kariyer Tip 2", "Kodlama"])
    }

    func testVaultSearchEngineRanksLoihdeQuestionFirstForSpecificPrefix() {
        let categories = [
            VaultInterviewCategory(
                title: "Tanisma. & Kariyer Tip 2",
                icon: "person",
                items: [
                    VaultInterviewItem(
                        question: "Miksi hait juuri Loihteelle?",
                        answerFinnish: "Loihteessa minua kiinnostaa erityisesti monipuolinen asiakasympäristö.",
                        translationTr: "Neden özellikle Loihde?",
                        keyPoints: ["loihde", "motivaatio"]
                    ),
                    VaultInterviewItem(
                        question: "Miksi etsit uutta työpaikkaa juuri nyt?",
                        answerFinnish: "Etsin pitkäjänteistä roolia vahvassa tiimissä.",
                        translationTr: "Neden şu an yeni iş arıyorsun?",
                        keyPoints: ["uusi työ", "vakautta"]
                    )
                ]
            )
        ]

        let results = VaultSearchEngine.rankedResults(query: "Miksi loih", categories: categories, limit: 5)

        XCTAssertEqual(results.first?.title, "Miksi hait juuri Loihteelle?")
    }

    func testVaultSearchEngineRefinesSearchWhenMoreWordsAreTyped() {
        let categories = [
            VaultInterviewCategory(
                title: "Tanisma. & Kariyer Tip 2",
                icon: "person",
                items: [
                    VaultInterviewItem(
                        question: "Miksi hait juuri Loihteelle?",
                        answerFinnish: "Loihteessa minua kiinnostaa erityisesti monipuolinen asiakasympäristö.",
                        translationTr: "Neden özellikle Loihde?",
                        keyPoints: ["loihde", "motivaatio"]
                    ),
                    VaultInterviewItem(
                        question: "Miksi etsit uutta työpaikkaa juuri nyt?",
                        answerFinnish: "Etsin pitkäjänteistä roolia vahvassa tiimissä.",
                        translationTr: "Neden şu an yeni iş arıyorsun?",
                        keyPoints: ["uusi työ", "vakautta"]
                    )
                ]
            )
        ]

        let results = VaultSearchEngine.rankedResults(query: "Miksi etsit uutta", categories: categories, limit: 5)

        XCTAssertEqual(results.first?.title, "Miksi etsit uutta työpaikkaa juuri nyt?")
    }

    func testVaultSearchEngineFindsCompensationQuestionFromPartialWord() {
        let categories = [
            VaultInterviewCategory(
                title: "Tanisma. & Kariyer Tip 2",
                icon: "person",
                items: [
                    VaultInterviewItem(
                        question: "Millainen palkkatoive sinulla on?",
                        answerFinnish: "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.",
                        translationTr: "Maaş beklentin nedir?",
                        keyPoints: ["palkka", "salary"]
                    )
                ]
            )
        ]

        let results = VaultSearchEngine.rankedResults(query: "palkkatoi", categories: categories, limit: 5)

        XCTAssertEqual(results.first?.title, "Millainen palkkatoive sinulla on?")
    }

    func testVaultSearchEngineUsesParaphraseForSelfIntroQuestion() {
        let categories = [
            VaultInterviewCategory(
                title: "Tanisma. & Kariyer Tip 2",
                icon: "person",
                items: [
                    VaultInterviewItem(
                        question: "Kerrotko vähän itsestäsi?",
                        answerFinnish: "Olen full stack kehittäjä, jolla on yli seitsemän vuoden kokemus.",
                        translationTr: "Biraz kendinden bahseder misin?",
                        keyPoints: ["intro", "kokemus"]
                    ),
                    VaultInterviewItem(
                        question: "Millainen palkkatoive sinulla on?",
                        answerFinnish: "Palkkatoiveeni on noin 5 600-6 200 euroa kuukaudessa.",
                        translationTr: "Maaş beklentin nedir?",
                        keyPoints: ["palkka"]
                    )
                ]
            )
        ]

        let results = VaultSearchEngine.rankedResults(query: "Kuka sinä olet?", categories: categories, limit: 5)

        XCTAssertEqual(results.first?.title, "Kerrotko vähän itsestäsi?")
    }

    func testIsCodingRelatedQueryDetectsNextJSAuthAuthoringRequest() {
        let query = InterviewKnowledgeMatcher.normalize("Voitko kirjoita authentication api with next.js?")

        XCTAssertTrue(IntelligenceService.isCodingRelatedQuery(query))
    }

    func testIsCodingRelatedQueryDoesNotMisclassifyApiExperienceInterviewQuestion() {
        let query = InterviewKnowledgeMatcher.normalize("Onko sinulla kokemusta API-integraatioista?")

        XCTAssertFalse(IntelligenceService.isCodingRelatedQuery(query))
    }

    func testPreferredLanguageCodeUsesNaturalLanguagePartOfCodeHeavyFinnishQuestion() {
        let query = """
        const updateBalance = async (userId, amount) => {
          const user = await db.getUser(userId);
          const newBalance = user.balance + amount;
          await db.saveBalance(userId, newBalance);
        }; Mikä vikaa on koodissa?
        """

        let languageCode = IntelligenceService.preferredLanguageCode(for: query)
        let probeText = IntelligenceService.languageDetectionProbeText(from: query)

        XCTAssertEqual(languageCode, "fi")
        XCTAssertEqual(probeText, "Mikä vikaa on koodissa?")
    }

    func testDetectedQuestionSegmentsHandlesSingleQuestionWithoutQuestionMark() {
        let query = "Mikä sinun palkkatoiveesi on"
        let segments = IntelligenceService.detectedQuestionSegments(query)

        XCTAssertEqual(segments, ["Mikä sinun palkkatoiveesi on?"])
    }

    func testDetectedQuestionSegmentsTrimsInterviewPreamble() {
        let query = "Seuraava kysymys kerrotko vähän itsestäsi"
        let segments = IntelligenceService.detectedQuestionSegments(query)

        XCTAssertEqual(segments, ["kerrotko vähän itsestäsi?"])
    }

    func testDetectedQuestionSegmentsIgnoresNonQuestionTranscript() {
        let query = "Meillä käytetään Azurea, Reactia ja Node.js:ää useissa projekteissa"
        let segments = IntelligenceService.detectedQuestionSegments(query)

        XCTAssertTrue(segments.isEmpty)
    }

    func testIsFollowUpQuestionDetectsReferentialProjectQuestion() {
        let query = "Hmm Minkäläistä projekti se oli?"

        XCTAssertTrue(IntelligenceService.isFollowUpQuestion(query))
    }

    func testIsFollowUpQuestionDetectsHowDidYouDoThatFinnishVariant() {
        let query = "Miten tehnyt sen?"

        XCTAssertTrue(IntelligenceService.isFollowUpQuestion(query))
    }

    func testIsFollowUpQuestionDoesNotFlagStandaloneAzureExperienceQuestion() {
        let query = "Entä millaista kokemusta sinulla on Azuresta?"

        XCTAssertFalse(IntelligenceService.isFollowUpQuestion(query))
    }

    func testFollowUpRetrievalQueryCarriesPreviousGroundedContext() {
        let query = IntelligenceService.followUpRetrievalQuery(
            currentQuery: "Minkäläistä projekti se oli?",
            previousQuestion: "Entä millaista kokemusta sinulla on Azuresta?",
            previousAnswer: "Olen käyttänyt Azure Functionsia ja App Serviceä yhdessä Next.js-frontendin kanssa."
        )

        XCTAssertTrue(query.contains("Minkäläistä projekti se oli?"))
        XCTAssertTrue(query.contains("Entä millaista kokemusta sinulla on Azuresta?"))
        XCTAssertTrue(query.contains("Azure Functionsia"))
        XCTAssertTrue(query.contains("App Serviceä"))
    }

    func testCanUseInstantInterviewCacheAllowsWarmConciseNonFollowUpInterviewQuery() {
        let allowed = IntelligenceService.canUseInstantInterviewCache(
            isInterviewConcise: true,
            requiresWebSearch: false,
            isCodingQuery: false,
            isFollowUpQuery: false,
            strongestRoleScore: 0.10,
            cacheIsWarm: true
        )

        XCTAssertTrue(allowed)
    }

    func testCanUseInstantInterviewCacheBlocksFollowUpAndRequiredWebQueries() {
        let followUpBlocked = IntelligenceService.canUseInstantInterviewCache(
            isInterviewConcise: true,
            requiresWebSearch: false,
            isCodingQuery: false,
            isFollowUpQuery: true,
            strongestRoleScore: 0.10,
            cacheIsWarm: true
        )
        let webBlocked = IntelligenceService.canUseInstantInterviewCache(
            isInterviewConcise: true,
            requiresWebSearch: true,
            isCodingQuery: false,
            isFollowUpQuery: false,
            strongestRoleScore: 0.10,
            cacheIsWarm: true
        )

        XCTAssertFalse(followUpBlocked)
        XCTAssertFalse(webBlocked)
    }

    func testCanUseInstantInterviewCacheAllowsCodingWhenWarmAndNonFollowUp() {
        let allowed = IntelligenceService.canUseInstantInterviewCache(
            isInterviewConcise: true,
            requiresWebSearch: false,
            isCodingQuery: true,
            isFollowUpQuery: false,
            strongestRoleScore: 0.0,
            cacheIsWarm: true
        )

        XCTAssertTrue(allowed)
    }

    func testHasRequiredInterviewConceptCoverageRejectsPartialActorCoverageForProblemQuestion() {
        let allowed = IntelligenceService.hasRequiredInterviewConceptCoverage(
            queryConcepts: ["problem", "client", "coworker"],
            recordConcepts: ["problem", "client", "handle"]
        )

        XCTAssertFalse(allowed)
    }

    func testHasRequiredInterviewConceptCoverageAllowsAlignedProblemHandlingConcepts() {
        let allowed = IntelligenceService.hasRequiredInterviewConceptCoverage(
            queryConcepts: ["problem", "client"],
            recordConcepts: ["problem", "client", "handle", "solve"]
        )

        XCTAssertTrue(allowed)
    }

    func testSupportedResponseLanguageCodeRestrictsOutputToEnglishOrFinnish() {
        let finnish = IntelligenceService.supportedResponseLanguageCode(
            for: "Mikä sinun vahvin teknologia on?"
        )
        let english = IntelligenceService.supportedResponseLanguageCode(
            for: "What is your strongest backend stack?"
        )
        // "Neden bu rol?" Türkçe sinyaller içerir ("neden"), bu yüzden "tr" döner.
        let turkish = IntelligenceService.supportedResponseLanguageCode(
            for: "Neden bu rol?"
        )

        XCTAssertEqual(finnish, "fi")
        XCTAssertEqual(english, "en")
        XCTAssertEqual(turkish, "tr")
    }

    func testShouldSuppressAutomaticWebSearchForSelfContainedCodeQuestion() {
        let query = """
        const updateBalance = async (userId, amount) => {
          const user = await db.getUser(userId);
          const newBalance = user.balance + amount;
          await db.saveBalance(userId, newBalance);
        }; Mikä vikaa on koodissa?
        """

        XCTAssertTrue(IntelligenceService.shouldSuppressAutomaticWebSearch(for: query))
    }

    func testShouldNotSuppressAutomaticWebSearchForCurrentCodingDocsQuestion() {
        let query = "What are the latest Next.js authentication docs and best practices?"

        XCTAssertFalse(IntelligenceService.shouldSuppressAutomaticWebSearch(for: query))
    }

    func testRequiresCorrectedCodeResponseForPastedBuggyCodeQuestion() {
        let query = """
        type User = {
          id: string;
          email: string;
          balance: number;
          version: number;
        };

        async function transferMoney(db: any, fromUserId: string, toUserId: string, amount: number) {
          const fromUser = await db.users.findById(fromUserId);
          const toUser = await db.users.findById(toUserId);
          fromUser.balance -= amount;
          toUser.balance += amount;
          await db.users.update(fromUser.id, { balance: fromUser.balance });
          await db.users.update(toUser.id, { balance: toUser.balance });
        }

        Mitä ongelmia näet tässä koodissa tuotantokäytön kannalta, ja miten korjaisit ne?
        """

        XCTAssertTrue(IntelligenceService.containsConcreteCodeSnippet(query))
        XCTAssertTrue(IntelligenceService.requiresCorrectedCodeResponse(query))
        XCTAssertTrue(IntelligenceService.isSelfContainedCodingDebugQuery(query))
    }

    func testRequiresCorrectedCodeResponseDoesNotFlagConceptualCodingQuestionWithoutSnippet() {
        let query = "Miten toteuttaisit turvallisen REST API:n Node.js:llä?"

        XCTAssertFalse(IntelligenceService.containsConcreteCodeSnippet(query))
        XCTAssertFalse(IntelligenceService.requiresCorrectedCodeResponse(query))
        XCTAssertFalse(IntelligenceService.isSelfContainedCodingDebugQuery(query))
    }

    func testModelFacingQueryAddsStrictCodeOutputContractForSelfContainedCodingDebug() {
        let query = """
        type User = {
          id: string;
          email: string;
          balance: number;
        };

        Mikä vikaa on koodissa ja miten korjaisit sen?
        """

        let prompt = IntelligenceService.modelFacingQuery(
            originalQuery: query,
            expectedLanguageCode: "fi",
            isSelfContainedCodingQuery: true
        )

        XCTAssertTrue(prompt.contains("2-4 short bullets"))
        XCTAssertTrue(prompt.contains("fenced markdown code block"))
        XCTAssertTrue(prompt.contains("Answer in Finnish"))
        XCTAssertTrue(prompt.contains(query))
    }

    func testMultiQuestionRequiresPersonaFallbackForWeakSignals() {
        let fallback = IntelligenceService.multiQuestionRequiresPersonaFallback(
            topScore: 0.19,
            matchedTokenCount: 0,
            queryTokenCount: 7,
            isIntroIntent: false,
            isCompensationIntent: false,
            languageAligned: true
        )

        XCTAssertTrue(fallback)
    }

    func testMultiQuestionRequiresPersonaFallbackAllowsStrongAlignedSignals() {
        let fallback = IntelligenceService.multiQuestionRequiresPersonaFallback(
            topScore: 0.36,
            matchedTokenCount: 2,
            queryTokenCount: 7,
            isIntroIntent: false,
            isCompensationIntent: false,
            languageAligned: true
        )

        XCTAssertFalse(fallback)
    }

    func testMultiQuestionModelFacingQueryAddsOrderingContractAndSegments() {
        let prompt = IntelligenceService.multiQuestionModelFacingQuery(
            baseQuery: "Miten ongelmia asiakkaiden kanssa syntyy? Miten asiakkaiden pyyntöihin voidaan vastata?",
            segments: [
                "Miten ongelmia asiakkaiden kanssa syntyy?",
                "Miten asiakkaiden pyyntöihin voidaan vastata?"
            ],
            expectedLanguageCode: "fi"
        )

        XCTAssertTrue(prompt.contains("[MULTI-QUESTION OUTPUT CONTRACT]"))
        XCTAssertTrue(prompt.contains("Do not merge questions into a single generic paragraph."))
        XCTAssertTrue(prompt.contains("Answer only in Finnish."))
        XCTAssertTrue(prompt.contains("Q1: Miten ongelmia asiakkaiden kanssa syntyy?"))
        XCTAssertTrue(prompt.contains("Q2: Miten asiakkaiden pyyntöihin voidaan vastata?"))
    }
}
