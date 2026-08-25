import Foundation
import Combine
import SwiftUI
import os

@MainActor
class MockInterviewService: ObservableObject {
    static let shared = MockInterviewService()
    private static let logger = Logger(subsystem: "com.zerolose", category: "mock-interview")
    
    @Published var isSessionActive = false
    @Published var isLoading = false
    @Published var currentQuestionIndex = 0
    @Published var questions: [String] = []
    @Published var multipleChoiceOptions: [[String]] = []
    @Published var userAnswers: [String] = []
    @Published var evaluations: [MockInterviewEvaluation] = []
    @Published var currentEvaluation: MockInterviewEvaluation? = nil
    
    @Published var isListeningToUser = false
    @Published var recognizedAnswerSoFar = ""

    /// false olduğunda sorular yalnızca ekranda gösterilir ve asla sesli okunmaz.
    /// Otomatik sesin dikkat dağıtıcı olacağı sınav/sessiz ortamlarda kullanışlıdır.
    @Published var speakQuestionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(speakQuestionsEnabled, forKey: "mockInterviewSpeakQuestions")
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    private let ollamaService = DependencyContainer.shared.ollamaService
    private let audioService = DependencyContainer.shared.audioService
    
    private init() {
        self.speakQuestionsEnabled = UserDefaults.standard.bool(forKey: "mockInterviewSpeakQuestions")
        // Aktif dinleme durumundayken ses transkriptlerini dinamik olarak izle
        audioService.$lastVoiceTranscript
            .sink { [weak self] transcript in
                guard let self = self, self.isListeningToUser, !transcript.isEmpty else { return }
                // Aktif konuşma sırasında transkriptleri birleştir
                if self.recognizedAnswerSoFar.isEmpty {
                    self.recognizedAnswerSoFar = transcript
                } else {
                    self.recognizedAnswerSoFar += " " + transcript
                }
            }
            .store(in: &cancellables)
    }
    
    func startMockInterview() async {
        let cv = UserDefaults.standard.string(forKey: "userPersonaContext") ?? ""
        let jd = UserDefaults.standard.string(forKey: "activeJobDescription") ?? ""
        
        guard !jd.isEmpty else {
            Self.logger.error("Job Description is empty. Cannot start mock interview.")
            return
        }
        
        isLoading = true
        isSessionActive = true
        currentQuestionIndex = 0
        questions.removeAll()
        multipleChoiceOptions.removeAll()
        userAnswers.removeAll()
        evaluations.removeAll()
        currentEvaluation = nil
        recognizedAnswerSoFar = ""
        isListeningToUser = false
        
        // Karma bir set üretmek için prompt oluştur: 2 çoktan seçmeli hatırlama kontrolü
        // ve ardından 3 açık uçlu senaryo sorusu. Formatları karıştırmak hem hızlı
        // bilgi doğrulaması hem de daha derin davranışsal yanıtlar sağlar.
        let prompt = """
        You are an elite technical interviewer. Generate exactly 5 challenging technical interview questions based on the candidate profile and the target job description.
        The first 2 must be multiple-choice (with 4 options each). The last 3 must be open-ended.
        
        Candidate Context:
        \(cv)
        
        Job Description:
        \(jd)
        
        Return ONLY a JSON object with this exact shape (no markdown wrapping):
        {
          "questions": [
            {"text": "MCQ 1", "options": ["A", "B", "C", "D"]},
            {"text": "MCQ 2", "options": ["A", "B", "C", "D"]},
            {"text": "Open question 1", "options": []},
            {"text": "Open question 2", "options": []},
            {"text": "Open question 3", "options": []}
          ]
        }
        Do not include an "answerIndex" — the model must not reveal the correct
        option. The evaluator will judge the candidate's chosen option later.
        """
        
        do {
            let response = try await ollamaService.generate(
                messages: [OllamaService.ChatMessage(role: "user", content: prompt, images: nil)],
                model: AIModelNames.fast
            )
            
            let cleaned = cleanJsonString(response)
            if let data = cleaned.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(InterviewQuestionSet.self, from: data),
               !parsed.questions.isEmpty {
                self.questions = parsed.questions.map(\.text)
                self.multipleChoiceOptions = parsed.questions.map(\.options)
                self.isLoading = false
                self.presentCurrentQuestion()
            } else {
                Self.logger.warning("Mülakat soru seti JSON olarak ayrıştırılamadı; yedek sorulara düşülüyor.")
                // JSON ayrıştırma başarısız olursa yedek sorular
                self.questions = [
                    "Which data structure is most appropriate for a priority queue?",
                    "Which HTTP status code correctly represents a successfully created resource?",
                    "Can you describe your experience with high-scale architecture and how you optimize performance?",
                    "How do you handle API security and prevent vulnerabilities like OWASP Top 10 in your backend services?",
                    "Can you explain your workflow for testing, and the integration patterns you prefer?"
                ]
                self.multipleChoiceOptions = [
                    ["Linked list", "Binary heap", "Hash map", "Array"],
                    ["200 OK", "201 Created", "204 No Content", "302 Found"],
                    [], [], []
                ]
                self.isLoading = false
                self.presentCurrentQuestion()
            }
        } catch {
            Self.logger.error(
                "Failed to generate interview questions: \(error.localizedDescription, privacy: .public)"
            )
            self.isLoading = false
            self.isSessionActive = false
        }
    }
    
