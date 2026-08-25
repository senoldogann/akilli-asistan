import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import os

/// AVCaptureSession ve ScreenCaptureKit kullanan paylaşımlı erişimli ses hizmeti.
/// ZeroLose ve Google Meet'in mikrofonu aynı anda kullanmasına izin verir ve sistem sesini dijital olarak yakalar.
@MainActor
class AudioService: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    @Published var lastVoiceTranscript: String = ""
    @Published var lastVoiceLanguage: String? = nil
    @Published var currentSpeaker: String? = nil
    
    // Bağımlılıklar
    private let groqService: GroqService
    private let logger = Logger.audio
    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    
    // Sistem Sesi için ScreenCaptureKit (Yankısız)
    private var scStream: SCStream?
    
    private var isProcessing = false
    private var lastTranscriptCache: String = ""
    private let targetSampleRate: Float64 = 16000.0 // Groq optimal: 16kHz mono
    
    // VAD Yapılandırması (Hassasiyet ve doğal duraklamalar optimizasyonu)
    private let silenceThreshold: Float = 0.05
    private let maxSilenceDuration: Double = 0.65 // Canlı mülakat söz alışverişi için daha hızlı boşaltma
    private let minSpeechDuration: Double = 0.45
    private let minRMSForTranscription: Float = 0.03  
    
    // Halüsinasyon Engelleme Listesi
    private let hallucinationBlocklist = [
        "thank you", "thanks", "tack", "kiitos", "you", "copyright", "subtitles", "youtube", "watching", "amara.org",
        "please like", "subscribe", "bye bye", "goodbye", "hello", "hi", "hey", ".", "...", "---",
        "tack så", "kiitoksia", "huomenta", "iltaa", "kiitos katsomisesta", "thank you for watching",
        "transcribed by", "subtitle", "texting", "studentinvest", "training session", "instrument in the", "outlook",
        "metall", "razvitiya", "成功", "circo"
    ]
    
    // Ses Tamponu Aktörü (İş Parçacığı Güvenli)
    private let bufferActor = AudioBufferActor()
    
    // İşleme Kuyruğu
    nonisolated private let processingQueue = DispatchQueue(label: "com.zerolose.audioprocessing", qos: .userInitiated)
    
    init(groqService: GroqService) {
        self.groqService = groqService
        super.init()
        setupAudio()
    }
    
    private func setupAudio() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { 
                Logger.audio.error("Audio Permission Denied")
            }
        }
        
        // Paylaşımlı erişim için yakalama oturumunu yapılandır
        captureSession.sessionPreset = .high
        
        // Ses çıkışı temsilcisini kur
        audioOutput.setSampleBufferDelegate(self, queue: processingQueue)
        
        // Cihaz değişikliklerini dinle (AirPods, vb.)
        registerForDeviceChanges()
    }
    
    private func registerForDeviceChanges() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            self.logger.info("🎧 Audio input device changed - Restarting capture session...")
            
            if self.isListening {
                Task { @MainActor in
                    self.stopListening()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.startListening()
                }
            }
        }
        
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            listenerBlock
        )
    }
    
    // MARK: - Genel Metotlar
    
    func startListening() {
        guard !isListening else { return }
        
        // Ses kaynağı tercihini kontrol et
        // useExternalAudio = true  -> Yalnızca Mikrofon (sesin + dış sesler)
        // useExternalAudio = false -> Yalnızca Sistem Sesi (Google Meet, Zoom, vb.)
        let useExternalAudio = UserDefaults.standard.bool(forKey: "useExternalAudio")
        
        if useExternalAudio {
            // MİKROFON MODU: Varsayılan mikrofondan yakala
            logger.info("🎤 Starting Microphone-Only Mode...")
            startMicrophoneCapture()
        } else {
            // SİSTEM SESİ MODU: Uygulamalardan yalnızca dijital sesi yakala (Mikrofon yok!)
            logger.info("🔊 Starting System Audio-Only Mode (No-Echo)...")
            startSystemAudioCapture()
        }
        
        isListening = true
    }
    
    private func startMicrophoneCapture() {
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            logger.error("❌ No microphone found")
            return
        }
        
        do {
            let audioInput = try AVCaptureDeviceInput(device: microphone)
            
            captureSession.inputs.forEach { captureSession.removeInput($0) }
            captureSession.outputs.forEach { captureSession.removeOutput($0) }
            
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            }
            
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }
            
            captureSession.startRunning()
            logger.info("🎤 Microphone capture started (\(microphone.localizedName))")
            
        } catch {
            logger.error("❌ Failed to start microphone: \(error.localizedDescription)")
        }
    }
    
    func stopListening() {
        guard isListening else { return }
        
        captureSession.stopRunning()
        stopSystemAudioCapture()
        
        isListening = false
        
        Task {
            await bufferActor.resetSilence()
        }
        
        logger.info("🔇 Listening stopped")
    }
    
    // MARK: - ScreenCaptureKit (Yankısız)
    
    private func startSystemAudioCapture() {
        Task {
            do {
                guard CGPreflightScreenCaptureAccess() else {
                    logger.error("Screen Recording permission is missing. Enable ZeroLose in System Settings > Privacy & Security > Screen Recording to capture system audio.")
                    return
                }

                logger.info("🔍 Step 1: Requesting SCShareableContent...")
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    logger.error("❌ SCStream Error: No display found")
                    return 
                }
                
                logger.info("🔍 Step 2: Configuring SCStream for \(display.width)x\(display.height)...")
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true 
                config.sampleRate = 48000
                config.channelCount = 1
                
                // Sessiz Video Düzeltmesi: 'output NOT found' günlük spamini durdurmak için minimum çözünürlük ve kare hızı ayarla
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 frame per second
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
                
                // Video karelerini 'tüketmek' ve HATA günlüklerini durdurmak için sahte bir video çıkışı ekle
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
                
                logger.info("🔍 Step 3: Starting Capture...")
                try await stream.startCapture()
                
                self.scStream = stream
                logger.info("✅ System Audio Capture (Direct) SUCCESS")
            } catch {
                logger.error("❌ SCStream FAILED: \(error.localizedDescription)")
            }
        }
    }
    
    private func stopSystemAudioCapture() {
        Task {
            try? await scStream?.stopCapture()
            scStream = nil
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate & SCStreamOutput

extension AudioService: AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processSampleBuffer(sampleBuffer)
    }
    
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            processSampleBuffer(sampleBuffer)
        }
    }
    
    nonisolated private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Ses örneklerini çıkar
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        
        // Ses formatını al
        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let asbd = audioStreamBasicDescription?.pointee else { return }
        
        // Örnek sayısını al
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        if numSamples <= 0 { return }
        
        // Ses verisini al
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let audioData = dataPointer else { return }
        
        // Float32 dizisine dönüştür
        let float32Data = audioData.withMemoryRebound(to: Float32.self, capacity: numSamples) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: numSamples))
        }
        
        // Sesi işle (VAD + tamponlama)
        Task {
            await processAudioSamples(float32Data, sampleRate: asbd.mSampleRate)
        }
    }
    
    private func processAudioSamples(_ samples: [Float], sampleRate: Float64) async {
        let resampled = resample(samples, from: sampleRate, to: targetSampleRate)
        
        // VAD için RMS enerji hesabı
        let rms = sqrt(resampled.map { $0 * $0 }.reduce(0, +) / Float(resampled.count))
        let isSpeech = rms > silenceThreshold
        
        // DEBUG: Ses yakalamayı teşhis etmek için RMS seviyelerini günlüğe yaz
        if rms > 0.01 {
            logger.debug("📊 RMS Level: \(String(format: "%.4f", rms)) | Speech: \(isSpeech)")
        }
        
        let silenceDuration = await bufferActor.appendAndCheckSilence(
            resampled, 
            chunkDuration: Double(resampled.count) / targetSampleRate, 
            isSpeech: isSpeech
        )
        
        if silenceDuration >= maxSilenceDuration {
            let minSamples = Int(targetSampleRate * minSpeechDuration)
            if let frames = await bufferActor.flushIfReady(minSamples: minSamples) {
                await bufferActor.setBusy(true)
                await sendToGroq(frames)
                await bufferActor.setBusy(false)
            }
        }
    }
    
    private func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        if sourceRate == targetRate { return samples }
        
        let ratio = sourceRate / targetRate
        let targetCount = Int(Double(samples.count) / ratio)
        guard targetCount > 0 else { return [] }
        
        var resampled = [Float]()
        resampled.reserveCapacity(targetCount)
        
        for i in 0..<targetCount {
            let sourceIndex = Double(i) * ratio
            let index = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(index))
            
            if index + 1 < samples.count {
                let sample = samples[index] * (1.0 - fraction) + samples[index + 1] * fraction
                resampled.append(sample)
            } else if index < samples.count {
                resampled.append(samples[index])
            }
        }
        return resampled
    }
    
    private func sendToGroq(_ frames: [Float]) async {
        let sampleRate = self.targetSampleRate
        
        // Önce tüm parça için RMS hesapla
        let segmentRMS = sqrt(frames.map { $0 * $0 }.reduce(0, +) / Float(frames.count))
        let durationSeconds = Double(frames.count) / sampleRate
        
        // RMS KAPISI: Sessiz/sessiz ses için API çağrılarını boşa harcama
        let rmsThreshold = self.minRMSForTranscription
        guard segmentRMS >= rmsThreshold else {
            logger.info("⏭️ Skipping quiet segment: RMS \(String(format: "%.4f", segmentRMS)) < threshold \(rmsThreshold)")
            return
        }
        
        do {
            // AŞAMA: Yalnızca bellek içi WAV üretimi
            let wavData = try generateWavData(frames: frames, sampleRate: Int(sampleRate))
            
            logger.info("📊 Audio Segment: \(String(format: "%.2f", durationSeconds))s @ \(Int(sampleRate))Hz | RMS: \(String(format: "%.4f", segmentRMS))")
            
            let selectedLanguage = UserDefaults.standard.string(forKey: "audioLanguage") ?? "auto"
            let transcribeLanguage = selectedLanguage == "auto" ? nil : selectedLanguage
            
            // Seçilen dile göre dinamik bağlam-farkındalıklı prompt
            var contextPrompt = ""
            switch selectedLanguage {
            case "fi":
                contextPrompt = "Tämä on suomenkielinen asiantuntijakeskustelu. Aiheena ohjelmistokehitys, arkkitehtuuri ja hajautetut järjestelmät."
            case "tr":
                contextPrompt = "Bu, yazılım geliştirme, mimari ve dağıtık sistemler hakkında teknik bir tartışmadır."
            case "en":
                contextPrompt = "This is a technical discussion about software development, architecture, and distributed systems."
            default:
                contextPrompt = "This is a technical discussion about software development, architecture, and distributed systems."
            }
            contextPrompt += " Keep technical terms clear."
            
            let response = try await groqService.transcribe(
                audioData: wavData, 
                prompt: contextPrompt, 
                language: transcribeLanguage, // Dinamik dil seçimi (nil = otomatik)
                enableDiarization: false
            )
            
            logger.info("📡 Groq response received (text_length: \(response.text.count, privacy: .public))")
            
            var cleanText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let segments = response.segments, !segments.isEmpty {
                // Whisper API yanıtındaki tam metni kullan (segment budama hatası giderildi)
                // Eğer segmentler varsa, sadece speaker bilgisini doğrulamak için kullanabiliriz
                // Ama metni asla son segmentle ezme!
                let speaker = response.segments?.last?.speaker ?? "Kullanıcı"
                await MainActor.run { currentSpeaker = speaker }
            } else {
                await MainActor.run { currentSpeaker = nil }
            }
            
            // AGGRESİF Halüsinasyon & Anlamsızlık filtreleme
            let lowerText = cleanText.lowercased().trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Engelleme listesini kontrol et
            let isHallucination = hallucinationBlocklist.contains { block in
                lowerText == block || (lowerText.contains(block) && block.count > 5)
            }
            
            if !self.lastTranscriptCache.isEmpty {
                logger.info("📎 Context prefix exists (Length: \(self.lastTranscriptCache.count))")
            }
            
            // Fince/İngilizce konuşmada görünmemesi gereken yabancı alfabeleri tespit et
            let hasCyrillic = cleanText.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
            let hasChinese = cleanText.range(of: "\\p{Han}", options: .regularExpression) != nil
            let hasGreek = cleanText.range(of: "\\p{Greek}", options: .regularExpression) != nil
            let hasKorean = cleanText.range(of: "\\p{Hangul}", options: .regularExpression) != nil
            let hasJapanese = cleanText.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil
            let hasArabic = cleanText.range(of: "\\p{Arabic}", options: .regularExpression) != nil
            
            // Herhangi bir yabancı alfabe tespit edilirse halüsinasyondur
            let hasForeignScript = hasCyrillic || hasChinese || hasGreek || hasKorean || hasJapanese || hasArabic
            
            // Minimum kelime sayısı iste (en az 3 gerçek kelime)
            // Gevşetilmiş gereksinim: Engelleme listesinde değilse ve anlamlı olacak kadar
            // uzunsa tek kelimelere izin ver (örn. "Düşünüyorum")
            let wordCount = cleanText.components(separatedBy: .whitespaces).filter { $0.count > 1 }.count
            let tooShort = wordCount < 1 // 2'den 1'e değiştirildi
            
            // Anlamsız kalıpları kontrol et (ardışık çok fazla ünsüz, vb.)
            let hasWeirdPatterns = cleanText.contains(".com") || cleanText.contains("www") || cleanText.contains("http")
            
            let isNonsense = hasForeignScript || tooShort || hasWeirdPatterns
            
            if isHallucination || isNonsense {
                if hasForeignScript {
                    logger.warning("🚫 Rejected: Foreign script detected: \(cleanText.prefix(50))...")
                } else if isHallucination {
                    logger.warning("🚫 Rejected: Hallucination detected (Blocklist): \(cleanText)")
                } else if tooShort {
                    logger.warning("🚫 Rejected: Too short (\(wordCount) words): \(cleanText)")
                } else if hasWeirdPatterns {
                    logger.warning("🚫 Rejected: Weird patterns (web/link): \(cleanText)")
                }
                cleanText = ""
            }
            
            if !cleanText.isEmpty && cleanText != self.lastTranscriptCache {
                // Sürekliliği korumak için sonraki parça için bağlamı güncelle
                self.lastTranscriptCache = cleanText
                logger.info("🗣️ Transcript accepted (length: \(cleanText.count, privacy: .public))")
                
                // GhostViewModel'in gözlemlemesi için @Published özelliğini güncelle
                await MainActor.run {
                    lastVoiceLanguage = response.language
                    lastVoiceTranscript = cleanText
                    SpeechAnalyticsService.shared.processTranscriptSegment(cleanText)
                }
            }
            
        } catch {
            logger.error("❌ Transcription error: \(error.localizedDescription)")
        }
    }
    
    private func generateWavData(frames: [Float], sampleRate: Int) throws -> Data {
        let numChannels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = frames.count * 2
        
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        
        // RIFF başlığı
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        
        // fmt parçası
        data.append("fmt ".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Data($0) })
        
        // data parçası
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })
        
        for sample in frames {
            let int16Sample = Int16(max(-32768, min(32767, sample * 32767)))
            data.append(withUnsafeBytes(of: int16Sample.littleEndian) { Data($0) })
        }
        
        return data
    }
}

// MARK: - Ses Tamponu Aktörü

actor AudioBufferActor {
    private var buffer: [Float] = []
    private var isBusy: Bool = false
    private var silenceDuration: Double = 0.0
    
    func appendAndCheckSilence(_ data: [Float], chunkDuration: Double, isSpeech: Bool) -> Double {
        buffer.append(contentsOf: data)
        // Tamponu yönetilebilir tut (gizli uygulama için en fazla 2 dakika)
        if buffer.count > 16000 * 120 {
            buffer.removeFirst(buffer.count - (16000 * 120))
        }
        
        if isSpeech {
            silenceDuration = 0
        } else {
            silenceDuration += chunkDuration
        }
        return silenceDuration
    }
    
    func flushIfReady(minSamples: Int) -> [Float]? {
        // HATA DÜZELTMESİ: Yeterli veri varsa yalnızca döndür, yoksa ASLA kaldırma.
        guard !isBusy && buffer.count >= minSamples else {
            return nil
        }
        
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        return data
    }
    
    func resetSilence() {
        silenceDuration = 0
        buffer.removeAll()
    }
    
    func setBusy(_ busy: Bool) { self.isBusy = busy }
}
