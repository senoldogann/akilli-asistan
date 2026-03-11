import Foundation
import os
import AppKit
import Combine

/// ZeroOperator executes system-level commands and AppleScripts to control the OS and applications.
/// This is the core 'hands' of the ZeroLose assistant.
@MainActor
class ZeroOperator: ObservableObject {
    @Published var activeAction: String? = nil
    private let logger = Logger(subsystem: "com.zerolose", category: "operator")
    private var recurringTask: Task<Void, Never>? = nil
    private let unsafeShellCommandsFlag = "allowUnsafeShellCommands"

    private struct ParsedShellCommand {
        let executableURL: URL
        let arguments: [String]
    }
    
    enum OperatorError: LocalizedError {
        case scriptExecutionFailed(String)
        case commandFailed(String)
        case unauthorized
        case initializationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .scriptExecutionFailed(let message): return "AppleScript Hatası: \(message)"
            case .commandFailed(let message): return "Komut Hatası: \(message)"
            case .unauthorized: return "Güvenlik Engeli: Bu işlem kısıtlanmıştır."
            case .initializationFailed(let message): return "Başlatma Hatası: \(message)"
            }
        }
    }
    
    init() {}
    
    /// Executes a given AppleScript and returns the output (Async & Background)
    @discardableResult
    func executeAppleScript(_ scriptSource: String, background: Bool = true) async throws -> String {
        if SafetyGuard.isDangerous(scriptSource, type: "applescript") {
            throw OperatorError.unauthorized
        }
        self.activeAction = "Executing Script..."
        defer { self.activeAction = nil }
        
        return try await Task.detached(priority: .userInitiated) {
            self.logger.info("🎭 Executing AppleScript (Background)...")
            
            var error: NSDictionary?
            self.logger.info("🎭 Executing AppleScript (length: \(scriptSource.count, privacy: .public))")
            
            if let script = NSAppleScript(source: scriptSource) {
                let result = script.executeAndReturnError(&error)
                
                if let error = error {
                    let errorDesc = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
                    throw OperatorError.scriptExecutionFailed(errorDesc)
                }
                
                return result.stringValue ?? "Success"
            } else {
                throw OperatorError.initializationFailed("AppleScript nesnesi oluşturulamadı. Script formatı hatalı olabilir.")
            }
        }.value
    }
    
    /// Executes a shell command in strict allowlist mode (no shell interpreter).
    @discardableResult
    func executeShell(_ command: String) async throws -> String {
        guard UserDefaults.standard.bool(forKey: unsafeShellCommandsFlag) else {
            logger.warning("Blocked shell command because unsafe shell mode is disabled.")
            throw OperatorError.unauthorized
        }

        if SafetyGuard.isDangerous(command, type: "shell") {
            throw OperatorError.unauthorized
        }

        guard let parsedCommand = parseAllowedShellCommand(command) else {
            logger.warning("Blocked shell command because it is outside the allowlist.")
            throw OperatorError.unauthorized
        }

        self.activeAction = "Sending Command..."
        defer { self.activeAction = nil }
        
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = nil 

            process.arguments = parsedCommand.arguments
            process.executableURL = parsedCommand.executableURL
            
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            if process.terminationStatus != 0 {
                let errorOutput = output.isEmpty ? "Shell command exited with status \(process.terminationStatus)" : output
                throw OperatorError.commandFailed(errorOutput)
            }
            
            return output
        }.value
    }

    /// Executes a shell command via AppleScript with administrator privileges.
    /// This will trigger macOS admin password prompt.
    @discardableResult
    func executePrivilegedShell(_ command: String) async throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OperatorError.commandFailed("Boş sudo komutu çalıştırılamaz.")
        }

        self.activeAction = "Running sudo command..."
        defer { self.activeAction = nil }

        return try await Task.detached(priority: .userInitiated) {
            let escaped = Self.escapeForAppleScriptShell(trimmed)
            let scriptSource = "do shell script \"\(escaped)\" with administrator privileges"

            var error: NSDictionary?
            guard let script = NSAppleScript(source: scriptSource) else {
                throw OperatorError.initializationFailed("Privileged AppleScript oluşturulamadı.")
            }

            let result = script.executeAndReturnError(&error)
            if let error = error {
                let errorDesc = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown privileged command error"
                throw OperatorError.commandFailed(errorDesc)
            }

            return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Success"
        }.value
    }

    private func parseAllowedShellCommand(_ command: String) -> ParsedShellCommand? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let base = parts.first?.lowercased() else { return nil }

        switch base {
        case "open":
            guard parts.count == 2,
                  let url = URL(string: parts[1]),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }

            return ParsedShellCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: [url.absoluteString]
            )
        default:
            return nil
        }
    }

    nonisolated private static func escapeForAppleScriptShell(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
    
    /// Starts a recurring task (e.g., scroll every X seconds)
    func startRecurringTask(script: String, interval: Double, label: String) {
        if SafetyGuard.isDangerous(script, type: "applescript") { return }
        let safeInterval = SafetyGuard.validateInterval(interval)
        
        recurringTask?.cancel()
        self.activeAction = "\(label)..."
        
        recurringTask = Task {
            while !Task.isCancelled {
                do {
                    _ = try await executeAppleScript(script, background: true)
                } catch {
                    logger.error("❌ Recurring Task Failed: \(error.localizedDescription)")
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(safeInterval * 1_000_000_000))
            }
            self.activeAction = nil
        }
    }
    
    func stopAllTasks() {
        recurringTask?.cancel()
        recurringTask = nil
        self.activeAction = nil
    }
}
