import Foundation

// 🛡️ SECURITY NOTICE: Treat this file with care.
// In a real production app, fetch this from a secure server or Build Settings.

enum LLMProvider: String, Sendable, CaseIterable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case openCodeZen = "opencode_zen"
    case openCodeGo = "opencode_go"
    case ollama = "ollama"

    nonisolated var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .openCodeZen: return "OpenCode Zen"
        case .openCodeGo: return "OpenCode Go"
        case .ollama: return "Ollama Cloud"
        }
    }
}

enum AIModelNames: Sendable {
    nonisolated private static let providerKey = "llm_provider"

    internal nonisolated static var providerStorageKey: String { providerKey }

    nonisolated private static let openAIVisionModel = "gpt-5-mini"
    nonisolated private static let openAIReasoningModel = "gpt-5-mini"
    nonisolated private static let openAICodingModel = "gpt-5.2-codex"
    nonisolated private static let openAIFastModel = "gpt-4o-mini"
    nonisolated private static let openAITranscriptionModel = "gpt-4o-mini-transcribe"

    nonisolated private static let deepSeekVisionModel = "deepseek-v4-flash-vision-exp"
    nonisolated private static let deepSeekReasoningModel = "deepseek-v4-pro"
    nonisolated private static let deepSeekCodingModel = "deepseek-v4-pro"
    nonisolated private static let deepSeekFastModel = "deepseek-v4-flash"

    // OpenCode hosts its own model catalog (verified live via /v1/models).
    // Defaults must be real OpenCode IDs, NOT DeepSeek aliases.
    nonisolated private static let openCodeZenReasoningModel = "claude-sonnet-5"
    nonisolated private static let openCodeZenCodingModel = "gpt-5.2-codex"
    nonisolated private static let openCodeZenFastModel = "gpt-5.6-luna"
    nonisolated private static let openCodeZenVisionModel = "gemini-3.5-flash"

    nonisolated private static let openCodeGoReasoningModel = "glm-5.2"
    nonisolated private static let openCodeGoCodingModel = "kimi-k2.7-code"
    nonisolated private static let openCodeGoFastModel = "qwen3.6-plus"
    nonisolated private static let openCodeGoVisionModel = "deepseek-v4-flash-vision-exp"

    // Live-verified OpenCode catalog (fetched from /v1/models on 2026-08-25).
    // Used as the source of truth for the model picker and as the fallback when
    // the /v1/models endpoint is unreachable (e.g. Cloudflare 403 for non-browser UA).
    nonisolated static let openCodeZenCatalog: [String] = [
        "big-pickle",
        "claude-fable-5",
        "claude-opus-4-6",
        "claude-opus-4-7",
        "claude-opus-4-8",
        "claude-opus-5",
        "claude-sonnet-4-6",
        "claude-sonnet-5",
        "deepseek-v4-flash",
        "deepseek-v4-flash-free",
        "deepseek-v4-pro",
        "gemini-3-flash",
        "gemini-3.1-pro",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.6-flash",
        "gemini-3.7-flash",
        "glm-5",
        "glm-5.1",
        "glm-5.2",
        "gpt-5",
        "gpt-5-codex",
        "gpt-5-nano",
        "gpt-5.1",
        "gpt-5.1-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex-mini",
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.4-pro",
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-5.6-luna",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "grok-4.5",
        "grok-4.6",
        "grok-build-0.1",
        "hy3-free",
        "kimi-k2.5",
        "kimi-k2.6",
        "kimi-k2.7-code",
        "kimi-k3",
        "laguna-s-2.1-free",
        "mimo-v2.5-free",
        "minimax-m2.5",
        "minimax-m2.7",
        "minimax-m3",
        "muse-spark-1.2",
        "muse-spark-1.2-contributor-free",
        "nemotron-3-ultra-free",
        "nemotron-3.5-lightning-free",
        "qwen3.5-plus",
        "qwen3.6-plus",
        "x-preview-f-free"
    ].sorted()

