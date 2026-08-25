import Foundation

/// Metin parçalama stratejisi için yapılandırma.
struct ChunkConfig: Sendable {
    let chunkSize: Int        // Parça başına hedef token sayısı
    let chunkOverlap: Int     // Anlamsal süreklilik için parçalar arası örtüşme
    let minChunkSize: Int     // Minimum geçerli parça boyutu
    
    nonisolated static let `default` = ChunkConfig(
        chunkSize: 512,
        chunkOverlap: 50,
        minChunkSize: 100
    )
}

/// Metni embedding için örtüşen parçalara böler.
class TextChunker {
    private let config: ChunkConfig
    
    nonisolated init(config: ChunkConfig = .default) {
        self.config = config
    }
    
    /// Metni örtüşmeli kaydırmalı pencere kullanarak parçalara böler.
    func chunk(text: String) -> [String] {
        // Basit kelime tabanlı tokenizasyon (NaturalLanguage framework ile geliştirilebilir)
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else { return [] }
        
        var chunks: [String] = []
        var currentPosition = 0
        
        while currentPosition < words.count {
            let endPosition = min(currentPosition + config.chunkSize, words.count)
            let chunkWords = words[currentPosition..<endPosition]
            let chunkText = chunkWords.joined(separator: " ")
            
            // Yalnızca minimum boyut gereksinimini karşılıyorsa ekle
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
    
    /// Doğal dil sınırlarına (cümle/paragraf) saygı göstererek metni parçalara böler.
    nonisolated func chunkWithBoundaries(text: String) -> [String] {
        // Önce paragraflara böl
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var chunks: [String] = []
        var currentChunk = ""
        var currentWordCount = 0
        
        for paragraph in paragraphs {
            let paragraphWords = paragraph.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let paragraphWordCount = paragraphWords.count
            
            // Bu paragrafı eklemek parça boyutunu aşarsa mevcut parçayı sonlandır
            if currentWordCount + paragraphWordCount > config.chunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                
                // Start new chunk with overlap from previous
                let overlapWords = currentChunk.components(separatedBy: .whitespaces)
                    .suffix(config.chunkOverlap)
                currentChunk = overlapWords.joined(separator: " ") + " " + paragraph
                currentWordCount = overlapWords.count + paragraphWordCount
            } else {
                // Mevcut parçaya ekle
                if !currentChunk.isEmpty {
                    currentChunk += "\n\n"
                }
                currentChunk += paragraph
                currentWordCount += paragraphWordCount
            }
        }
        
        // Son parçayı ekle
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        
        let filtered = chunks.filter { $0.components(separatedBy: .whitespaces).count >= config.minChunkSize }
        
        // Her şey minChunkSize altındaysa tüm bağlamı bırakmak yerine en büyük parçayı koru.
        if filtered.isEmpty, let fallback = chunks.max(by: {
            $0.components(separatedBy: .whitespaces).count < $1.components(separatedBy: .whitespaces).count
        }) {
            return [fallback]
        }
        
        return filtered
    }
}
