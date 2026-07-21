import SwiftUI

extension Color {
    static var brandPrimary: Color {
        let theme = UserDefaults.standard.string(forKey: "selectedThemeName") ?? "Red"
        switch theme {
        case "Red":      return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange":   return Color.orange
        case "Blue":     return Color(red: 0.2, green: 0.6, blue: 1.0)
        case "Purple":   return Color(red: 0.7, green: 0.3, blue: 1.0)
        case "Green":    return Color(red: 0.2, green: 0.85, blue: 0.5)
        case "Graphite": return Color(white: 0.55)
        default:         return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
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
