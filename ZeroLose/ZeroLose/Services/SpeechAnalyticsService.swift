import Foundation
import Combine

@MainActor
class SpeechAnalyticsService: ObservableObject {
    static let shared = SpeechAnalyticsService()
    
    @Published var wpm: Double = 0.0
    @Published var fillerWordsCount: Int = 0
    @Published var fillerWordsRatio: Double = 0.0 // percentage of filler words
    @Published var pacingFeedback: String = "Not Speaking"
    @Published var sessionTranscripts: [String] = []
    
    private var startTime: Date?
    private var totalWordsCount = 0
    private var fillerCount = 0
    
    // Multi-language filler words list
    private let fillerWords: Set<String> = [
        // English
        "um", "uh", "ah", "eh", "like", "actually", "basically", "so", "you know", "well",
        // Turkish
        "şey", "yani", "eee", "hım", "mesela", "bence", "falan", "filan",
        // Finnish
        "tota", "niinku", "niin", "eli", "joo", "oikeesti", "totta"
    ]
    
    func resetSession() {
        startTime = nil
        totalWordsCount = 0
        fillerCount = 0
        wpm = 0.0
        fillerWordsCount = 0
        fillerWordsRatio = 0.0
        pacingFeedback = "Ready"
        sessionTranscripts.removeAll()
    }
    
    func processTranscriptSegment(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        
        sessionTranscripts.append(clean)
        
        if startTime == nil {
            startTime = Date()
        }
        
        // Split segment into words
        let words = clean.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else { return }
        
        totalWordsCount += words.count
        
        // Count filler words
        for word in words {
            if fillerWords.contains(word) {
                fillerCount += 1
            }
        }
        
        // Calculate dynamic WPM based on elapsed time
        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 1.5 { // Debounce extremely short durations
                let minutes = elapsed / 60.0
                wpm = Double(totalWordsCount) / minutes
            } else {
                wpm = Double(totalWordsCount) * 12.0 // Assume ~5 seconds estimation
            }
        }
        
        fillerWordsCount = fillerCount
        
        if totalWordsCount > 0 {
            fillerWordsRatio = (Double(fillerCount) / Double(totalWordsCount)) * 100.0
        }
        
        // Pacing categorization
        updatePacingFeedback()
    }
    
    private func updatePacingFeedback() {
        if wpm == 0 {
            pacingFeedback = "Ready"
        } else if wpm < 100 {
            pacingFeedback = "Slow pace (WPM: \(Int(wpm))) - Speak slightly faster"
        } else if wpm <= 150 {
            pacingFeedback = "Ideal pace (WPM: \(Int(wpm)))"
        } else if wpm <= 180 {
            pacingFeedback = "Fast pace (WPM: \(Int(wpm))) - Try to slow down"
        } else {
            pacingFeedback = "Too Fast! (WPM: \(Int(wpm))) - Take a breath"
        }
    }
}
