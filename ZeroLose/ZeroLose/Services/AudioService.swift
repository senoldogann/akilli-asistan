import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import os

/// Shared-access audio service using AVCaptureSession and ScreenCaptureKit
/// Allows ZeroLose and Google Meet to use microphone simultaneously and captures system audio digitally
@MainActor
class AudioService: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    @Published var lastVoiceTranscript: String = ""
    @Published var lastVoiceLanguage: String? = nil
    @Published var currentSpeaker: String? = nil
    
    // Dependencies
    private let groqService: GroqService
    private let logger = Logger.audio
    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    
    // ScreenCaptureKit for System Audio (Echo-free)
    private var scStream: SCStream?
    
    private var isProcessing = false
    private var lastTranscriptCache: String = ""
    private let targetSampleRate: Float64 = 16000.0 // Groq optimal: 16kHz mono
    
    // VAD Configuration (Sensitivity and natural pauses optimization)
    private let silenceThreshold: Float = 0.05
    private let maxSilenceDuration: Double = 0.65 // Faster flush for live interview turn-taking
    private let minSpeechDuration: Double = 0.45
    private let minRMSForTranscription: Float = 0.03  
    
    // Hallucination Blocklist
    private let hallucinationBlocklist = [
        "thank you", "thanks", "tack", "kiitos", "you", "copyright", "subtitles", "youtube", "watching", "amara.org",
        "please like", "subscribe", "bye bye", "goodbye", "hello", "hi", "hey", ".", "...", "---",
        "tack så", "kiitoksia", "huomenta", "iltaa", "kiitos katsomisesta", "thank you for watching",
        "transcribed by", "subtitle", "texting", "studentinvest", "training session", "instrument in the", "outlook",
        "metall", "razvitiya", "成功", "circo"
    ]
    
    // Audio Buffer Actor (Thread-Safe)
    private let bufferActor = AudioBufferActor()
    
    // Processing Queue
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
        
        // Configure capture session for shared access
        captureSession.sessionPreset = .high
        
        // Setup audio output delegate
        audioOutput.setSampleBufferDelegate(self, queue: processingQueue)
        
        // Listen for device changes (AirPods, etc.)
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
    
    // MARK: - Public Methods
    
    func startListening() {
        guard !isListening else { return }
        
        // Check audio source preference
        // useExternalAudio = true  -> Microphone ONLY (your voice + external sounds)
        // useExternalAudio = false -> System Audio ONLY (Google Meet, Zoom, etc.)
        let useExternalAudio = UserDefaults.standard.bool(forKey: "useExternalAudio")
        
        if useExternalAudio {
            // MICROPHONE MODE: Capture from default mic
            logger.info("🎤 Starting Microphone-Only Mode...")
            startMicrophoneCapture()
        } else {
            // SYSTEM AUDIO MODE: Capture only digital audio from apps (No mic!)
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
    
    // MARK: - ScreenCaptureKit (No-Echo)
    
    private func startSystemAudioCapture() {
        Task {
            do {
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
                
                // Silent Video Fix: Set minimum resolution and frame rate to stop 'output NOT found' log spam
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 frame per second
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
                
                // Add a dummy video output to 'consume' the video frames and stop the ERROR logs
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
        // Extract audio samples
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        
        // Get audio format
        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let asbd = audioStreamBasicDescription?.pointee else { return }
        
        // Get sample count
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        if numSamples <= 0 { return }
        
        // Get audio data
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let audioData = dataPointer else { return }
        
        // Convert to Float32 array
        let float32Data = audioData.withMemoryRebound(to: Float32.self, capacity: numSamples) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: numSamples))
        }
        
        // Process audio (VAD + buffering)
        Task {
            await processAudioSamples(float32Data, sampleRate: asbd.mSampleRate)
        }
    }
    
    private func processAudioSamples(_ samples: [Float], sampleRate: Float64) async {
        let resampled = resample(samples, from: sampleRate, to: targetSampleRate)
        
        // RMS energy calculation for VAD
        let rms = sqrt(resampled.map { $0 * $0 }.reduce(0, +) / Float(resampled.count))
        let isSpeech = rms > silenceThreshold
        
        // DEBUG: Log RMS levels to diagnose audio capture
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
        
        // Calculate RMS for the entire segment FIRST
        let segmentRMS = sqrt(frames.map { $0 * $0 }.reduce(0, +) / Float(frames.count))
        let durationSeconds = Double(frames.count) / sampleRate
        
        // RMS GATE: Don't waste API calls on quiet/silent audio
        let rmsThreshold = self.minRMSForTranscription
        guard segmentRMS >= rmsThreshold else {
            logger.info("⏭️ Skipping quiet segment: RMS \(String(format: "%.4f", segmentRMS)) < threshold \(rmsThreshold)")
            return
        }
        
        do {
            // PHASE: Memory-only WAV generation
            let wavData = try generateWavData(frames: frames, sampleRate: Int(sampleRate))
            
            logger.info("📊 Audio Segment: \(String(format: "%.2f", durationSeconds))s @ \(Int(sampleRate))Hz | RMS: \(String(format: "%.4f", segmentRMS))")
            
            let selectedLanguage = UserDefaults.standard.string(forKey: "audioLanguage") ?? "auto"
            let transcribeLanguage = selectedLanguage == "auto" ? nil : selectedLanguage
            
            // Dynamic context-aware prompt based on selected language
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
                language: transcribeLanguage, // Dynamic language selection (nil = auto)
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
            
            // AGGRESSIVE Hallucination & Nonsense filtering
            let lowerText = cleanText.lowercased().trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check blocklist
            let isHallucination = hallucinationBlocklist.contains { block in
                lowerText == block || (lowerText.contains(block) && block.count > 5)
            }
            
            if !self.lastTranscriptCache.isEmpty {
                logger.info("📎 Context prefix exists (Length: \(self.lastTranscriptCache.count))")
            }
            
            // Detect foreign scripts that shouldn't appear in Finnish/English speech
            let hasCyrillic = cleanText.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
            let hasChinese = cleanText.range(of: "\\p{Han}", options: .regularExpression) != nil
            let hasGreek = cleanText.range(of: "\\p{Greek}", options: .regularExpression) != nil
            let hasKorean = cleanText.range(of: "\\p{Hangul}", options: .regularExpression) != nil
            let hasJapanese = cleanText.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil
            let hasArabic = cleanText.range(of: "\\p{Arabic}", options: .regularExpression) != nil
            
            // If ANY foreign script detected, it's hallucination
            let hasForeignScript = hasCyrillic || hasChinese || hasGreek || hasKorean || hasJapanese || hasArabic
            
            // Require minimum word count (at least 3 real words)
            // Relaxed requirement: Allow single words if they're not in the blocklist 
            // and are long enough to be meaningful (e.g. "Düşünüyorum")
            let wordCount = cleanText.components(separatedBy: .whitespaces).filter { $0.count > 1 }.count
            let tooShort = wordCount < 1 // Changed from 2 to 1
            
            // Check for gibberish patterns (too many consonants in a row, etc.)
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
                // Update context for next segment to maintain continuity
                self.lastTranscriptCache = cleanText
                logger.info("🗣️ Transcript accepted (length: \(cleanText.count, privacy: .public))")
                
                // Update @Published property for GhostViewModel to observe
                await MainActor.run {
                    lastVoiceLanguage = response.language
                    lastVoiceTranscript = cleanText
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
        
        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Data($0) })
        
        // data chunk
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })
        
        for sample in frames {
            let int16Sample = Int16(max(-32768, min(32767, sample * 32767)))
            data.append(withUnsafeBytes(of: int16Sample.littleEndian) { Data($0) })
        }
        
        return data
    }
}

// MARK: - Audio Buffer Actor

actor AudioBufferActor {
    private var buffer: [Float] = []
    private var isBusy: Bool = false
    private var silenceDuration: Double = 0.0
    
    func appendAndCheckSilence(_ data: [Float], chunkDuration: Double, isSpeech: Bool) -> Double {
        buffer.append(contentsOf: data)
        // Keep buffer manageable (max 2 mins for stealth app)
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
        // BUG FIX: Only return if we have enough data, but NEVER remove if we don't.
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
