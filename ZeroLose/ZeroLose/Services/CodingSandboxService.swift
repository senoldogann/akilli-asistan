import Foundation

class CodingSandboxService {
    static let shared = CodingSandboxService()
    
    private init() {}
    
    struct CompilationResult {
        let success: Bool
        let diagnostics: String
    }
    
    func verifySwiftCode(_ code: String) -> CompilationResult {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let fileName = "sandbox_\(UUID().uuidString.prefix(8)).swift"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try code.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return CompilationResult(success: false, diagnostics: "Failed to write sandbox file: \(error.localizedDescription)")
        }
        
        defer {
            try? fileManager.removeItem(at: fileURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        // swiftc'yi -typecheck bayrağıyla kullan. Hızlı, güvenli, ikili üretmez.
        process.arguments = ["-typecheck", fileURL.path]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CompilationResult(success: false, diagnostics: "Compiler launch error: \(error.localizedDescription)")
        }
        
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        var errorString = String(data: errorData, encoding: .utf8) ?? ""
        
        // Şık görünüm için hata çıktısındaki geçici dosya adlarını temizle
        errorString = errorString.replacingOccurrences(of: fileURL.path, with: "Main.swift")
        
        let success = process.terminationStatus == 0
        return CompilationResult(success: success, diagnostics: errorString.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
