import Foundation
import Combine

@MainActor
class SpeechAnalyticsService: ObservableObject {
    static let shared = SpeechAnalyticsService()
    
    @Published var wpm: Double = 0.0
    @Published var fillerWordsCount: Int = 0
    @Published var fillerWordsRatio: Double = 0.0 // dolgu kelimelerinin yüzdesi
    @Published var pacingFeedback: String = "Not Speaking"
    @Published var sessionTranscripts: [String] = []
    
    private var startTime: Date?
    private var totalWordsCount = 0
    private var fillerCount = 0
    
    // Çok dilli dolgu kelimeleri listesi
    private let fillerWords: Set<String> = [
        // İngilizce
        "um", "uh", "ah", "eh", "like", "actually", "basically", "so", "you know", "well",
        // Türkçe
        "şey", "yani", "eee", "hım", "mesela", "bence", "falan", "filan",
        // Fince
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
        
        // Parçayı kelimelere böl
        let words = clean.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else { return }
        
        totalWordsCount += words.count
        
        // Dolgu kelimelerini say
        for word in words {
            if fillerWords.contains(word) {
                fillerCount += 1
            }
        }
        
        // Geçen süreye göre dinamik WPM hesapla
        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 1.5 { // Aşırı kısa süreleri birleştir
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
        
        // Hız kategorizasyonu
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
