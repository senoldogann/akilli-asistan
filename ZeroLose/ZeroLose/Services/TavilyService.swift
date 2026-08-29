import Foundation
import OSLog

/// Tavily Arama API'si ile etkileşim kuran bir hizmet.
actor TavilyService {
    private let baseURL = URL(string: "https://api.tavily.com")!
    private let logger = Logger(subsystem: "com.zerolose", category: "tavily")
    private var inMemoryCache: [String: CachedSearchContext] = [:]
    private let cacheTTL: TimeInterval = 90
    private let maxProviderQueryLength = 380

    enum DetailLevel: String, Sendable {
        case brief
        case detailed
    }
    
    enum TavilyError: Error {
        case invalidURL
        case requestFailed(String)
        case apiError(Int, String)
        case decodingError
        case missingAPIKey
    }
    
    struct CachedSearchContext {
        let context: String
        let createdAt: Date
    }
    
    struct SearchRequest: Codable {
        let api_key: String
        let query: String
        let search_depth: String
        let include_answer: Bool
        let max_results: Int
    }
    
    struct SearchResult: Codable {
        let title: String
        let url: String
        let content: String
        let score: Double
    }
    
    struct SearchResponse: Codable {
        let results: [SearchResult]
        let answer: String?
    }
    
    /// Bir web araması yapar ve yapılandırılmış bir kanıt bağlamı döndürür.
    /// `onProgress` arama aşamalarını ve her kaynağı UI'a canlı aktarır.
    func search(
        query: String,
        detailLevel: DetailLevel = .brief,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let preparedQuery = Self.preferredQuery(from: query, maxLength: maxProviderQueryLength)
        let normalizedQuery = preparedQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let key = "\(detailLevel.rawValue)::\(normalizedQuery)"
        
        if let cached = inMemoryCache[key], Date().timeIntervalSince(cached.createdAt) <= cacheTTL {
            logger.info("Tavily cache HIT (query_length: \(query.count, privacy: .public))")
            return cached.context
        }
        
        let apiKey = Secrets.tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw TavilyError.missingAPIKey
        }
        
        let url = baseURL.appendingPathComponent("search")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = SearchRequest(
            api_key: apiKey,
            query: preparedQuery,
            search_depth: detailLevel == .detailed ? "advanced" : "basic",
            include_answer: true,
            max_results: detailLevel == .detailed ? 8 : 5
        )
        
        request.httpBody = try JSONEncoder().encode(payload)
        
        logger.info("Performing Tavily search (query_length: \(preparedQuery.count, privacy: .public))")
        onProgress?("Arama sorgusu hazırlandı: \(preparedQuery)")
        onProgress?("Tavily kaynakları aranıyor…")
        
        return try await withRetry {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TavilyError.requestFailed("Invalid Response")
            }
            
            if httpResponse.statusCode != 200 {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
                self.logger.error("Tavily API Error: \(httpResponse.statusCode), \(errorMsg)")
                throw TavilyError.apiError(httpResponse.statusCode, errorMsg)
            }
            
            do {
                let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
                
                if let answer = searchResponse.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                    onProgress?("Özet bulundu: \(self.compact(answer, limit: 240))")
                }
                for (index, result) in searchResponse.results.prefix(detailLevel == .detailed ? 8 : 5).enumerated() {
                    onProgress?("Kaynak \(index + 1): \(result.title)")
                }
                onProgress?("Kaynaklar alındı, cevap hazırlanıyor…")

                let context = self.buildContext(
                    query: preparedQuery,
                    response: searchResponse,
                    detailLevel: detailLevel
                )
                
                self.inMemoryCache[key] = CachedSearchContext(context: context, createdAt: Date())
                return context
            } catch {
                self.logger.error("Tavily Decoding Error: \(error.localizedDescription)")
                throw TavilyError.decodingError
            }
        }
    }
    
    // MARK: - Resilience
    
    private func withRetry<T>(
        maxAttempts: Int = 3,
        baseDelay: Double = 1.0,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard shouldRetry(error: error) else {
                    throw error
                }
                if attempt < maxAttempts {
                    let delay = baseDelay * pow(2.0, Double(attempt - 1))
                    let jitter = Double.random(in: 0...(delay * 0.1))
                    logger.warning("⚠️ Tavily Attempt \(attempt) failed, retrying in \(String(format: "%.2f", delay + jitter))s...")
                    try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                }
            }
        }
        throw lastError ?? TavilyError.requestFailed("Max attempts reached")
    }

    private func shouldRetry(error: Error) -> Bool {
        if case let TavilyError.apiError(statusCode, _) = error {
            return statusCode == 429 || statusCode >= 500
        }
        return true
    }

    private func buildContext(
        query: String,
        response: SearchResponse,
        detailLevel: DetailLevel
    ) -> String {
        let resultLimit = detailLevel == .detailed ? 8 : 4
        let snippetLimit = detailLevel == .detailed ? 520 : 240
        let selectedResults = Array(response.results.prefix(resultLimit))
        let retrievedAt = ISO8601DateFormatter().string(from: Date())

        var lines: [String] = []
        lines.append("[WEB SEARCH CONTEXT]")
        lines.append("Query: \(query)")
        lines.append("RetrievedAtUTC: \(retrievedAt)")

        if let answer = response.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            lines.append("")
            lines.append("[DIRECT SUMMARY]")
            lines.append(answer)
        }

        lines.append("")
        lines.append("[EVIDENCE SOURCES]")

        if selectedResults.isEmpty {
            lines.append("No web sources returned.")
        } else {
            for (index, result) in selectedResults.enumerated() {
                let snippet = compact(result.content, limit: snippetLimit)
                lines.append("[\(index + 1)] \(result.title)")
                lines.append("URL: \(result.url)")
                lines.append("Relevance: \(String(format: "%.2f", result.score))")
                lines.append("Evidence: \(snippet)")
                lines.append("")
            }
        }

        lines.append("[SOURCE LINKS]")
        if selectedResults.isEmpty {
            lines.append("No source links available.")
        } else {
            for (index, result) in selectedResults.enumerated() {
                lines.append("\(index + 1). \(result.title) - \(result.url)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func compact(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    nonisolated static func preferredQuery(from rawQuery: String, maxLength: Int = 380) -> String {
        func compactWhitespace(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        func containsQuestionSignal(_ text: String) -> Bool {
            let lowered = text.lowercased()
            if lowered.contains("?") {
                return true
            }

            let tokens = [
                "mikä", "mita", "mitä", "miten", "miksi", "millainen", "millä", "minkä", "minkälainen",
                "what", "why", "how", "which", "who", "can you",
                "neden", "nasıl", "nasil", "hangi", "ne", "kim"
            ]
            return tokens.contains { lowered.contains($0) }
        }

        func looksLikeCodeLine(_ text: String) -> Bool {
            let lowered = text.lowercased()
            let codeSignals = [
                "const ", "let ", "var ", "function ", "async ", "await ", "return ",
                "class ", "interface ", "type ", "import ", "export ", "=>", "{", "}",
                "</", "/>", "select ", "insert ", "update ", "delete ", "public ", "private "
            ]
            return codeSignals.contains { lowered.contains($0) }
        }

        func looksCodeHeavy(_ text: String) -> Bool {
            let lowered = text.lowercased()
            let strongSignals = ["```", "const ", "let ", "function ", "async ", "await ", "interface ", "type ", "=>"]
            if strongSignals.contains(where: lowered.contains) {
                return true
            }

            let punctuationCount = lowered.filter { "{}[]();<>".contains($0) }.count
            return punctuationCount >= 12
        }

        let compacted = rawQuery
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compacted.isEmpty else { return "" }
        if compacted.count <= maxLength && !looksCodeHeavy(compacted) {
            return compactWhitespace(compacted)
        }

        let preprocessed = compacted
            .replacingOccurrences(of: "```", with: "\n")
            .replacingOccurrences(of: "=>", with: "\n")
            .replacingOccurrences(of: "{", with: "\n")
            .replacingOccurrences(of: "}", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")

        let lines = preprocessed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let nonCodeLines = lines.filter { !looksLikeCodeLine($0) }
        let questionLikeLines = nonCodeLines.filter { containsQuestionSignal($0) }
        let candidateLines = questionLikeLines.isEmpty ? nonCodeLines : questionLikeLines

        if !candidateLines.isEmpty {
            var selected: [String] = []
            var usedLength = 0

            for line in candidateLines.suffix(3) {
                let compactLine = compactWhitespace(line)
                guard !compactLine.isEmpty else { continue }
                let projected = usedLength + compactLine.count + (selected.isEmpty ? 0 : 1)
                if projected > maxLength {
                    continue
                }
                selected.append(compactLine)
                usedLength = projected
            }

            if !selected.isEmpty {
                return selected.joined(separator: " ")
            }
        }

        return String(compactWhitespace(compacted).prefix(maxLength))
    }
}
