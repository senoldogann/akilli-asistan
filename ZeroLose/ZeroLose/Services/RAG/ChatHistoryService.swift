import Foundation
import os

/// Service for persisting and retrieving chat history for RAG
actor ChatHistoryService {
    private let vectorStore: VectorStore
    private let documentProcessor: DocumentProcessor
    private let embeddingService: OllamaEmbeddingService
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "ChatHistory")
    
    private var currentSessionID: String
    private var conversationBuffer: [String] = []
    private let bufferSize = 2 // Save quickly (user+assistant pair) so RAG becomes active early
    
    init(vectorStore: VectorStore, documentProcessor: DocumentProcessor, embeddingService: OllamaEmbeddingService) {
        self.vectorStore = vectorStore
        self.documentProcessor = documentProcessor
        self.embeddingService = embeddingService
        self.currentSessionID = "session_\(UUID().uuidString.prefix(8))"
    }
    
    // MARK: - Save Messages
    
    /// Add a message to the conversation buffer
    func addMessage(text: String, isUser: Bool) async throws {
        let prefix = isUser ? "USER: " : "AI: "
        let message = "\(prefix)\(text)"
        
        conversationBuffer.append(message)
        logger.info("📝 Message added to buffer (\(self.conversationBuffer.count)/\(self.bufferSize))")
        
        // Flush buffer when it reaches capacity
        if conversationBuffer.count >= bufferSize {
            try await flushBuffer()
        }
    }
    
    /// Flush the conversation buffer to vector store
    func flushBuffer() async throws {
        guard !conversationBuffer.isEmpty else { return }
        
        logger.info("💾 Flushing \(self.conversationBuffer.count) messages to vector store...")
        
        // Process chat messages into chunks
        let chunks = await documentProcessor.processChatHistory(
            messages: conversationBuffer,
            sessionID: currentSessionID
        )
        
        // Generate embeddings and insert
        for chunk in chunks {
            let embedding = try await embeddingService.embedSingle(text: chunk.text)
            try await vectorStore.insert(chunk: chunk, embedding: embedding)
        }
        
        logger.info("✅ Saved \(chunks.count) chunks from chat history")
        
        // Clear buffer
        conversationBuffer.removeAll()
    }
    
    /// Start a new conversation session
    func startNewSession() {
        currentSessionID = "session_\(UUID().uuidString.prefix(8))_\(Date().timeIntervalSince1970)"
        conversationBuffer.removeAll()
        logger.info("🆕 Started new session: \(self.currentSessionID)")
    }
    
    /// Manually save current buffer (e.g., on app termination)
    func saveAndClose() async throws {
        try await flushBuffer()
        logger.info("💾 Chat history saved on close")
    }
}
