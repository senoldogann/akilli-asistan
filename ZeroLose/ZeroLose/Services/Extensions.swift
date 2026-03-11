import SwiftUI
import os

extension Logger {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.zerolose"

    nonisolated static let app = Logger(subsystem: subsystem, category: "App")
    nonisolated static let audio = Logger(subsystem: subsystem, category: "Audio")
    nonisolated static let vision = Logger(subsystem: subsystem, category: "Vision")
    nonisolated static let intelligence = Logger(subsystem: subsystem, category: "Intelligence")
    nonisolated static let network = Logger(subsystem: subsystem, category: "Network")
}

extension NSImage {
    /// Converts NSImage to a Base64 String (JPEG compressed)
    func base64String() -> String? {
        guard let tiffRepresentation = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        
        // Use JPEG compression (0.7 quality) to reduce payload size
        guard let imageData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        
        return imageData.base64EncodedString()
    }
}

extension View {
    /// Adds a pointing hand cursor on hover (macOS)
    func pointerCursor() -> some View {
        self.onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

/// Plain-style button with subtle hover feedback and pointer cursor.
struct InteractiveButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var hoverColor: Color = Color.white.opacity(0.08)
    var pressedColor: Color = Color.white.opacity(0.14)
    
    func makeBody(configuration: Configuration) -> some View {
        InteractiveButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hoverColor: hoverColor,
            pressedColor: pressedColor
        )
    }
    
    private struct InteractiveButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let hoverColor: Color
        let pressedColor: Color
        
        @State private var isHovered = false
        
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(configuration.isPressed ? pressedColor : (isHovered ? hoverColor : .clear))
                )
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { hovered in
                    isHovered = hovered
                    if hovered {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
        }
    }
}

extension ButtonStyle where Self == InteractiveButtonStyle {
    static var interactive: InteractiveButtonStyle { InteractiveButtonStyle() }
}

/// Native macOS Blur Effect wrapper for SwiftUI
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
