import Foundation
import AVFoundation
import os

actor GroqService: Sendable {
    private enum Provider {
        case openAI
        case groq
    }

    private let groqApiKey: String
    nonisolated private let logger = Logger.network

    init(apiKey: String) {
        self.groqApiKey = apiKey
    }

    func transcribe(
        audioData: Data,
        fileName: String = "audio.wav",
        prompt: String? = nil,
        language: String? = nil,
        enableDiarization: Bool = false
    ) async throws -> TranscriptionResponse {
        switch activeTranscriptionProvider(preferOpenAI: Secrets.isOpenAIKeyValid) {
        case .openAI:
            return try await transcribeWithOpenAI(
                audioData: audioData,
                fileName: fileName,
                prompt: prompt,
                language: language
            )
        case .groq:
            return try await transcribeWithGroq(
                audioData: audioData,
                fileName: fileName,
                prompt: prompt,
                language: language,
                enableDiarization: enableDiarization
            )
        }
    }

    nonisolated static func transcriptionProvider(preferOpenAI: Bool) -> String {
        preferOpenAI ? "openai" : "groq"
    }

    nonisolated static func transcriptionResponseFormat(preferOpenAI: Bool) -> String {
        preferOpenAI ? "json" : "verbose_json"
    }

    private func activeTranscriptionProvider(preferOpenAI: Bool) -> Provider {
        preferOpenAI ? .openAI : .groq
    }

    private func shouldRetryTranscription(error: Error) -> Bool {
        guard case let ZeroLoseError.apiError(statusCode, _) = error else {
            return true
        }

        if statusCode == 429 || statusCode >= 500 {
            return true
        }

        return false
    }

    private func transcribeWithOpenAI(
        audioData: Data,
        fileName: String,
        prompt: String?,
        language: String?
    ) async throws -> TranscriptionResponse {
        let apiKey = Secrets.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ZeroLoseError.apiError(401, "OpenAI API key is missing.")
        }

        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n", to: &body)
        appendString("\(AIModelNames.whisper)\r\n", to: &body)

        if let language {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n", to: &body)
            appendString("\(language)\r\n", to: &body)
        }

        if let prompt {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n", to: &body)
            appendString("\(prompt)\r\n", to: &body)
        }

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n", to: &body)
        appendString("\(Self.transcriptionResponseFormat(preferOpenAI: true))\r\n", to: &body)

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n", to: &body)
        appendString("Content-Type: audio/wav\r\n\r\n", to: &body)
        body.append(audioData)
        appendString("\r\n", to: &body)

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n", to: &body)
        appendString("0\r\n", to: &body)
        appendString("--\(boundary)--\r\n", to: &body)
        request.httpBody = body

        return try await withRetry {
            self.logger.info("Sending transcription request to OpenAI (\(audioData.count) bytes)")

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ZeroLoseError.invalidResponse
            }

            if httpResponse.statusCode != 200 {
                let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown Error"
                self.logger.error("OpenAI API Error (\(httpResponse.statusCode)): \(errorBody, privacy: .public)")
                throw ZeroLoseError.apiError(httpResponse.statusCode, errorBody)
            }

            return try self.decodeTranscriptionResponse(responseData)
        }
    }

    private func transcribeWithGroq(
        audioData: Data,
        fileName: String,
        prompt: String?,
        language: String?,
        enableDiarization: Bool
    ) async throws -> TranscriptionResponse {
        let apiKey = groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ZeroLoseError.apiError(401, "Groq API key is missing.")
        }

        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n", to: &body)
        appendString("\(AIModelNames.whisper)\r\n", to: &body)

        if let language {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n", to: &body)
            appendString("\(language)\r\n", to: &body)
        }

        if let prompt {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n", to: &body)
            appendString("\(prompt)\r\n", to: &body)
        }

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n", to: &body)
        appendString("\(Self.transcriptionResponseFormat(preferOpenAI: false))\r\n", to: &body)

        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n", to: &body)
        appendString("Content-Type: audio/wav\r\n\r\n", to: &body)
        body.append(audioData)
        appendString("\r\n", to: &body)

        if enableDiarization {
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n", to: &body)
            appendString("segment\r\n", to: &body)
            appendString("--\(boundary)\r\n", to: &body)
            appendString("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n", to: &body)
            appendString("word\r\n", to: &body)
        }

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
                self.logger.error("Groq API Error (\(httpResponse.statusCode)): \(errorBody, privacy: .public)")
                throw ZeroLoseError.apiError(httpResponse.statusCode, errorBody)
            }

            return try self.decodeTranscriptionResponse(responseData)
        }
    }

    private func decodeTranscriptionResponse(_ responseData: Data) throws -> TranscriptionResponse {
        struct InternalResponse: Codable {
            let text: String?
            let language: String?
            let segments: [InternalSegment]?

            struct InternalSegment: Codable {
                let text: String
                let speaker: String?
                let start: Double?
                let end: Double?
            }
        }

        do {
            let decoded = try JSONDecoder().decode(InternalResponse.self, from: responseData)
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
            logger.error("Failed to decode transcription response: \(error.localizedDescription, privacy: .public)")
            throw ZeroLoseError.decodingError(error.localizedDescription)
        }
    }

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
                if attempt < maxAttempts, shouldRetryTranscription(error: error) {
                    let delay = baseDelay * pow(2.0, Double(attempt - 1))
                    let jitter = Double.random(in: 0...(delay * 0.1))
                    logger.warning("Attempt \(attempt) failed, retrying in \(String(format: "%.2f", delay + jitter))s")
                    try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                } else if attempt < maxAttempts {
                    logger.warning("Attempt \(attempt) failed with non-retriable transcription error. Aborting retries.")
                    break
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

struct TranscriptionResponse: Sendable {
    let text: String
    let language: String?
    let segments: [TranscriptSegment]?
}

struct TranscriptSegment: Sendable {
    let text: String
    let speaker: String?
    let timestamp: TimeInterval
}
