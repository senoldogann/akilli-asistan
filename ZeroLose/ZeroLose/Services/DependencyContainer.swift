import Foundation

class DependencyContainer {
    static let shared = DependencyContainer()
    
    // Core Services
    let ollamaService: OllamaService
    let groqService: GroqService
    let tavilyService = TavilyService()
    let visionService = VisionService()
    
    // RAG Services
    let vectorStore: VectorStore
    let embeddingService: OllamaEmbeddingService
    let documentProcessor: DocumentProcessor
    let semanticRetriever: SemanticRetriever
    let chatHistoryService: ChatHistoryService
    let screenshotWatcher: ScreenshotWatcherService
    let audioService: AudioService
    let intelligenceService: IntelligenceService
    let zeroOperator = ZeroOperator()
    let systemStatusService = SystemStatusService()
    
    // ViewModel (Singleton)
    let ghostViewModel: GhostViewModel
    
    private init() {
        // Init low-level services
        let ollama = OllamaService()
        let groqAPIKey = Secrets.groqApiKey // Assuming Secrets.groqApiKey is still used
        let groq = GroqService(apiKey: groqAPIKey)
        let clipboard = ClipboardService() // Still needed for ViewModel
        let watcher = ScreenshotWatcherService()
        
        // Init high-level services
        let audio = AudioService(groqService: groq)
        
        self.ollamaService = ollama
        self.groqService = groq
        self.screenshotWatcher = watcher
        self.audioService = audio
        
        // Initialize RAG Components
        self.vectorStore = VectorStore()
        self.embeddingService = OllamaEmbeddingService()
        self.documentProcessor = DocumentProcessor()
        self.semanticRetriever = SemanticRetriever(vectorStore: vectorStore, embeddingService: embeddingService)
        self.chatHistoryService = ChatHistoryService(vectorStore: vectorStore, documentProcessor: documentProcessor, embeddingService: embeddingService)
        
        // Initialize Intelligence Service with RAG
        self.intelligenceService = IntelligenceService(
            ollamaService: ollamaService,
            tavilyService: tavilyService,
            semanticRetriever: semanticRetriever,
            chatHistoryService: chatHistoryService,
            systemStatusService: systemStatusService
        )
        
        // Initialize ViewModel
        self.ghostViewModel = GhostViewModel(
            ollamaService: ollama,
            visionService: visionService,
            clipboardService: clipboard,
            screenshotWatcher: watcher,
            audioService: audio,
            intelligenceService: intelligenceService,
            documentProcessor: documentProcessor,
            embeddingService: embeddingService,
            vectorStore: vectorStore,
            zeroOperator: zeroOperator,
            chatHistoryService: chatHistoryService
        )
    }
}
