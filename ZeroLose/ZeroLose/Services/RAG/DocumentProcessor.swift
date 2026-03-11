import Foundation
import PDFKit
import os

/// Processes documents (PDFs, text) into chunks for embedding
actor DocumentProcessor {
    private let chunker: TextChunker
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "DocumentProcessor")
    
    init(chunker: TextChunker = TextChunker()) {
        self.chunker = chunker
    }
    
    // MARK: - PDF Processing
    
    /// Process a PDF file and extract all text from all pages
    func processPDF(url: URL) async throws -> [DocumentChunk] {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw RAGError.documentProcessingFailed("Could not open PDF")
        }
        
        let filename = url.lastPathComponent
        var chunks: [DocumentChunk] = []
        
        logger.info("Processing PDF: \(filename) (\(pdfDocument.pageCount) pages)")
        
        // Process each page
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex),
                  let pageText = page.string else {
                continue
            }
            
            // Skip empty pages
            let trimmedText = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            
            // Chunk the page text
            let pageChunks = chunker.chunkWithBoundaries(text: trimmedText)
            
            // Create DocumentChunk for each text chunk
            for chunkText in pageChunks {
                let metadata = ChunkMetadata(
                    sourceType: .pdf,
                    sourceID: filename,
                    pageNumber: pageIndex + 1  // 1-indexed for user display
                )
                
                let chunk = DocumentChunk(text: chunkText, metadata: metadata)
                chunks.append(chunk)
            }
        }
        
        logger.info("Extracted \(chunks.count) chunks from \(pdfDocument.pageCount) pages")
        return chunks
    }
    
    // MARK: - Chat Message Processing
    
    /// Process a chat message into a single chunk
    func processChatMessage(text: String, sessionID: String) -> DocumentChunk {
        let metadata = ChunkMetadata(
            sourceType: .chat,
            sourceID: sessionID
        )
        
        return DocumentChunk(text: text, metadata: metadata)
    }
    
    /// Process chat history (multiple messages) into chunks
    func processChatHistory(messages: [String], sessionID: String) -> [DocumentChunk] {
        // Combine multiple messages and chunk them
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
    
    // MARK: - Plain Text Processing
    
    /// Process arbitrary text (e.g., from clipboard) into chunks
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
