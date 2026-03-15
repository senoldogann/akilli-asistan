import Foundation

// 🛡️ SECURITY NOTICE: Treat this file with care.
// In a real production app, fetch this from a secure server or Build Settings.

enum AIModelNames: Sendable {
    nonisolated private static let openAIVisionModel = "gpt-5-mini"
    nonisolated private static let openAIReasoningModel = "gpt-5-mini"
    nonisolated private static let openAICodingModel = "gpt-5.2-codex"
    nonisolated private static let openAIFastModel = "gpt-4o-mini"
    nonisolated private static let openAITranscriptionModel = "gpt-4o-mini-transcribe"

    nonisolated private static let legacyVisionModel = "gemini-3-flash-preview:cloud"
    nonisolated private static let legacyReasoningModel = "gemini-3-flash-preview:cloud"
    nonisolated private static let legacyCodingModel = "gemini-3-flash-preview:cloud"
    nonisolated private static let legacyFastModel = "ministral-3:14b-cloud"
    nonisolated private static let legacyTranscriptionModel = "whisper-large-v3-turbo"

    nonisolated static var vision: String {
        vision(preferOpenAI: Secrets.isOpenAIKeyValid)
    }

    nonisolated static var reasoning: String {
        reasoning(preferOpenAI: Secrets.isOpenAIKeyValid)
    }

    nonisolated static var coding: String {
        coding(preferOpenAI: Secrets.isOpenAIKeyValid)
    }

    nonisolated static var fast: String {
        fast(preferOpenAI: Secrets.isOpenAIKeyValid)
    }

    nonisolated static var whisper: String {
        whisper(preferOpenAI: Secrets.isOpenAIKeyValid)
    }

    nonisolated static func vision(preferOpenAI: Bool) -> String {
        preferOpenAI ? openAIVisionModel : legacyVisionModel
    }

    nonisolated static func reasoning(preferOpenAI: Bool) -> String {
        preferOpenAI ? openAIReasoningModel : legacyReasoningModel
    }

    nonisolated static func coding(preferOpenAI: Bool) -> String {
        preferOpenAI ? openAICodingModel : legacyCodingModel
    }

    nonisolated static func fast(preferOpenAI: Bool) -> String {
        preferOpenAI ? openAIFastModel : legacyFastModel
    }

    nonisolated static func whisper(preferOpenAI: Bool) -> String {
        preferOpenAI ? openAITranscriptionModel : legacyTranscriptionModel
    }

    nonisolated static func prefersOpenAI() -> Bool {
        Secrets.isOpenAIKeyValid
    }
}
