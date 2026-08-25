import Foundation
import AVFoundation
import Combine

@MainActor
class SpeechSynthesizerService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynthesizerService()
    
    @Published var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var onCompletion: (() -> Void)?
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    func speak(_ text: String, language: String = "en-US", onCompletion: (() -> Void)? = nil) {
        stop()
        self.onCompletion = onCompletion
        
        let utterance = AVSpeechUtterance(string: text)
        // Eşleşen sinirsel/varsayılan sesi seç
        if let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        
        // Hız oranı (0.5 varsayılan/normal)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        isSpeaking = true
        synthesizer.speak(utterance)
    }
    
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onCompletion?()
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onCompletion?()
        }
    }
}
