import Foundation
import os

/// RAG için sohbet geçmişini kalıcı hale getiren ve alan hizmet.
actor ChatHistoryService {
    private let vectorStore: VectorStore
    private let documentProcessor: DocumentProcessor
    private let embeddingService: OllamaEmbeddingService
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "ChatHistory")
    
    private var currentSessionID: String
    private var conversationBuffer: [String] = []
    private let bufferSize = 2 // Hızlı kaydet (kullanıcı+asistan ikilisi) böylece RAG erken aktif olur
    
    init(vectorStore: VectorStore, documentProcessor: DocumentProcessor, embeddingService: OllamaEmbeddingService) {
        self.vectorStore = vectorStore
        self.documentProcessor = documentProcessor
        self.embeddingService = embeddingService
        self.currentSessionID = "session_\(UUID().uuidString.prefix(8))"
    }
    
    // MARK: - Mesajları Kaydet
    
    /// Sohbet tamponuna bir mesaj ekler.
    func addMessage(text: String, isUser: Bool) async throws {
        let prefix = isUser ? "USER: " : "AI: "
        let message = "\(prefix)\(text)"
        
        conversationBuffer.append(message)
        logger.info("📝 Message added to buffer (\(self.conversationBuffer.count)/\(self.bufferSize))")
        
        // Tampon kapasiteye ulaştığında boşalt
        if conversationBuffer.count >= bufferSize {
            try await flushBuffer()
        }
    }
    
    /// Sohbet tamponunu vektör deposuna boşaltır.
    func flushBuffer() async throws {
        guard !conversationBuffer.isEmpty else { return }
        
        logger.info("💾 Flushing \(self.conversationBuffer.count) messages to vector store...")
        
        // Sohbet mesajlarını parçalara işle
        let chunks = await documentProcessor.processChatHistory(
            messages: conversationBuffer,
            sessionID: currentSessionID
        )
        
        // Embedding üret ve ekle
        for chunk in chunks {
            let embedding = try await embeddingService.embedSingle(text: chunk.text)
            try await vectorStore.insert(chunk: chunk, embedding: embedding)
        }
        
        logger.info("✅ Saved \(chunks.count) chunks from chat history")
        
        // Tamponu temizle
        conversationBuffer.removeAll()
    }
    
    /// Yeni bir sohbet oturumu başlatır.
    func startNewSession() {
        currentSessionID = "session_\(UUID().uuidString.prefix(8))_\(Date().timeIntervalSince1970)"
        conversationBuffer.removeAll()
        logger.info("🆕 Started new session: \(self.currentSessionID)")
    }
    
    /// Mevcut tamponu elle kaydeder (örn. uygulama kapanışında)
    func saveAndClose() async throws {
        try await flushBuffer()
        logger.info("💾 Chat history saved on close")
    }
}
