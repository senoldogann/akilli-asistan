import Foundation
import os

/// Retrieves relevant context from vector store for RAG
actor SemanticRetriever {
    private let vectorStore: VectorStore
    private let embeddingService: OllamaEmbeddingService
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "SemanticRetrieval")
    
    init(vectorStore: VectorStore, embeddingService: OllamaEmbeddingService) {
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
    }
    
    /// Retrieve top-K most relevant chunks for a query
    func retrieve(query: String, topK: Int = 5) async throws -> [RetrievedContext] {
        logger.info("Retrieving context for query: \(query.prefix(50))...")
        
        // Generate query embedding
        let queryText = "search_query: \(query)"
        let queryEmbedding = try await embeddingService.embedSingle(text: queryText)
        
        // Search vector store
        let results = try await vectorStore.search(queryEmbedding: queryEmbedding, topK: topK)
        
        // Convert to RetrievedContext
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