    func presentCurrentQuestion() {
        guard currentQuestionIndex < questions.count else { return }
        let question = questions[currentQuestionIndex]
        
        recognizedAnswerSoFar = ""
        isListeningToUser = false
        currentEvaluation = nil

        // Yalnızca kullanıcı tercih ettiyse sesli oku. Sınavlar sırasında kullanıcı
        // sessizce okumayı ve sesi manuel kontrol etmeyi tercih edebilir.
        guard speakQuestionsEnabled else { return }
        
        SpeechSynthesizerService.shared.speak(question) {
            // Konuşma tamamlandığında kullanıcı yanıtını kaydetmeye başla
            Task { @MainActor in
                self.startListeningToUser()
            }
        }
    }
    
    func startListeningToUser() {
        recognizedAnswerSoFar = ""
        isListeningToUser = true
        if !audioService.isListening {
            audioService.startListening()
        }
        SpeechAnalyticsService.shared.resetSession()
    }
    
    func stopListeningAndEvaluate() async {
        isListeningToUser = false
        audioService.stopListening()
        
        let answer = recognizedAnswerSoFar.trimmingCharacters(in: .whitespacesAndNewlines)
        userAnswers.append(answer)
        
        guard currentQuestionIndex < questions.count else { return }
        let question = questions[currentQuestionIndex]
        
        isLoading = true
        
        let prompt = """
        You are an expert interviewer evaluating a candidate's response.
        
        Question:
        \(question)
        
        Candidate's Response:
        \(answer.isEmpty ? "[No response given]" : answer)
        
        Evaluate the response. Return a JSON object with:
        - "score": integer from 1 to 10
        - "positives": array of strings (what they did well)
        - "improvements": array of strings (what they missed or could explain better)
        - "sampleAnswer": string (a comprehensive 10/10 sample response)
        
        Do NOT write markdown wrapping. Return ONLY valid JSON.
        """
        
        do {
            let response = try await ollamaService.generate(
                messages: [OllamaService.ChatMessage(role: "user", content: prompt, images: nil)],
                model: AIModelNames.fast
            )
            
            let cleaned = cleanJsonString(response)
            if let data = cleaned.data(using: .utf8),
               let evaluation = try? JSONDecoder().decode(MockInterviewEvaluation.self, from: data) {
                self.currentEvaluation = evaluation
                self.evaluations.append(evaluation)
            } else {
                Self.logger.warning("Mülakat değerlendirmesi JSON olarak ayrıştırılamadı; yedek değerlendirmeye düşülüyor.")
                // Yedek değerlendirme
                let fallback = MockInterviewEvaluation(
                    score: answer.isEmpty ? 1 : 7,
                    positives: ["Attempted to answer the technical question."],
                    improvements: ["Could provide more architectural details and specific metrics."],
                    sampleAnswer: "A great answer would cover structural design patterns, performance gates, and testing details."
                )
                self.currentEvaluation = fallback
                self.evaluations.append(fallback)
            }
            
            isLoading = false
            
            // Değerlendirme özetini sesli oku
            if let score = currentEvaluation?.score {
                let text = "I've evaluated your response. Your score is \(score) out of 10. Let's move to the next question when you are ready."
                SpeechSynthesizerService.shared.speak(text)
            }
        } catch {
            Self.logger.error(
                "Failed to evaluate answer: \(error.localizedDescription, privacy: .public)"
            )
            isLoading = false
        }
    }

