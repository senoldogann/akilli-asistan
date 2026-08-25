import Foundation
import PDFKit
import os

class DocumentParserService {
    static let shared = DocumentParserService()
    private static let logger = Logger(subsystem: "com.zerolose", category: "document-parser")
    
    private init() {}
    
    func extractText(from url: URL) -> String? {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileExtension = url.pathExtension.lowercased()
        
        if fileExtension == "pdf" {
            guard let document = PDFDocument(url: url) else {
                Self.logger.error("Failed to initialize PDFDocument for URL: \(url, privacy: .public)")
                return nil
            }
            var fullText = ""
            for i in 0..<document.pageCount {
                if let page = document.page(at: i), let pageText = page.string {
                    fullText += pageText + "\n"
                }
            }
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } else {
            // Metin/JSON dosyaları
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                Self.logger.error(
                    "Failed to read text contents from URL: \(url, privacy: .public) error: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }
}
