import SwiftUI
import Combine

struct ThinkingIndicator: View {
    @State private var animateShimmer = false
    @State private var dotCount = 0
    private let dotTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    
    var body: some View {
        let content = HStack(spacing: 6) {
            ZeroLoseIcon(type: .sparkles, color: .brandPrimary, size: 14)
                .symbolEffect(.pulse)
            
            Text("Thinking" + String(repeating: ".", count: dotCount))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.brandPrimary)
                .frame(width: 80, alignment: .leading)
        }
        
        return content
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.85), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: 60)
                .offset(x: animateShimmer ? 130 : -80)
                .blendMode(.plusLighter)
            )
            .mask(content)
            .padding(.vertical, 4)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    animateShimmer = true
                }
            }
            .onReceive(dotTimer) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    dotCount = (dotCount + 1) % 4
                }
            }
    }
}
