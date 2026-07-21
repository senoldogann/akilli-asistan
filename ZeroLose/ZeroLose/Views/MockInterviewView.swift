import SwiftUI

struct MockInterviewView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var mockService = MockInterviewService.shared
    @ObservedObject private var speechAnalytics = SpeechAnalyticsService.shared
    
    @State private var showSampleAnswer = false
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZeroLoseIcon(type: .person, color: .orange, size: 22)
                Text("Mock Interview Simulator")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    mockService.endSession()
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color.textSecondary)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
            .padding(20)
            .background(Color.black.opacity(0.12))
            .overlay(
                Rectangle()
                    .frame(height: 0.8)
                    .foregroundColor(Color.glassStroke),
                alignment: .bottom
            )
            
            // Content
            if !mockService.isSessionActive {
                setupSessionView
            } else if mockService.isLoading {
                loadingView
            } else {
                activeSessionView
            }
        }
        .frame(width: 550, height: 680)
        .background {
            ZStack {
                if #available(macOS 26.0, *) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                } else {
                    Rectangle()
                        .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.96))
                }
                
                // Subtle overlay
                Color.white.opacity(0.022)
                    .blendMode(.overlay)
            }
            .ignoresSafeArea()
        }
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.glassStroke, lineWidth: 0.8)
        )
    }
    
    // MARK: - Setup view
    
    private var setupSessionView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZeroLoseIcon(type: .brain, color: .orange, size: 64)
                .shadow(color: .orange.opacity(0.3), radius: 15)
            
            VStack(spacing: 8) {
                Text("AI Mock Technical Interview")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("ZeroLose will generate 3 highly targeted technical questions based on your CV and active Job Description, speak them aloud, and evaluate your responses.")
                    .font(.system(size: 13))
                    .foregroundColor(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            VStack(spacing: 12) {
                let cv = UserDefaults.standard.string(forKey: "userPersonaContext") ?? ""
                let jd = UserDefaults.standard.string(forKey: "activeJobDescription") ?? ""
                
                HStack {
                    Image(systemName: cv.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(cv.isEmpty ? .red : .green)
                    Text(cv.isEmpty ? "Candidate CV Context Missing" : "Candidate CV Context Loaded")
                        .font(.system(size: 12, weight: .medium))
                }
                
                HStack {
                    Image(systemName: jd.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(jd.isEmpty ? .red : .green)
                    Text(jd.isEmpty ? "Active Job Description (JD) Missing" : "Active Job Description (JD) Loaded")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(14)
            .background(Color.glassFill)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.glassStroke, lineWidth: 0.8))
            
            let jd = UserDefaults.standard.string(forKey: "activeJobDescription") ?? ""
            
            Button(action: {
                Task {
                    await mockService.startMockInterview()
                }
            }) {
                Text("Start Mock Interview")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(jd.isEmpty ? Color.gray : Color.orange)
                    .cornerRadius(22)
                    .shadow(color: jd.isEmpty ? .clear : .orange.opacity(0.3), radius: 8, x: 0, y: 3)
            }
            .disabled(jd.isEmpty)
            .buttonStyle(.interactive)
            .pointerCursor()
            
            if jd.isEmpty {
                Text("Please paste a Job Description in Settings first.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            
            Spacer()
        }
        .padding(24)
    }
    
    // MARK: - Loading view
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .tint(.orange)
            Text("AI is processing... Please wait.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.textSecondary)
            Spacer()
        }
    }
    
    // MARK: - Active Session view
    
    private var activeSessionView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Progress
                HStack {
                    Text("Question \(mockService.currentQuestionIndex + 1) of \(mockService.questions.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                    Spacer()
                }
                
                // Question Card
                if mockService.currentQuestionIndex < mockService.questions.count {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(mockService.questions[mockService.currentQuestionIndex])
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.glassFill)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                }
                
                // User Answer Area
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(mockService.isListeningToUser ? "🎤 Listening to your answer..." : "Your Answer")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(mockService.isListeningToUser ? .green : Color.textSecondary)
                        Spacer()
                    }
                    
                    Text(mockService.recognizedAnswerSoFar.isEmpty ? "Start speaking to record answer..." : mockService.recognizedAnswerSoFar)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(mockService.recognizedAnswerSoFar.isEmpty ? 0.35 : 0.95))
                        .lineSpacing(3)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                        .background(Color.black.opacity(0.18))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                }
                
                // Real-time Speaking Pace & Filler words (Speech Analytics Card)
                if mockService.isListeningToUser {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Speech Analytics (Real-Time)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.orange)
                        
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pacing")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.textSecondary)
                                Text(speechAnalytics.pacingFeedback)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Filler Words")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.textSecondary)
                                Text("\(speechAnalytics.fillerWordsCount) (\(Int(speechAnalytics.fillerWordsRatio))%)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(speechAnalytics.fillerWordsCount > 2 ? .orange : .green)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.glassFill)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.glassStroke, lineWidth: 0.5))
                }
                
                // Submit & Next Controls
                HStack(spacing: 16) {
                    if mockService.isListeningToUser {
                        Button(action: {
                            Task {
                                await mockService.stopListeningAndEvaluate()
                            }
                        }) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Submit & Evaluate")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    } else if let evaluation = mockService.currentEvaluation {
                        Button(action: {
                            mockService.nextQuestion()
                        }) {
                            HStack {
                                Text(mockService.currentQuestionIndex + 1 < mockService.questions.count ? "Next Question" : "Complete Interview")
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.orange)
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
                
                // Evaluation feedback card
                if let evaluation = mockService.currentEvaluation {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Evaluation Report")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Spacer()
                            // Score badge
                            Text("Score: \(evaluation.score)/10")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(evaluation.score >= 8 ? .green : (evaluation.score >= 5 ? .orange : .red))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background((evaluation.score >= 8 ? Color.green : (evaluation.score >= 5 ? Color.orange : Color.red)).opacity(0.12))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder((evaluation.score >= 8 ? Color.green : (evaluation.score >= 5 ? Color.orange : Color.red)).opacity(0.3), lineWidth: 0.5)
                                )
                        }
                        
                        Divider()
                            .overlay(Color.glassStroke)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What you answered well:")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.green)
                            
                            ForEach(evaluation.positives, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundColor(.green)
                                    Text(item)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.textPrimary)
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Points for improvement:")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.orange)
                            
                            ForEach(evaluation.improvements, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundColor(.orange)
                                    Text(item)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.textPrimary)
                                }
                            }
                        }
                        
                        Divider()
                            .overlay(Color.glassStroke)
                        
                        // Toggle for Sample answer
                        Button(action: {
                            withAnimation {
                                showSampleAnswer.toggle()
                            }
                        }) {
                            HStack {
                                Text(showSampleAnswer ? "Hide Sample 10/10 Answer" : "Show Sample 10/10 Answer")
                                Spacer()
                                Image(systemName: showSampleAnswer ? "chevron.up" : "chevron.down")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        
                        if showSampleAnswer {
                            Text(evaluation.sampleAnswer)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(Color.textPrimary.opacity(0.9))
                                .lineSpacing(3)
                                .padding(10)
                                .background(Color.orange.opacity(0.04))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.14), lineWidth: 0.8))
                        }
                    }
                    .padding(16)
                    .background(Color.glassFill)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                }
            }
            .padding(20)
        }
    }
}