    nonisolated static let openCodeGoCatalog: [String] = [
        "deepseek-v4-flash",
        "deepseek-v4-flash-vision-exp",
        "deepseek-v4-pro",
        "glm-5",
        "glm-5.1",
        "glm-5.2",
        "glm-5.3",
        "gpt-5.6-luna",
        "grok-4.5",
        "hy3",
        "hy3-preview",
        "kimi-k2.5",
        "kimi-k2.6",
        "kimi-k2.7-code",
        "kimi-k3",
        "longcat-2.0",
        "mimo-v2-omni",
        "mimo-v2-pro",
        "mimo-v2.5",
        "mimo-v2.5-pro",
        "minimax-m2.5",
        "minimax-m2.7",
        "minimax-m3",
        "muse-spark-1.2-contributor",
        "ox-alpha-free",
        "qwen3.5-plus",
        "qwen3.6-plus",
        "qwen3.7-max",
        "qwen3.7-plus",
        "qwen3.8-max"
    ].sorted()

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
        vision(forProvider: currentProvider())
    }

    nonisolated static func reasoning(preferOpenAI: Bool) -> String {
        reasoning(forProvider: currentProvider())
    }

    nonisolated static func coding(preferOpenAI: Bool) -> String {
        coding(forProvider: currentProvider())
    }

    nonisolated static func fast(preferOpenAI: Bool) -> String {
        fast(forProvider: currentProvider())
    }

    nonisolated static func whisper(preferOpenAI: Bool) -> String {
        whisper(forProvider: currentProvider())
    }

    // MARK: - Provider-based selection

    nonisolated static func currentProvider() -> LLMProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? LLMProvider.ollama.rawValue
        let preferred = LLMProvider(rawValue: raw) ?? .ollama
        switch preferred {
        case .openAI:
            return Secrets.isOpenAIKeyValid ? .openAI : fallbackProvider()
        case .deepSeek:
            return Secrets.isDeepSeekKeyValid ? .deepSeek : fallbackProvider()
        case .openCodeZen:
            return Secrets.isOpenCodeZenKeyValid ? .openCodeZen : fallbackProvider()
        case .openCodeGo:
            return Secrets.isOpenCodeGoKeyValid ? .openCodeGo : fallbackProvider()
        case .ollama:
            return .ollama
        }
    }

    /// Conservative context-window size (tokens) for the active provider.
    /// These are safe lower bounds used only by the UI fullness meter; the real
    /// model-specific window may be larger. Keeping a provider-level value means
    /// the meter reflects the actual conversation budget instead of a hardcoded
    /// 128k that under-reports on small-window models.
    nonisolated static func contextWindow(forProvider provider: LLMProvider) -> Int {
        switch provider {
        case .openAI:
            return 128_000
        case .deepSeek:
            return 128_000
        case .openCodeZen:
            return 200_000
        case .openCodeGo:
            return 200_000
        case .ollama:
            return 128_000
        }
    }

    private nonisolated static func fallbackProvider() -> LLMProvider {
        if Secrets.isOpenAIKeyValid { return .openAI }
        if Secrets.isDeepSeekKeyValid { return .deepSeek }
        if Secrets.isOpenCodeZenKeyValid { return .openCodeZen }
        if Secrets.isOpenCodeGoKeyValid { return .openCodeGo }
        return .ollama
    }

    nonisolated static func vision(forProvider provider: LLMProvider) -> String {
        switch provider {
        case .openAI: return UserDefaults.standard.string(forKey: "customOpenAIVisionModel") ?? openAIVisionModel
        case .deepSeek: return UserDefaults.standard.string(forKey: "customDeepSeekVisionModel") ?? deepSeekVisionModel
        case .openCodeZen: return UserDefaults.standard.string(forKey: "customOpenCodeZenVisionModel") ?? openCodeZenVisionModel
        case .openCodeGo: return UserDefaults.standard.string(forKey: "customOpenCodeGoVisionModel") ?? openCodeGoVisionModel
        case .ollama: return UserDefaults.standard.string(forKey: "customOllamaVisionModel") ?? legacyVisionModel
        }
    }

    nonisolated static func reasoning(forProvider provider: LLMProvider) -> String {
        switch provider {
        case .openAI: return UserDefaults.standard.string(forKey: "customOpenAIReasoningModel") ?? openAIReasoningModel
        case .deepSeek: return UserDefaults.standard.string(forKey: "customDeepSeekReasoningModel") ?? deepSeekReasoningModel
        case .openCodeZen: return UserDefaults.standard.string(forKey: "customOpenCodeZenReasoningModel") ?? openCodeZenReasoningModel
        case .openCodeGo: return UserDefaults.standard.string(forKey: "customOpenCodeGoReasoningModel") ?? openCodeGoReasoningModel
        case .ollama: return UserDefaults.standard.string(forKey: "customOllamaReasoningModel") ?? legacyReasoningModel
        }
    }

    nonisolated static func coding(forProvider provider: LLMProvider) -> String {
        switch provider {
        case .openAI: return UserDefaults.standard.string(forKey: "customOpenAICodingModel") ?? openAICodingModel
        case .deepSeek: return UserDefaults.standard.string(forKey: "customDeepSeekCodingModel") ?? deepSeekCodingModel
        case .openCodeZen: return UserDefaults.standard.string(forKey: "customOpenCodeZenCodingModel") ?? openCodeZenCodingModel
        case .openCodeGo: return UserDefaults.standard.string(forKey: "customOpenCodeGoCodingModel") ?? openCodeGoCodingModel
        case .ollama: return UserDefaults.standard.string(forKey: "customOllamaCodingModel") ?? legacyCodingModel
        }
    }

    nonisolated static func fast(forProvider provider: LLMProvider) -> String {
        switch provider {
        case .openAI: return UserDefaults.standard.string(forKey: "customOpenAIFastModel") ?? openAIFastModel
        case .deepSeek: return UserDefaults.standard.string(forKey: "customDeepSeekFastModel") ?? deepSeekFastModel
        case .openCodeZen: return UserDefaults.standard.string(forKey: "customOpenCodeZenFastModel") ?? openCodeZenFastModel
        case .openCodeGo: return UserDefaults.standard.string(forKey: "customOpenCodeGoFastModel") ?? openCodeGoFastModel
        case .ollama: return UserDefaults.standard.string(forKey: "customOllamaFastModel") ?? legacyFastModel
        }
    }

    nonisolated static func whisper(forProvider provider: LLMProvider) -> String {
        switch provider {
        case .openAI: return UserDefaults.standard.string(forKey: "customOpenAIWhisperModel") ?? openAITranscriptionModel
        case .deepSeek: return UserDefaults.standard.string(forKey: "customDeepSeekWhisperModel") ?? deepSeekVisionModel
        case .openCodeZen: return UserDefaults.standard.string(forKey: "customOpenCodeZenWhisperModel") ?? openCodeZenVisionModel
        case .openCodeGo: return UserDefaults.standard.string(forKey: "customOpenCodeGoWhisperModel") ?? openCodeGoVisionModel
        case .ollama: return UserDefaults.standard.string(forKey: "customOllamaWhisperModel") ?? legacyTranscriptionModel
        }
    }

    nonisolated static func activeProviderDisplay() -> String {
        currentProvider().displayName
    }

    nonisolated static func prefersOpenAI() -> Bool {
        Secrets.isOpenAIKeyValid
    }

    nonisolated static func prefersDeepSeek() -> Bool {
        Secrets.isDeepSeekKeyValid
    }
}
