import Foundation
import PDFKit
import os

/// Belgeleri (PDF, metin) embedding için parçalara işler.
actor DocumentProcessor {
    private let chunker: TextChunker
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "DocumentProcessor")
    
    init(chunker: TextChunker = TextChunker()) {
        self.chunker = chunker
    }
    
    // MARK: - PDF İşleme
    
    /// Bir PDF dosyasını işler ve tüm sayfalardan tüm metni çıkarır.
    func processPDF(url: URL) async throws -> [DocumentChunk] {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw RAGError.documentProcessingFailed("Could not open PDF")
        }
        
        let filename = url.lastPathComponent
        var chunks: [DocumentChunk] = []
        
        logger.info("Processing PDF: \(filename) (\(pdfDocument.pageCount) pages)")
        
        // Her sayfayı işle
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex),
                  let pageText = page.string else {
                continue
            }
            
            // Boş sayfaları atla
            let trimmedText = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            
            // Sayfa metnini parçalara ayır
            let pageChunks = chunker.chunkWithBoundaries(text: trimmedText)
            
            // Her metin parçası için DocumentChunk oluştur
            for chunkText in pageChunks {
                let metadata = ChunkMetadata(
                    sourceType: .pdf,
                    sourceID: filename,
                    pageNumber: pageIndex + 1  // kullanıcı gösterimi için 1 tabanlı
                )
                
                let chunk = DocumentChunk(text: chunkText, metadata: metadata)
                chunks.append(chunk)
            }
        }
        
        logger.info("Extracted \(chunks.count) chunks from \(pdfDocument.pageCount) pages")
        return chunks
    }
    
    // MARK: - Sohbet Mesajı İşleme
    
    /// Bir sohbet mesajını tek bir parçaya işler.
    func processChatMessage(text: String, sessionID: String) -> DocumentChunk {
        let metadata = ChunkMetadata(
            sourceType: .chat,
            sourceID: sessionID
        )
        
        return DocumentChunk(text: text, metadata: metadata)
    }
    
    /// Sohbet geçmişini (birden fazla mesaj) parçalara işler.
    func processChatHistory(messages: [String], sessionID: String) -> [DocumentChunk] {
        // Birden fazla mesajı birleştir ve parçalara ayır
        let combinedText = messages.joined(separator: "\n\n")
        let textChunks = chunker.chunkWithBoundaries(text: combinedText)
        
        return textChunks.map { chunkText in
            let metadata = ChunkMetadata(
                sourceType: .chat,
                sourceID: sessionID
            )
            return DocumentChunk(text: chunkText, metadata: metadata)
        }
    }
    
    // MARK: - Düz Metin İşleme
    
    /// Rastgele metni (örn. panodan) parçalara işler.
    func processText(text: String, sourceID: String) -> [DocumentChunk] {
        let textChunks = chunker.chunkWithBoundaries(text: text)
        
        return textChunks.map { chunkText in
            let metadata = ChunkMetadata(
                sourceType: .clipboard,
                sourceID: sourceID
            )
            return DocumentChunk(text: chunkText, metadata: metadata)
        }
    }
}
