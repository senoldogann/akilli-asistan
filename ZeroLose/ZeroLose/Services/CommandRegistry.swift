import Foundation

/// Registry of safest and most common AppleScripts for system control.
struct CommandRegistry {
    
    enum SystemAction {
        case setVolume(Int)
        case openApp(String)
        case emptyTrash
        case toggleMute
        case screenshot
        
        var script: String {
            switch self {
            case .setVolume(let level):
                return "set volume output volume \(level)"
            case .openApp(let name):
                return "tell application \"\(name)\" to activate"
            case .emptyTrash:
                return "tell application \"Finder\" to empty trash"
            case .toggleMute:
                return "set isMuted to output muted of (get volume settings)\nset volume output muted not isMuted"
            case .screenshot:
                // Uses native screencapture utility
                return "do shell script \"screencapture -c\"" // Capture to clipboard
            }
        }
    }
    
    /// Generates specialized scripts for complex app interactions
    static func scriptFor(app: String, action: String) -> String {
        switch app.lowercased() {
        case "safari", "google chrome":
            return "tell application \"\(app)\" to open location \"https://www.google.com/search?q=\(action.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")\""
        case "spotify":
            if action.lowercased() == "play" || action.lowercased() == "pause" {
                return "tell application \"Spotify\" to playpause"
            }
            return "tell application \"Spotify\" to play track \"\(action)\""
        default:
            return "tell application \"\(app)\" to \(action)"
        }
    }
}
