import Foundation

/// LLM kapısı için modele yönelik prompt dizilerini oluşturur.
///
/// Orkestrasyon dosyasını kontrol akışına odaklı tutmak için `IntelligenceService`'ten
/// çıkarıldı. Bunlar saf, durumsuz dize oluşturuculardır ve örnek durumuna dokunmazlar,
/// bu yüzden bağımsız yaşayabilirler.
enum LLMPromptBuilder {
    nonisolated static func modelFacingQuery(
        originalQuery: String,
        expectedLanguageCode: String?,
        isSelfContainedCodingQuery: Bool
    ) -> String {
        guard isSelfContainedCodingQuery else { return originalQuery }

        let languageName: String = {
            switch expectedLanguageCode?.lowercased() {
            case "tr", "turkish":
                return "Turkish"
            case "fi", "finnish":
                return "Finnish"
            case "en", "english":
                return "English"
            default:
                return "the user's language"
            }
        }()

        return """
        Review the pasted code and answer the user's debugging question directly.

        Required output format:
        - Start with 2-4 short bullets naming the main production risks.
        - Then provide the corrected code in a fenced markdown code block.
        - End with 1-2 short sentences explaining why the corrected version is safer.
        - Answer in \(languageName).
        - Do not omit the code block.
        - Keep comments brief and useful.

        USER QUESTION:
        \(originalQuery)
        """
    }

    nonisolated static func multiQuestionModelFacingQuery(
        baseQuery: String,
        segments: [String],
        expectedLanguageCode: String?
    ) -> String {
        guard segments.count >= 2 else { return baseQuery }

        let languageInstruction: String = {
            switch expectedLanguageCode?.lowercased() {
            case "fi", "finnish":
                return "Answer only in Finnish."
            case "en", "english":
                return "Answer only in English."
            default:
                return "Answer in the same language as the user's message."
            }
        }()

        let segmentLines = segments.enumerated().map { index, segment in
            "Q\(index + 1): \(segment)"
        }.joined(separator: "\n")

        return """
        \(baseQuery)

        [MULTI-QUESTION OUTPUT CONTRACT]
        - You must answer all \(segments.count) questions in order.
        - Use one short paragraph per question.
        - Do not merge questions into a single generic paragraph.
        - If [Qx FALLBACK REQUIRED] appears in context, generate that segment from [ACTIVE ROLE GROUNDING] and [USER PERSONA].
        - \(languageInstruction)

        [DETECTED QUESTIONS]
        \(segmentLines)
        """
    }
}
