import Foundation

/// Represents a chunk of text extracted from a document or conversation
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

/// Metadata about the source of a chunk
struct ChunkMetadata: Codable, Sendable {
    let sourceType: SourceType
    let sourceID: String        // Filename or chat session ID
    let pageNumber: Int?        // For PDF sources
    let timestamp: Date
    
    nonisolated init(sourceType: SourceType, sourceID: String, pageNumber: Int? = nil, timestamp: Date = Date()) {
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.pageNumber = pageNumber
        self.timestamp = timestamp
    }
}

/// Type of document source
enum SourceType: String, Codable, Sendable {
    case pdf
    case chat
    case clipboard
}

/// Result from a semantic search
struct SearchResult: Sendable {
    let chunk: DocumentChunk
    let similarity: Float
    let embedding: [Float]
}

/// Retrieved context for RAG augmentation
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
