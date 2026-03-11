import Foundation
import CryptoKit
import os

/// Cache service for storing AI responses to interview questions
/// Provides instant answers during interviews by caching warm-up responses
class ResponseCacheService {
    static let shared = ResponseCacheService()
    
    private let cacheURL: URL
    private var cache: ResponseCache?
    private let logger = Logger(subsystem: "com.zerolose", category: "response-cache")
    
    struct ResponseCache: Codable {
        var version: String = "1.0"
        var timestamp: Date
        var sourceHash: String // SHA256 of InterviewData.json
        var responses: [CachedResponse]
    }
    
    struct CachedResponse: Codable {
        let question: String
        let answer: String
        let category: String
        let cachedAt: Date
    }
    
    init(cacheURL customCacheURL: URL? = nil) {
        if let customCacheURL {
            self.cacheURL = customCacheURL
            let parentDir = customCacheURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } else {
            // Store cache in app support directory
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("ZeroLose", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.cacheURL = appDir.appendingPathComponent("ResponseCache.json")
        }
        loadCache()
    }
    
    // MARK: - Public Methods
    
    func saveResponse(question: String, answer: String, category: String) {
        if cache == nil {
            cache = ResponseCache(timestamp: Date(), sourceHash: "", responses: [])
        }
        
        let response = CachedResponse(
            question: question,
            answer: answer,
            category: category,
            cachedAt: Date()
        )
        
        upsert(response)
        persistCache()
    }
    
    /// Bulk primes cache from interview vault entries.
    /// Returns number of unique questions kept in cache.
    @discardableResult
    func primeInterviewVault(entries: [(question: String, answer: String, category: String)]) -> Int {
        if cache == nil {
            cache = ResponseCache(timestamp: Date(), sourceHash: "", responses: [])
        }
        
        for entry in entries {
            let response = CachedResponse(
                question: entry.question,
                answer: entry.answer,
                category: entry.category,
                cachedAt: Date()
            )
            upsert(response)
        }
        
        cache?.timestamp = Date()
        persistCache()
        return cache?.responses.count ?? 0
    }

    func interviewVaultCoverage(
        entries: [(question: String, answer: String, category: String)]
    ) -> (total: Int, cached: Int, missing: Int) {
        let requestedKeys = Set(entries.map { cacheKey(question: $0.question, category: $0.category) })
        let total = requestedKeys.count
        guard total > 0, let cache = cache else {
            return (total, 0, total)
        }

        let cachedKeys = Set(cache.responses.map { cacheKey(question: $0.question, category: $0.category) })
        let coveredCount = requestedKeys.intersection(cachedKeys).count
        return (total, coveredCount, max(0, total - coveredCount))
    }
    
    func getResponse(for question: String) -> String? {
        guard let cache = cache, !cache.responses.isEmpty else { return nil }
        
        let normalizedQuery = normalize(question)
        let queryTokenCount = normalizedQuery.split(separator: " ").count
        let compensationIntent = isCompensationIntent(question)
        
        // Try exact match first
        if let match = cache.responses.first(where: { normalize($0.question) == normalizedQuery }) {
            return match.answer
        }
        
        // Variant-aware semantic-ish matching via shared interview matcher.
        let records = cache.responses.map { response in
            InterviewKnowledgeRecord(
                category: response.category,
                question: response.question,
                answer: response.answer,
                keyPoints: []
            )
        }

        guard let topMatch = InterviewKnowledgeMatcher.topMatches(
            query: question,
            records: records,
            maxResults: 1,
            minimumScore: 0.16
        ).first else {
            return nil
        }

        if queryTokenCount <= 3 {
            let strictConfidence = topMatch.score >= 0.72 && topMatch.matchedTokenCount >= 1
            if strictConfidence {
                return topMatch.record.answer
            }

            let compensationConfidence =
                compensationIntent &&
                isCompensationRecord(topMatch.record) &&
                topMatch.score >= 0.22 &&
                (
                    topMatch.matchedTokenCount >= 1 ||
                    isCompensationIntent(topMatch.record.question) ||
                    isCompensationIntent(topMatch.record.answer)
                )
            return compensationConfidence ? topMatch.record.answer : nil
        }

        let highConfidence = topMatch.score >= 0.55
        let mediumConfidence = topMatch.score >= 0.38 && topMatch.matchedTokenCount >= 2
        return (highConfidence || mediumConfidence) ? topMatch.record.answer : nil
    }
    
    private func normalize(_ text: String) -> String {
        InterviewKnowledgeMatcher.normalize(text)
    }
    
    private func upsert(_ response: CachedResponse) {
        guard cache != nil else { return }
        
        let key = cacheKey(question: response.question, category: response.category)
        if let existingIndex = cache?.responses.firstIndex(where: {
            cacheKey(question: $0.question, category: $0.category) == key
        }) {
            cache?.responses[existingIndex] = response
        } else {
            cache?.responses.append(response)
        }
    }

    private func cacheKey(question: String, category: String) -> String {
        "\(normalize(category))|\(normalize(question))"
    }

    private func isCompensationIntent(_ query: String) -> Bool {
        let normalizedQuery = normalize(query)
        let explicitTokens = [
            "palkka", "palkkatoive", "palkkatavoite", "palkkavaatimus", "palkkataso",
            "salary", "compensation", "wage", "brutto", "euro"
        ]
        if explicitTokens.contains(where: { normalizedQuery.contains($0) }) {
            return true
        }
        return InterviewKnowledgeMatcher.canonicalKeywords(from: normalizedQuery).contains("salary")
    }

    private func isCompensationRecord(_ record: InterviewKnowledgeRecord) -> Bool {
        let corpus = [
            record.category,
            record.question,
            record.answer,
            record.keyPoints.joined(separator: " ")
        ].joined(separator: " ")
        return InterviewKnowledgeMatcher.canonicalKeywords(from: corpus).contains("salary")
    }
    
    func clearCache() {
        cache = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }
    
    func isWarmupComplete() -> Bool {
        guard let cache = cache else { return false }
        return !cache.responses.isEmpty
    }
    
    func validateCache(against dataHash: String) -> Bool {
        guard let cache = cache else { return false }
        
        // Check if source data changed
        if cache.sourceHash != dataHash {
            return false
        }
        
        // Check if cache is older than 24 hours
        let hoursSinceCache = Date().timeIntervalSince(cache.timestamp) / 3600
        if hoursSinceCache > 24 {
            return false
        }
        
        return true
    }
    
    func saveSourceHash(_ hash: String) {
        cache?.sourceHash = hash
        cache?.timestamp = Date()
        persistCache()
    }
    
    // MARK: - Private Methods
    
    private func loadCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: cacheURL)
            cache = try JSONDecoder().decode(ResponseCache.self, from: data)
        } catch {
            logger.error("Failed to load cache: \(error.localizedDescription)")
            cache = nil
        }
    }
    
    private func persistCache() {
        guard let cache = cache else { return }
        
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL)
        } catch {
            logger.error("Failed to save cache: \(error.localizedDescription)")
        }
    }
    
    // Similarity handled in InterviewKnowledgeMatcher for consistent vault/cache behavior.
}

// MARK: - Hash Extension

extension String {
    func sha256() -> String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
