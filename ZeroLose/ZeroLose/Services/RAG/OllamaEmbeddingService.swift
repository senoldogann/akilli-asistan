import Foundation
import os

/// Ollama'nın yerel modellerini kullanarak metin embedding'leri üreten hizmet.
actor OllamaEmbeddingService {
    private let baseURL: String
    private let model: String
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "RAGEmbedding")
    
    init(baseURL: String = "http://localhost:11434", model: String = "nomic-embed-text") {
        self.baseURL = baseURL
        self.model = model
    }
    
    // MARK: - Genel API
    
    /// Bir grup metin için embedding üretir.
    func embed(texts: [String]) async throws -> [[Float]] {
        var allEmbeddings: [[Float]] = []
        
        // Performans için 10'lu gruplar halinde işle
        let batchSize = 10
        for batch in texts.chunked(into: batchSize) {
            let batchEmbeddings = try await processBatch(batch)
            allEmbeddings.append(contentsOf: batchEmbeddings)
        }
        
        return allEmbeddings
    }
    
    /// Tek bir metin için embedding üretir.
    func embedSingle(text: String) async throws -> [Float] {
        let embeddings = try await embed(texts: [text])
        guard let embedding = embeddings.first else {
            throw RAGError.embeddingFailed("No embedding returned")
        }
        return embedding
    }
    
    // MARK: - Özel Uygulama
    
    private func processBatch(_ texts: [String]) async throws -> [[Float]] {
        var embeddings: [[Float]] = []
        
        for text in texts {
            let embedding = try await generateEmbedding(for: text)
            embeddings.append(embedding)
        }
        
        return embeddings
    }
    
    private func generateEmbedding(for text: String) async throws -> [Float] {
        let url = URL(string: "\(baseURL)/api/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Daha iyi anlamsal anlama için önek ekle
        let prefixedText = "search_document: \(text)"
        
        let requestBody: [String: Any] = [
            "model": model,
            "prompt": prefixedText
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RAGError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Ollama embedding failed (\(httpResponse.statusCode)): \(errorBody)")
            throw RAGError.embeddingFailed(errorBody)
        }
        
        struct EmbeddingResponse: Codable {
            let embedding: [Float]
        }
        
        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        logger.info("Generated embedding: \(decoded.embedding.count) dimensions")
        
        return decoded.embedding
    }
}

// MARK: - Parçalama için Dizi Uzantısı

extension Array {
    nonisolated func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Hatalar

enum RAGError: LocalizedError {
    case embeddingFailed(String)
    case invalidResponse
    case documentProcessingFailed(String)
    case vectorStoreFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .embeddingFailed(let msg):
            return "Embedding generation failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from Ollama"
        case .documentProcessingFailed(let msg):
            return "Document processing failed: \(msg)"
        case .vectorStoreFailed(let msg):
            return "Vector store operation failed: \(msg)"
        }
    }
}
