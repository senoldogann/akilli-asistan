import SwiftUI

struct TeleprompterView: View {
    @AppStorage("teleprompterText") private var teleprompterText: String = ""
    @Binding var isPresented: Bool
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    
    // Helper to get dynamic color
    private var themeColor: Color {
        switch selectedTheme {
        case "Red": return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange": return Color.orange
        case "Blue": return Color.blue
        case "Purple": return Color.purple
        case "Green": return Color.green
        case "Graphite": return Color(white: 0.3)
        default: return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Drag Area
            HStack {
                HStack(spacing: 8) {
                    ZeroLoseIcon(type: .textbubble, color: themeColor, size: 14)
                    Text("INTERVIEW NOTES")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .kerning(1)
                }
                
                Spacer()
                
                Button(action: { isPresented = false }) {
                    ZeroLoseIcon(type: .xmark, color: .white.opacity(0.4), size: 12)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.01))
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Editor
            ZStack {
                if teleprompterText.isEmpty {
                    Text("Type or paste your interview notes here...")
                        .font(.system(size: fontSize + 1, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                
                TextEditor(text: $teleprompterText)
                    .font(.system(size: fontSize + 1, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            .background(Color.black.opacity(0.2))
        }
        .background(Color.zeroBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .preferredColorScheme(.dark)
    }
}
