import Foundation

// 🛡️ SECURITY NOTICE: Treat this file with care.
// In a real production app, fetch this from a secure server or Build Settings.

enum AIModelNames: Sendable {
    nonisolated static let vision = "gemini-3-flash-preview:cloud"
    nonisolated static let reasoning = "gpt-oss:20b-cloud"
    nonisolated static let coding = "gpt-oss:120b-cloud"
    nonisolated static let fast = "ministral-3:14b-cloud"
    nonisolated static let whisper = "whisper-large-v3-turbo"
}
