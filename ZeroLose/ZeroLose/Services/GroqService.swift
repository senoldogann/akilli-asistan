import Foundation
import AVFoundation
import os

actor GroqService: Sendable {
    private let apiKey: String
    private let model: String = AIModelNames.whisper
    nonisolated private let logger = Logger.network
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Transcribe audio from Data instead of a file URL to minimize disk I/O
    func transcribe(audioData: Data, fileName: String = "audio.wav", prompt: String? = nil, language: String? = nil, enableDiarization: Bool = false) async throws -> TranscriptionResponse {
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Model parameter
        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n", to: &body)
        appendString("\(model)\r\n", to: &body)
        
        // Language parameter
        if let language = language {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n", to: &body)
            appendString("\(language)\r\n", to: &body)
        }
        
        // Prompt parameter
        if let prompt = prompt {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n", to: &body)
            appendString("\(prompt)\r\n", to: &body)
        }
        
        // Response Format (Required for segments/timestamps)
        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n", to: &body)
        appendString("verbose_json\r\n", to: &body)
        
        // File parameter from Data
        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n", to: &body)
        appendString("Content-Type: audio/wav\r\n\r\n", to: &body)
        body.append(audioData)
        appendString("\r\n", to: &body)
        
        // Timestamp Granularities (Replacing non-standard diarize)
        if enableDiarization {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n", to: &body)
            appendString("segment\r\n", to: &body)
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n", to: &body)
            appendString("word\r\n", to: &body)
        }
        
        // Temperature for deterministic output
        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n", to: &body)
        appendString("0\r\n", to: &body)
        
        appendString("--\(boundary)--\r\n", to: &body)
        request.httpBody = body
        
        return try await withRetry {
            self.logger.info("Sending transcription request to Groq (\(audioData.count) bytes)")
            
            let (responseData, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ZeroLoseError.invalidResponse
            }
            
            if httpResponse.statusCode != 200 {
                let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown Error"
                self.logger.error("Groq API Error (\(httpResponse.statusCode)): \(errorBody)")
                throw ZeroLoseError.apiError(httpResponse.statusCode, errorBody)
            }
            
            struct GroqInternalResponse: Codable {
                let text: String?
                let language: String?
                let segments: [GroqInternalSegment]?
                
                struct GroqInternalSegment: Codable {
                    let text: String
                    let speaker: String?
                    let start: Double?
                    let end: Double?
                }
            }
            
            do {
                let decoded = try JSONDecoder().decode(GroqInternalResponse.self, from: responseData)
                
                let finalSegments = decoded.segments?.map {
                    TranscriptSegment(
                        text: $0.text,
                        speaker: $0.speaker,
                        timestamp: $0.start ?? 0
                    )
                }
                
                return TranscriptionResponse(
                    text: decoded.text ?? (finalSegments?.first?.text ?? ""),
                    language: decoded.language,
                    segments: finalSegments
                )
            } catch {
                self.logger.error("Failed to decode Groq response: \(error.localizedDescription)")
                throw ZeroLoseError.decodingError(error.localizedDescription)
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
                    logger.warning("⚠️ Groq Attempt \(attempt) failed, retrying in \(String(format: "%.2f", delay + jitter))s...")
                    try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                }
            }
        }
        throw lastError ?? ZeroLoseError.invalidResponse
    }

    private func appendString(_ string: String, to data: inout Data) {
        if let d = string.data(using: .utf8) {
            data.append(d)
        }
    }
}

// MARK: - Data Models

struct TranscriptionResponse: Sendable {
    let text: String
    let language: String?
    let segments: [TranscriptSegment]?
}

struct TranscriptSegment: Sendable {
    let text: String
    let speaker: String? // "Speaker 0", "Speaker 1"
    let timestamp: TimeInterval
}


