import Foundation
import os

struct SafetyGuard {
    private static let logger = Logger(subsystem: "com.zerolose", category: "security")

    /// Betik tehlikeli kabul ediliyorsa true döndürür (örn. çöp kutusu dışında kalıcı silme)
    static func isDangerous(_ payload: String, type: String) -> Bool {
        let lowerPayload = payload.lowercased()

        // 1. GLOBAL KARA LİSTE (Anahtar Kelimeler & Kalıplar)
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
                // "rm" yalnızca özyinelemeli değilse veya güvenliyse izin ver (çok katı)
                if term == "rm " && !lowerPayload.contains("-rf") && !lowerPayload.contains("-r") {
                    continue
                }
                logger.warning("🛡️ SafetyGuard: Blocked keyword '\(term)'")
                return true
            }
        }

        // 2. YOL DUYARLILIĞI (Home/Sistem yolları için Regex)
        // rm -rf /, rm -rf ~, rm -rf $HOME, /etc/*, /Library/* gibi kalıpları tespit et
        let dangerousPathPatterns = [
            #"/(\s|$)"#,                  // Kök /
            #"~\s"#,                        // Ev dizini ~
            #"\$home"#,                     // $HOME
            #"/etc/"#,                      // Sistem yapılandırması
            #"/library/"#,                  // Sistem Kütüphanesi
            #"/system/"#,                   // macOS Sistemi
            #"\.\./"#,                      // Yol geçişi
            #"\|\s*(sh|bash|zsh|zsh-)"#,    // Shell'e borulama
            #"(curl|wget).*\|\s*sh"#,       // Uzak betik çalıştırma
            #"osascript\s+-e"#              // Dolaylı AppleScript yürütme
        ]

        for pattern in dangerousPathPatterns {
            if lowerPayload.range(of: pattern, options: .regularExpression) != nil {
                logger.warning("🛡️ SafetyGuard: Blocked dangerous path/pattern '\(pattern)'")
                return true
            }
        }

        // 3. APPLESCRIPT'A ÖZGÜ (Yürütme baypasları)
        if type == "applescript" {
            // Pano ekran görüntüsü için yalnızca tek bir sıkı kapsamlı shell köprüsüne izin ver.
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
                // Bu açık izin listesini dar tut.
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

    /// Yinelenen görev aralıkları için tutarlılık kontrolü
    static func validateInterval(_ interval: Double) -> Double {
        return max(0.5, interval) // CPU aşırı yükünü önlemek için minimum 0.5s
    }
}
