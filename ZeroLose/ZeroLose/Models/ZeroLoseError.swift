import Foundation

enum ZeroLoseError: LocalizedError {
    case audioCaptureFailed(String)
    case transcriptionFailed(String)
    case intelligenceFailed(String)
    case visionCaptureFailed(String)
    case apiError(Int, String)
    case invalidResponse
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .audioCaptureFailed(let msg): return "Audio Capture Failed: \(msg)"
        case .transcriptionFailed(let msg): return "Transcription Failed: \(msg)"
        case .intelligenceFailed(let msg): return "Intelligence Service Failed: \(msg)"
        case .visionCaptureFailed(let msg): return "Vision Capture Failed: \(msg)"
        case .apiError(let code, let msg): return "API Error (\(code)): \(msg)"
        case .invalidResponse: return "Invalid Response from Server."
        case .decodingError(let msg): return "Decoding Error: \(msg)"
        }
    }
}
