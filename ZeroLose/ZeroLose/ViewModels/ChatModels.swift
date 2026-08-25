import Foundation

// MARK: - Chat History Models

struct ChatMessage: Identifiable, Sendable {
    enum AssistantOrigin: Sendable {
        case system
        case cache
        case groundedFastPath
        case aiGenerated
    }

    /// Ajanın çalıştırdığı bir aracın (komut) sohbette görünür kart bilgisi.
    /// `nil` ise bu mesaj normal bir metin mesajıdır. Dolu ise `aiBubble`
    /// bir "komut kartı" render eder (çalışıyor / başarılı / hata + çıktı).
    struct ToolRun: Sendable, Equatable {
        enum Status: Sendable, Equatable {
            case running
            case done
            case error(String)
        }

        let kind: String          // "shell", "file", "web_search", "applescript"...
        let command: String       // görüntülenen komut/eylem özeti
        let status: Status
        let output: String
    }

    let id: UUID
    let text: String
    let isUser: Bool
    let type: MessageType
    let assistantOrigin: AssistantOrigin?
    let relatedQuery: String?
    let thinking: String?
    let toolRun: ToolRun?

    enum MessageType: Sendable {
        case text
        case image
        case error
        case thinking
    }

    let imageData: Data?

    var allowsAIRefinement: Bool {
        guard !isUser else { return false }
        guard let relatedQuery, !relatedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let assistantOrigin else { return false }
        switch assistantOrigin {
        case .cache, .groundedFastPath:
            return true
        case .system, .aiGenerated:
            return false
        }
    }

    var assistantBadgeText: String? {
        switch assistantOrigin {
        case .cache:
            return "CACHE"
        case .groundedFastPath:
            return "FAST"
        default:
            return nil
        }
    }

    init(
        id: UUID = UUID(),
        text: String,
        isUser: Bool,
        type: MessageType,
        imageData: Data? = nil,
        assistantOrigin: AssistantOrigin? = nil,
        relatedQuery: String? = nil,
        thinking: String? = nil,
        toolRun: ToolRun? = nil
    ) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.type = type
        self.imageData = imageData
        self.assistantOrigin = assistantOrigin
        self.relatedQuery = relatedQuery
        self.thinking = thinking
        self.toolRun = toolRun
    }
}

/// İşlenmeyi bekleyen bir sorguyu temsil eder.
enum PendingQuery: Sendable {
    case text(
        query: String,
        source: String,
        language: String? = nil,
        webSearchMode: WebSearchMode = .automatic,
        allowAgentActions: Bool = false,
        processingMode: IntelligenceService.ProcessingMode = .automatic,
        showUserMessage: Bool = true,
        targetAssistantMessageID: UUID? = nil
    )
    case vision(data: Data, source: String, query: String?)
}

/// Giriş alanında gösterilen hafif bağlam penceresi kullanım tahmini.
/// Her sağlayıcı tam token sayılarını sunmaz, bu yüzden UI görünür sohbetten
/// deterministik bir tahmin türetir. Faturalama derecesinde bir token sayacı
/// değil, göreli bir doluluk göstergesi olarak tasarlanmıştır.
struct ContextUsage: Sendable, Equatable {
    let usedTokens: Int
    let windowTokens: Int

    var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(1.0, Double(usedTokens) / Double(windowTokens))
    }

    var percentText: String {
        let pct = Int((fraction * 100).rounded())
        return "%\(pct)"
    }
}
