import Foundation
import PDFKit

class DocumentParserService {
    static let shared = DocumentParserService()
    
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
                print("Failed to initialize PDFDocument for URL: \(url)")
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
            // Text/JSON files
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                print("Failed to read text contents from URL: \(url), error: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
