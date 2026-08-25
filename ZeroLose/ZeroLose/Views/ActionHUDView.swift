import SwiftUI
import Combine

struct ActionHUDView: View {
    let action: String
    @State private var animateShimmer = false
    @State private var dotCount = 0
    private let dotTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    
    var body: some View {
        let content = HStack(spacing: 12) {
            // Animasyonlu Nabız Göstergesi
            ZStack {
                Circle()
                    .fill(Color.brandPrimary.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .scaleEffect(1.2)
                
                Circle()
                    .fill(Color.brandPrimary)
                    .frame(width: 12, height: 12)
            }
            .pulseAnimation()
            
            VStack(alignment: .leading, spacing: 2) {
                Text("AGENT ACTIVE" + String(repeating: ".", count: dotCount))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.brandPrimary)
                
                Text(action)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        
        return content
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color(white: 0.1).opacity(0.9))
                
                RoundedRectangle(cornerRadius: 30)
                    .stroke(Color.brandPrimary.opacity(0.4), lineWidth: 1)
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        .transition(.move(edge: .top).combined(with: .opacity))
        .overlay(
            LinearGradient(
                colors: [.clear, .white.opacity(0.65), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 80)
            .offset(x: animateShimmer ? 220 : -100)
            .blendMode(.plusLighter)
            .clipShape(
                RoundedRectangle(cornerRadius: 30)
            )
        )
        .clipped()
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

// Nabız için yardımcı genişletme
extension View {
    func pulseAnimation() -> some View {
        self.modifier(PulseEffect())
    }
}

struct PulseEffect: ViewModifier {
    @State private var pulse: CGFloat = 1.0
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(pulse)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = 1.2
                }
            }
    }
}
