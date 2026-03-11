import SwiftUI

struct ThinkingIndicator: View {
    @State private var animate = false
    
    var body: some View {
        ZStack {
            // Background Glow
            Circle()
                .fill(Color.brandPrimary.opacity(0.15))
                .frame(width: 24, height: 24)
                .blur(radius: animate ? 8 : 4)
                .scaleEffect(animate ? 1.4 : 0.9)
            
            // Core Orb
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.brandPrimary, .brandPrimary.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: .brandPrimary.opacity(0.5), radius: animate ? 6 : 2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
