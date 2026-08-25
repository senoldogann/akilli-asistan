import SwiftUI

extension Color {
    static var brandPrimary: Color {
        let theme = UserDefaults.standard.string(forKey: "selectedThemeName") ?? "Red"
        return ThemeStore.accent(for: theme)
    }

    // Liquid Glass design tokens
    static let glassStroke    = Color.white.opacity(0.18)
    static let glassStrokeHi  = Color.white.opacity(0.32)
    static let glassFill      = Color.white.opacity(0.05)
    static let glassShadow    = Color.black.opacity(0.45)
    static let textPrimary    = Color.white.opacity(0.95)
    static let textSecondary  = Color.white.opacity(0.55)

    // Legacy aliases kept for backward compatibility
    static let zeroBackground = Color.clear
    static let zeroHeader     = Color.white.opacity(0.06)
}
