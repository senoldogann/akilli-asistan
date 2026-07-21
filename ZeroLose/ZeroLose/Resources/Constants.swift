import Foundation

// 🛡️ SECURITY NOTICE: Treat this file with care.
// In a real production app, fetch this from a secure server or Build Settings.

enum AIModelNames: Sendable {
    nonisolated private static let openAIVisionModel = "gpt-5-mini"
    nonisolated private static let openAIReasoningModel = "gpt-5-mini"
    nonisolated private static let openAICodingModel = "gpt-5.2-codex"
    nonisolated private static let openAIFastModel = "gpt-4o-mini"
    nonisolated private static let openAITranscriptionModel = "gpt-4o-mini-transcribe"

    nonisolated private static let legacyVisionModel = "gemma2:9b-cloud"
    nonisolated private static let legacyReasoningModel = "llama3.1:8b-cloud"
    nonisolated private static let legacyCodingModel = "qwen2.5-coder:7b-cloud"
    nonisolated private static let legacyFastModel = "qwen2.5:7b-cloud"
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
        if preferOpenAI {
            return UserDefaults.standard.string(forKey: "customOpenAIVisionModel") ?? openAIVisionModel
        } else {
            return UserDefaults.standard.string(forKey: "customOllamaVisionModel") ?? legacyVisionModel
        }
    }

    nonisolated static func reasoning(preferOpenAI: Bool) -> String {
        if preferOpenAI {
            return UserDefaults.standard.string(forKey: "customOpenAIReasoningModel") ?? openAIReasoningModel
        } else {
            return UserDefaults.standard.string(forKey: "customOllamaReasoningModel") ?? legacyReasoningModel
        }
    }

    nonisolated static func coding(preferOpenAI: Bool) -> String {
        if preferOpenAI {
            return UserDefaults.standard.string(forKey: "customOpenAICodingModel") ?? openAICodingModel
        } else {
            return UserDefaults.standard.string(forKey: "customOllamaCodingModel") ?? legacyCodingModel
        }
    }

    nonisolated static func fast(preferOpenAI: Bool) -> String {
        if preferOpenAI {
            return UserDefaults.standard.string(forKey: "customOpenAIFastModel") ?? openAIFastModel
        } else {
            return UserDefaults.standard.string(forKey: "customOllamaFastModel") ?? legacyFastModel
        }
    }

    nonisolated static func whisper(preferOpenAI: Bool) -> String {
        if preferOpenAI {
            return UserDefaults.standard.string(forKey: "customOpenAIWhisperModel") ?? openAITranscriptionModel
        } else {
            return UserDefaults.standard.string(forKey: "customOllamaWhisperModel") ?? legacyTranscriptionModel
        }
    }

    nonisolated static func prefersOpenAI() -> Bool {
        Secrets.isOpenAIKeyValid
    }
}
