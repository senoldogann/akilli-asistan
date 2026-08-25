import Foundation

/// MacOS otomasyonu için doğrulanmış AppleScript komutlarının kapsamlı kütüphanesi.
/// AI halüsinasyonlarını önlemek için "Tek Doğruluk Kaynağı" görevi görür.
struct AutomationLibrary {
    
    struct System {
        static let setVolume = "set volume output volume %d" // String(format:) kullan
        static let mute = "set volume output muted true"
        static let unmute = "set volume output muted false"
        static let safeEmptyTrash = """
        tell application "Finder"
            set trashCount to count of items of trash
            if trashCount is 0 then
                return "Trash already empty"
            else
                empty trash
                return "Trash emptied: " & trashCount
            end if
        end tell
        """
        static let sleep = "tell application \"Finder\" to sleep"
        static let screenSaver = "tell application \"System Events\" to start current screen saver"
        static let lockScreen = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        static let minimizeAll = "tell application \"Finder\" to set collapsed of every window to true"
        static let screenshotClipboard = "do shell script \"screencapture -c\""
    }
    
    struct Finder {
        static let cleanDesktop = """
        tell application "Finder"
            set arrangement of icon view options of window of desktop to not arranged
            set arrangement of icon view options of window of desktop to arranged by name
            clean up window of desktop
        end tell
        """
        static let closeAllFinderWindows = "tell application \"Finder\" to close every window"
        static let showHiddenFiles = "do shell script \"defaults write com.apple.finder AppleShowAllFiles -bool true; killall Finder\""
        static let hideHiddenFiles = "do shell script \"defaults write com.apple.finder AppleShowAllFiles -bool false; killall Finder\""
    }
    
    struct Browser {
        static func chromeOpen(url: String) -> String {
            return "tell application \"Google Chrome\" to open location \"\(url)\""
        }
        
        static func safariOpen(url: String) -> String {
            return "tell application \"Safari\" to open location \"\(url)\""
        }
        
        static let chromePause = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "youtube.com" then execute t javascript "document.querySelector('video').pause()"
                end repeat
            end repeat
        end tell
        """
        
        static let safariPause = """
        tell application "Safari"
            repeat with t in tabs of windows
                if URL of t contains "youtube.com" then do JavaScript "document.querySelector('video').pause()" in t
            end repeat
        end tell
        """
        
        // Sağlam Arama & Oynatma
        static func chromeSearchAndPlay(query: String) -> String {
             return """
             tell application "Google Chrome"
                 open location "https://www.youtube.com/results?search_query=\(query)"
                 delay 2
                 execute front window's active tab javascript "document.querySelector('ytd-video-renderer a#video-title').click()"
             end tell
             """
        }
    }
    
    struct Media {
        static let spotifyPlayPause = "tell application \"Spotify\" to playpause"
        static let spotifyNext = "tell application \"Spotify\" to next track"
        static let spotifyPrev = "tell application \"Spotify\" to previous track"
        static let musicPlayPause = "tell application \"Music\" to playpause"
    }
    
    struct AppControl {
        static func closeApp(_ name: String) -> String {
            return "tell application \"\(name)\" to quit"
        }
        
        static func activateApp(_ name: String) -> String {
            return "tell application \"\(name)\" to activate"
        }
    }
    
    /// AI Prompt'una enjekte edilecek yeteneklerin tam listesini döndürür.
    static func getPromptContext() -> String {
        // JSON yükü için kaçış (tırnak ve satır sonlarının kaçışı gerekir)
        func escape(_ script: String) -> String {
            return script
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        
        return """
        VERIFIED AUTOMATION LIBRARY (USE THESE TEMPLATES):
        
        1. SYSTEM:
           - Mute: [ACTION: {"type": "applescript", "payload": "\(System.mute)"}]
           - Volume (50%): [ACTION: {"type": "applescript", "payload": "set volume output volume 50"}]
           - Sleep: [ACTION: {"type": "applescript", "payload": "\(System.sleep)"}]
           
        2. FINDER:
           - Clean Desktop: [ACTION: {"type": "applescript", "payload": "\(escape(Finder.cleanDesktop))"}]
           
        3. BROWSER (Chrome/Safari):
           - Search & Play (YouTube): Open URL, delay 2s, click first video.
           - Pause All YouTube: Use the multi-line iteration script.
           
        4. MEDIA:
           - Spotify Play/Pause: [ACTION: {"type": "applescript", "payload": "\(escape(Media.spotifyPlayPause))"}]
           
        5. APPS:
           - Close App: tell application "Name" to quit
        """
    }
}
