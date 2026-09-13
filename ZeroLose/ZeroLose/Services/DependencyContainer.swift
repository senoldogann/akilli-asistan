import Foundation

@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    // Core model and data services.
    let groqService: GroqService
    let tavilyService: TavilyService
    let visionService: VisionService
    let clipboardService: ClipboardService
    let screenshotWatcher: ScreenshotWatcherService
    let audioService: AudioService
    let systemStatusService: SystemStatusService

    // Conversation and document services.
    let vectorStore: VectorStore
    let embeddingService: OllamaEmbeddingService
    let documentProcessor: DocumentProcessor
    let chatHistoryService: ChatHistoryService

    private init() {
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
        let chatHistoryService = ChatHistoryService(
            vectorStore: vectorStore,
            documentProcessor: documentProcessor,
            embeddingService: embeddingService
        )

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
        self.chatHistoryService = chatHistoryService
    }
}
