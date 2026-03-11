import Foundation
import os
// Removed AppKit to prevent MainActor pollution

enum OllamaError: Error {
    case invalidURL
    case noData
    case decodingError
    case serverError(String)
}

actor OllamaService {
    // ☁️ CLOUD CONFIGURATION
    private let baseURL = URL(string: "https://ollama.com/api")!
    
    // We use a non-isolated logger
    private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "OllamaCloud")
    
    // START: Request Structures
    struct ChatMessage: Encodable, Sendable {
        let role: String
        let content: String
        let images: [String]?
    }
    
    struct ChatRequest: Encodable, Sendable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }
    
    struct ChatResponse: Decodable, Sendable {
        let model: String
        let message: ResponseMessage
        let done: Bool
    }
    
    struct ResponseMessage: Decodable, Sendable {
        let role: String
        let content: String
    }
    // END: Request Structures
    
    /// Generates response. 
    func generate(messages: [ChatMessage], model: String? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Use Global Secret Key
        request.setValue("Bearer \(Secrets.ollamaApiKey)", forHTTPHeaderField: "Authorization")
        
        // Model Selection Logic
        let selectedModel: String
        if let explicitModel = model {
            selectedModel = explicitModel
        } else {
            // Logic: If any message has an image -> Vision, else -> Reasoning
            let hasImages = messages.contains { $0.images != nil && !($0.images?.isEmpty ?? true) }
            selectedModel = hasImages ? AIModelNames.vision : AIModelNames.reasoning
        }
        
        let payload = ChatRequest(
            model: selectedModel,
            messages: messages,
            stream: false
        )
        
        request.httpBody = try JSONEncoder().encode(payload)
        
        logger.info("Sending CLOUD request... Model: \(selectedModel) (Messages: \(messages.count))")
        
        return try await withRetry {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.serverError("Network Error")
            }
            
            if httpResponse.statusCode != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                self.logger.error("Cloud Error: \(httpResponse.statusCode) | Body: \(errorBody)")
                throw OllamaError.serverError("API Error: \(httpResponse.statusCode)")
            }
            
            do {
                let result = try JSONDecoder().decode(ChatResponse.self, from: data)
                return result.message.content
            } catch {
                self.logger.error("Decode Error: \(error.localizedDescription)")
                throw OllamaError.decodingError
            }
        }
    }
    
    /// Generates response with STREAMING support. Calls onPartialResponse with each chunk.
    func generateStreaming(messages: [ChatMessage], model: String? = nil, onPartialResponse: @escaping (String) -> Void) async throws {
        let url = baseURL.appendingPathComponent("chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Secrets.ollamaApiKey)", forHTTPHeaderField: "Authorization")
        
        // Model Selection Logic
        let selectedModel: String
        if let explicitModel = model {
            selectedModel = explicitModel
        } else {
            let hasImages = messages.contains { $0.images != nil && !($0.images?.isEmpty ?? true) }
            selectedModel = hasImages ? AIModelNames.vision : AIModelNames.reasoning
        }
        
        let payload = ChatRequest(
            model: selectedModel,
            messages: messages,
            stream: true // STREAMING ENABLED
        )
        
        request.httpBody = try JSONEncoder().encode(payload)
        
        logger.info("Sending STREAMING request... Model: \(selectedModel) (Messages: \(messages.count))")
        
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.serverError("Network Error")
        }
        
        if httpResponse.statusCode != 200 {
            throw OllamaError.serverError("API Error: \(httpResponse.statusCode)")
        }
        
        var buffer = ""
        for try await line in asyncBytes.lines {
            // Check for cancellation at each chunk
            try Task.checkCancellation()
            
            guard !line.isEmpty else { continue }
            
            do {
                let chunk = try JSONDecoder().decode(ChatResponse.self, from: Data(line.utf8))
                let content = chunk.message.content
                buffer += content
                onPartialResponse(buffer) // Send accumulated text to UI
            } catch {
                logger.error("Stream decode error: \(error.localizedDescription)")
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
                    logger.warning("⚠️ Attempt \(attempt) failed, retrying in \(String(format: "%.2f", delay + jitter))s...")
                    try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                }
            }
        }
        throw lastError ?? OllamaError.serverError("Max attempts reached")
    }
}

// MARK: - Extensions
// NSImage extension moved to Extensions.swift to maintain Actor isolation.
