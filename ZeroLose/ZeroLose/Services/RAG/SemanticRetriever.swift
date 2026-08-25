import Foundation
import os

/// RAG için vektör deposundan ilgili bağlamı alır.
actor SemanticRetriever {
    private let vectorStore: VectorStore
    private let embeddingService: OllamaEmbeddingService
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "SemanticRetrieval")
    
    init(vectorStore: VectorStore, embeddingService: OllamaEmbeddingService) {
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
    }
    
    /// Bir sorgu için en alakalı ilk-K parçayı alır.
    func retrieve(query: String, topK: Int = 5) async throws -> [RetrievedContext] {
        logger.info("Retrieving context for query: \(query.prefix(50))...")
        
        // Sorgu embedding'i üret
        let queryText = "search_query: \(query)"
        let queryEmbedding = try await embeddingService.embedSingle(text: queryText)
        
        // Vektör deposunda ara
        let results = try await vectorStore.search(queryEmbedding: queryEmbedding, topK: topK)
        
        // RetrievedContext'e dönüştür
        let contexts = results.map { result in
            RetrievedContext(
                chunkText: result.chunk.text,
                similarity: result.similarity,
                metadata: result.chunk.metadata
            )
        }
        
        logger.info("Retrieved \(contexts.count) contexts with avg similarity: \(String(format: "%.2f", contexts.map(\.similarity).reduce(0, +) / Float(max(contexts.count, 1))))")
        
        return contexts
    }
}
