import AppKit
import Foundation
import os
import CoreAudio

/// MacOS sistem durumu hakkında AI bağlamı için gerçek zamanlı bilgi sağlar.
actor SystemStatusService {
    private let logger = Logger(subsystem: "com.zerolose", category: "system-status")
    
    struct SystemContext {
        let frontmostApp: String
        let runningApps: [String]
        let trashItemCount: Int
        let volume: Int
        let isMuted: Bool
    }
    
    /// RAM kullanımı dahil mevcut sistem durumunun bir özetini toplar.
    func getSystemContextSummary() async -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        
        let appNames = runningApps.compactMap { $0.localizedName }.sorted()
        
        let trashCount = getTrashItemCount()
        let (volume, isMuted) = getVolumeSettings()
        let memoryStats = await getMemoryUsage(for: runningApps)
        
        var summary = "\n--- SYSTEM STATE ---\n"
        summary += "Active App: \(frontmost)\n"
        summary += "Open Apps: \(appNames.joined(separator: ", "))\n"
        summary += "High RAM Apps: \(memoryStats)\n"
        summary += "Trash: \(trashCount) items\n"
        summary += "Volume: \(volume)% \(isMuted ? "(MUTED)" : "")\n"
        summary += "---------------------\n"
        
        return summary
    }
    
    private func getTrashItemCount() -> Int {
        let fileManager = FileManager.default
        guard let trashURL = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first else { return 0 }
        do {
            return try fileManager.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).count
        } catch {
            logger.error("Çöp kutusu içeriği okunamadı: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
    
    private func getVolumeSettings() -> (Int, Bool) {
        let script = NSAppleScript(source: "get volume settings")
        var error: NSDictionary?
        if let desc = script?.executeAndReturnError(&error) {
            let vol = Int(desc.atIndex(1)?.int32Value ?? 0) // Çıkış ses düzeyi
            let muted = desc.atIndex(3)?.booleanValue ?? false // Çıkış sessiz mi
            return (vol, muted)
        }
        return (0, false)
    }
    
    private func getMemoryUsage(for apps: [NSRunningApplication]) async -> String {
        let pids = apps.map { String($0.processIdentifier) }
        guard !pids.isEmpty else { return "None" }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p"] + [pids.joined(separator: ",")] + ["-o", "pid,rss"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return "Unknown" }
            
            // Ayrıştır: PID RSS
            var pidToRSS: [Int32: Int] = [:]
            let lines = output.components(separatedBy: .newlines).dropFirst() // Başlığı atla
            
            for line in lines {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count == 2, let pid = Int32(parts[0]), let rss = Int(parts[1]) {
                    pidToRSS[pid] = rss
                }
            }
            
            // Uygulamalara geri eşle ve sırala
            let sortedApps = apps.compactMap { app -> (String, Int)? in
                guard let rss = pidToRSS[app.processIdentifier] else { return nil }
                return (app.localizedName ?? "Unknown", rss)
            }.sorted { $0.1 > $1.1 }
            
            // İlk 3 sonucu döndür
            return sortedApps.prefix(3).map { app in
                let mb = Double(app.1) / 1024.0
                return String(format: "%@ (%.0f MB)", app.0, mb)
            }.joined(separator: ", ")
            
        } catch {
            return "Error retrieving stats"
        }
    }
}
