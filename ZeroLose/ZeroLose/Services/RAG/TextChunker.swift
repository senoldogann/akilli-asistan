import Foundation

/// Configuration for text chunking strategy
struct ChunkConfig: Sendable {
    let chunkSize: Int        // Target tokens per chunk
    let chunkOverlap: Int     // Overlap between chunks for semantic continuity
    let minChunkSize: Int     // Minimum viable chunk size
    
    nonisolated static let `default` = ChunkConfig(
        chunkSize: 512,
        chunkOverlap: 50,
        minChunkSize: 100
    )
}

/// Splits text into overlapping chunks for embedding
class TextChunker {
    private let config: ChunkConfig
    
    nonisolated init(config: ChunkConfig = .default) {
        self.config = config
    }
    
    /// Chunk text using sliding window with overlap
    func chunk(text: String) -> [String] {
        // Simple word-based tokenization (can be improved with NaturalLanguage framework)
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else { return [] }
        
        var chunks: [String] = []
        var currentPosition = 0
        
        while currentPosition < words.count {
            let endPosition = min(currentPosition + config.chunkSize, words.count)
            let chunkWords = words[currentPosition..<endPosition]
            let chunkText = chunkWords.joined(separator: " ")
            
            // Only add if meets minimum size requirement
            if chunkWords.count >= config.minChunkSize || endPosition == words.count {
                chunks.append(chunkText)
            }
            
            // Move forward with overlap
            currentPosition += (config.chunkSize - config.chunkOverlap)
            
            // Prevent infinite loop
            if currentPosition <= (endPosition - config.chunkSize) {
                break
            }
        }
        
        return chunks
    }
    
    /// Chunk text respecting natural language boundaries (sentences/paragraphs)
    nonisolated func chunkWithBoundaries(text: String) -> [String] {
        // Split by paragraphs first
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var chunks: [String] = []
        var currentChunk = ""
        var currentWordCount = 0
        
        for paragraph in paragraphs {
            let paragraphWords = paragraph.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let paragraphWordCount = paragraphWords.count
            
            // If adding this paragraph exceeds chunk size, finalize current chunk
            if currentWordCount + paragraphWordCount > config.chunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                
                // Start new chunk with overlap from previous
                let overlapWords = currentChunk.components(separatedBy: .whitespaces)
                    .suffix(config.chunkOverlap)
                currentChunk = overlapWords.joined(separator: " ") + " " + paragraph
                currentWordCount = overlapWords.count + paragraphWordCount
            } else {
                // Add to current chunk
                if !currentChunk.isEmpty {
                    currentChunk += "\n\n"
                }
                currentChunk += paragraph
                currentWordCount += paragraphWordCount
            }
        }
        
        // Add final chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        
        let filtered = chunks.filter { $0.components(separatedBy: .whitespaces).count >= config.minChunkSize }
        
        // If everything is below minChunkSize, keep the largest chunk instead of dropping all context.
        if filtered.isEmpty, let fallback = chunks.max(by: {
            $0.components(separatedBy: .whitespaces).count < $1.components(separatedBy: .whitespaces).count
        }) {
            return [fallback]
        }
        
        return filtered
    }
}