    /// Kullanıcının çoktan seçmeli soru için seçtiği seçeneği kaydeder ve
    /// sözlü yanıt gerektirmeden değerlendirir.
    func submitMultipleChoiceAnswer(_ option: String) async {
        guard currentQuestionIndex < questions.count else { return }
        let question = questions[currentQuestionIndex]
        let options = multipleChoiceOptions[currentQuestionIndex]
        userAnswers.append(option)

        isLoading = true

        let prompt = """
        You are an expert technical interviewer grading a multiple-choice question.

        Question:
        \(question)

        Options:
        \(options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Candidate chose:
        \(option)

        First state whether the choice is correct or incorrect (be lenient if the
        wording differs but the meaning matches). Then explain why, and give a
        one-paragraph sample answer that a 10/10 candidate would give.
        Return ONLY a JSON object with:
        - "score": integer from 1 to 10
        - "positives": array of strings
        - "improvements": array of strings
        - "sampleAnswer": string
        No markdown wrapping.
        """

        do {
            let response = try await ollamaService.generate(
                messages: [OllamaService.ChatMessage(role: "user", content: prompt, images: nil)],
                model: AIModelNames.fast
            )
            let cleaned = cleanJsonString(response)
            if let data = cleaned.data(using: .utf8),
               let evaluation = try? JSONDecoder().decode(MockInterviewEvaluation.self, from: data) {
                self.currentEvaluation = evaluation
                self.evaluations.append(evaluation)
            } else {
                Self.logger.warning("Çoktan seçmeli yanıt değerlendirmesi JSON olarak ayrıştırılamadı; yedek değerlendirmeye düşülüyor.")
                let fallback = MockInterviewEvaluation(
                    score: 6,
                    positives: ["Selected an option."],
                    improvements: ["Review the explained reasons behind the correct choice."],
                    sampleAnswer: "A strong answer explains the reasoning, trade-offs, and when alternatives are preferable."
                )
                self.currentEvaluation = fallback
                self.evaluations.append(fallback)
            }
            isLoading = false
            if let score = currentEvaluation?.score, speakQuestionsEnabled {
                SpeechSynthesizerService.shared.speak("Your score for this question is \(score) out of 10.")
            }
        } catch {
            Self.logger.error("Failed to evaluate MCQ answer: \(error.localizedDescription, privacy: .public)")
            isLoading = false
        }
    }
    
    func nextQuestion() {
        currentEvaluation = nil
        currentQuestionIndex += 1
        
        if currentQuestionIndex < questions.count {
            presentCurrentQuestion()
        } else {
            isSessionActive = false
        }
    }
    
    func endSession() {
        isSessionActive = false
        SpeechSynthesizerService.shared.stop()
        audioService.stopListening()
    }
    
    private func cleanJsonString(_ input: String) -> String {
        var clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") {
            clean = String(clean.dropFirst(7))
        }
        if clean.hasSuffix("```") {
            clean = String(clean.dropLast(3))
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MockInterviewEvaluation: Codable, Identifiable {
    var id: UUID { UUID() }
    let score: Int
    let positives: [String]
    let improvements: [String]
    let sampleAnswer: String
}

struct InterviewQuestion: Codable {
    let text: String
    let options: [String]
}

struct InterviewQuestionSet: Codable {
    let questions: [InterviewQuestion]
}
