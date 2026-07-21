import Foundation
import Combine
import SwiftUI

@MainActor
class MockInterviewService: ObservableObject {
    static let shared = MockInterviewService()
    
    @Published var isSessionActive = false
    @Published var isLoading = false
    @Published var currentQuestionIndex = 0
    @Published var questions: [String] = []
    @Published var userAnswers: [String] = []
    @Published var evaluations: [MockInterviewEvaluation] = []
    @Published var currentEvaluation: MockInterviewEvaluation? = nil
    
    @Published var isListeningToUser = false
    @Published var recognizedAnswerSoFar = ""
    
    private var cancellables = Set<AnyCancellable>()
    private let ollamaService = DependencyContainer.shared.ollamaService
    private let audioService = DependencyContainer.shared.audioService
    
    private init() {
        // Observe voice transcripts dynamically when we are in active listening state
        audioService.$lastVoiceTranscript
            .sink { [weak self] transcript in
                guard let self = self, self.isListeningToUser, !transcript.isEmpty else { return }
                // Append transcripts together during active speaking
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
            print("Job Description is empty. Cannot start mock interview.")
            return
        }
        
        isLoading = true
        isSessionActive = true
        currentQuestionIndex = 0
        questions.removeAll()
        userAnswers.removeAll()
        evaluations.removeAll()
        currentEvaluation = nil
        recognizedAnswerSoFar = ""
        isListeningToUser = false
        
        // Form prompt to generate 3 questions
        let prompt = """
        You are an elite technical interviewer. Generate exactly 3 challenging technical interview questions based on the candidate profile and the target job description.
        
        Candidate Context:
        \(cv)
        
        Job Description:
        \(jd)
        
        Return ONLY a JSON array containing exactly 3 strings (the questions). Do NOT wrap it in markdown code blocks. Example format:
        ["Question 1", "Question 2", "Question 3"]
        """
        
        do {
            let response = try await ollamaService.generate(
                messages: [OllamaService.ChatMessage(role: "user", content: prompt, images: nil)],
                model: AIModelNames.fast
            )
            
            let cleaned = cleanJsonString(response)
            if let data = cleaned.data(using: .utf8),
               let parsedQuestions = try? JSONDecoder().decode([String].self, from: data) {
                self.questions = parsedQuestions
                self.isLoading = false
                speakCurrentQuestion()
            } else {
                // Fallback questions if JSON parsing fails
                self.questions = [
                    "Can you describe your experience with high-scale architecture and how you optimize performance?",
                    "How do you handle API security and prevent vulnerabilities like OWASP Top 10 in your backend services?",
                    "Can you explain your workflow for testing, and the integration patterns you prefer?"
                ]
                self.isLoading = false
                speakCurrentQuestion()
            }
        } catch {
            print("Failed to generate interview questions: \(error.localizedDescription)")
            self.isLoading = false
            self.isSessionActive = false
        }
    }
    
    func speakCurrentQuestion() {
        guard currentQuestionIndex < questions.count else { return }
        let question = questions[currentQuestionIndex]
        
        recognizedAnswerSoFar = ""
        isListeningToUser = false
        
        SpeechSynthesizerService.shared.speak(question) {
            // Once speaking completes, start recording user answer
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
                // Fallback evaluation
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
            
            // Speak evaluation overview
            if let score = currentEvaluation?.score {
                let text = "I've evaluated your response. Your score is \(score) out of 10. Let's move to the next question when you are ready."
                SpeechSynthesizerService.shared.speak(text)
            }
        } catch {
            print("Failed to evaluate answer: \(error.localizedDescription)")
            isLoading = false
        }
    }
    
    func nextQuestion() {
        currentEvaluation = nil
        currentQuestionIndex += 1
        
        if currentQuestionIndex < questions.count {
            speakCurrentQuestion()
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
