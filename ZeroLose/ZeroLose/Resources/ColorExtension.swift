import SwiftUI

extension Color {
    static var brandPrimary: Color {
        let theme = UserDefaults.standard.string(forKey: "selectedThemeName") ?? "Red"
        switch theme {
        case "Red": return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange": return Color.orange
        case "Blue": return Color.blue
        case "Purple": return Color.purple
        case "Green": return Color.green
        case "Graphite": return Color(white: 0.3)
        default: return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
    }
    
    // Custom UI Colors
    static let zeroBackground = Color(red: 0.11, green: 0.11, blue: 0.11) // #1C1C1C
    static let zeroHeader = Color(red: 0.16, green: 0.16, blue: 0.16)     // #292929
}
