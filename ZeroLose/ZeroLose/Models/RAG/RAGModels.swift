import Foundation

/// Bir belgeden veya sohbetten çıkarılan bir metin parçasını temsil eder.
struct DocumentChunk: Codable, Sendable {
    let id: UUID
    let text: String
    let metadata: ChunkMetadata
    
    nonisolated init(id: UUID = UUID(), text: String, metadata: ChunkMetadata) {
        self.id = id
        self.text = text
        self.metadata = metadata
    }
}

/// Bir parçanın kaynağı hakkında meta veri.
struct ChunkMetadata: Codable, Sendable {
    let sourceType: SourceType
    let sourceID: String        // Dosya adı veya sohbet oturumu kimliği
    let pageNumber: Int?        // PDF kaynakları için
    let timestamp: Date
    
    nonisolated init(sourceType: SourceType, sourceID: String, pageNumber: Int? = nil, timestamp: Date = Date()) {
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.pageNumber = pageNumber
        self.timestamp = timestamp
    }
}

/// Belge kaynağı türü.
enum SourceType: String, Codable, Sendable {
    case pdf
    case chat
    case clipboard
}

/// Anlamsal arama sonucu.
struct SearchResult: Sendable {
    let chunk: DocumentChunk
    let similarity: Float
    let embedding: [Float]
}

/// RAG genişletmesi için alınan bağlam.
struct RetrievedContext: Sendable {
    let chunkText: String
    let similarity: Float
    let metadata: ChunkMetadata
    
    var sourceDisplay: String {
        switch metadata.sourceType {
        case .pdf:
            if let page = metadata.pageNumber {
                return "\(metadata.sourceID) (page \(page))"
            }
            return metadata.sourceID
        case .chat:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "Chat: \(formatter.string(from: metadata.timestamp))"
        case .clipboard:
            return "Clipboard"
        }
    }
}
