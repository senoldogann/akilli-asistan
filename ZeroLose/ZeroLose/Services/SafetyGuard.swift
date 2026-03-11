import Foundation
import os

struct SafetyGuard {
    private static let logger = Logger(subsystem: "com.zerolose", category: "security")

    /// Returns true if the script is considered dangerous (e.g. permanent deletion outside trash)
    static func isDangerous(_ payload: String, type: String) -> Bool {
        let lowerPayload = payload.lowercased()

        // 1. GLOBAL BLACKLIST (Keywords & Patterns)
        let blacklistedTerms = [
            "rm ", "mkfs", "dd ", "> /dev/", "format ",
            "shutdown", "reboot", "sudo ", "su ", "passwd",
            "chmod -r", "chown -r", "launchctl unload",
            "systemsetup", "networksetup", "nc ", "netcat ",
            "crontab ", "ssh ", "sftp ", "scp ",
            "curl ", "wget "
        ]

        for term in blacklistedTerms {
            if lowerPayload.contains(term) {
                // Allow "rm" only if it's not recursive or if it's safe (very strict)
                if term == "rm " && !lowerPayload.contains("-rf") && !lowerPayload.contains("-r") {
                    continue
                }
                logger.warning("🛡️ SafetyGuard: Blocked keyword '\(term)'")
                return true
            }
        }

        // 2. PATH SENSITIVITY (Regex for Home/System paths)
        // Detect patterns like rm -rf /, rm -rf ~, rm -rf $HOME, /etc/*, /Library/*
        let dangerousPathPatterns = [
            #"/(\s|$)"#,                  // Root /
            #"~\s"#,                        // Home ~
            #"\$home"#,                     // $HOME
            #"/etc/"#,                      // System config
            #"/library/"#,                  // System Library
            #"/system/"#,                   // macOS System
            #"\.\./"#,                      // Path traversal
            #"\|\s*(sh|bash|zsh|zsh-)"#,    // Piping to shell
            #"(curl|wget).*\|\s*sh"#,       // Remote script execution
            #"osascript\s+-e"#              // Indirect AppleScript execution
        ]

        for pattern in dangerousPathPatterns {
            if lowerPayload.range(of: pattern, options: .regularExpression) != nil {
                logger.warning("🛡️ SafetyGuard: Blocked dangerous path/pattern '\(pattern)'")
                return true
            }
        }

        // 3. APPLESCRIPT SPECIFIC (Execution bypasses)
        if type == "applescript" {
            // Only allow one tightly scoped shell bridge for clipboard screenshot.
            if lowerPayload.contains("do shell script") &&
                !lowerPayload.contains("do shell script \"screencapture -c\"") {
                logger.warning("🛡️ SafetyGuard: Blocked AppleScript shell bridge")
                return true
            }

            let dangerousAppleScriptTerms = [
                "run script",
                "eval",
                "tell application \"terminal\"",
                "tell application \"iterm\""
            ]
            for term in dangerousAppleScriptTerms where lowerPayload.contains(term) {
                logger.warning("🛡️ SafetyGuard: Blocked AppleScript term '\(term)'")
                return true
            }

            if lowerPayload.contains("do shell script \"screencapture -c\"") {
                // Keep this explicit allowlist narrow.
                let containsAnythingElse = lowerPayload.replacingOccurrences(
                    of: "do shell script \"screencapture -c\"",
                    with: ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !containsAnythingElse.isEmpty {
                    logger.warning("🛡️ SafetyGuard: Blocked mixed shell payload in AppleScript")
                    return true
                }
            }
        }

        return false
    }

    /// Sanity check for recurring task intervals
    static func validateInterval(_ interval: Double) -> Double {
        return max(0.5, interval) // Minimum 0.5s to prevent CPU overload
    }
}
