import Foundation

@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    // Core model and data services.
    let ollamaService: OllamaService
    let groqService: GroqService
    let tavilyService: TavilyService
    let visionService: VisionService
    let clipboardService: ClipboardService
    let screenshotWatcher: ScreenshotWatcherService
    let audioService: AudioService
    let systemStatusService: SystemStatusService

    // RAG and conversation services.
    let vectorStore: VectorStore
    let embeddingService: OllamaEmbeddingService
    let documentProcessor: DocumentProcessor
    let semanticRetriever: SemanticRetriever
    let chatHistoryService: ChatHistoryService
    let intelligenceService: IntelligenceService

    private init() {
        let ollama = OllamaService()
        let groq = GroqService(apiKey: Secrets.groqApiKey)
        let tavily = TavilyService()
        let vision = VisionService()
        let clipboard = ClipboardService()
        let watcher = ScreenshotWatcherService()
        let audio = AudioService(groqService: groq)
        let systemStatus = SystemStatusService()

        let vectorStore = VectorStore()
        let embeddingService = OllamaEmbeddingService()
        let documentProcessor = DocumentProcessor()
        let semanticRetriever = SemanticRetriever(
            vectorStore: vectorStore,
            embeddingService: embeddingService
        )
        let chatHistoryService = ChatHistoryService(
            vectorStore: vectorStore,
            documentProcessor: documentProcessor,
            embeddingService: embeddingService
        )
        let intelligenceService = IntelligenceService(
            ollamaService: ollama,
            tavilyService: tavily,
            semanticRetriever: semanticRetriever,
            chatHistoryService: chatHistoryService,
            systemStatusService: systemStatus
        )

        self.ollamaService = ollama
        self.groqService = groq
        self.tavilyService = tavily
        self.visionService = vision
        self.clipboardService = clipboard
        self.screenshotWatcher = watcher
        self.audioService = audio
        self.systemStatusService = systemStatus
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.documentProcessor = documentProcessor
        self.semanticRetriever = semanticRetriever
        self.chatHistoryService = chatHistoryService
        self.intelligenceService = intelligenceService
    }
}
