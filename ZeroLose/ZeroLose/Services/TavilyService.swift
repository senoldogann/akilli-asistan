import Foundation
import OSLog

/// A service to interact with the Tavily Search API.
actor TavilyService {
    private let baseURL = URL(string: "https://api.tavily.com")!
    private let logger = Logger(subsystem: "com.zerolose", category: "tavily")
    private var inMemoryCache: [String: CachedSearchContext] = [:]
    private let cacheTTL: TimeInterval = 90

    enum DetailLevel: String, Sendable {
        case brief
        case detailed
    }
    
    enum TavilyError: Error {
        case invalidURL
        case requestFailed(String)
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
    
    /// Performs a web search and returns a structured evidence context.
    func search(query: String, detailLevel: DetailLevel = .brief) async throws -> String {
        let normalizedQuery = query
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
            query: query,
            search_depth: detailLevel == .detailed ? "advanced" : "basic",
            include_answer: true,
            max_results: detailLevel == .detailed ? 8 : 5
        )
        
        request.httpBody = try JSONEncoder().encode(payload)
        
        logger.info("Performing Tavily search (query_length: \(query.count, privacy: .public))")
        
        return try await withRetry {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TavilyError.requestFailed("Invalid Response")
            }
            
            if httpResponse.statusCode != 200 {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
                self.logger.error("Tavily API Error: \(httpResponse.statusCode), \(errorMsg)")
                throw TavilyError.requestFailed("API Error: \(httpResponse.statusCode)")
            }
            
            do {
                let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
                
                let context = self.buildContext(
                    query: query,
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
}
