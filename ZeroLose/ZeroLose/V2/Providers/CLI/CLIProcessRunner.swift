import Foundation

nonisolated enum CLIEnvironmentKey: String, Sendable, Hashable {
    case openCodeConfig = "OPENCODE_CONFIG"
    case noColor = "NO_COLOR"
}

nonisolated struct CLICommand: Sendable, Equatable {
    let sessionID: ModelSessionID
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL?
    let timeoutSeconds: TimeInterval
    let environmentOverrides: [CLIEnvironmentKey: String]
}

nonisolated enum CLIProcessEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
}

nonisolated enum CLIProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed
    case duplicateSession
    case disallowedExecutable
    case cancelled
    case timeout
}

nonisolated protocol CLIProcessRunning: Sendable {
    func run(
        _ command: CLICommand
    ) async -> AsyncThrowingStream<CLIProcessEvent, Error>

    func cancel(sessionID: ModelSessionID) async
}

actor CLIProcessRunner: CLIProcessRunning {
    private enum TerminalReason {
        case cancelled
        case timeout
    }

    private struct ActiveProcess {
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
        let continuation: AsyncThrowingStream<CLIProcessEvent, Error>.Continuation
        let timeoutTask: Task<Void, Never>
        var terminalReason: TerminalReason?
    }

    private var active: [ModelSessionID: ActiveProcess] = [:]
    private let baseEnvironment: [String: String]

    init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    nonisolated static func sanitizedEnvironment(
        _ source: [String: String]
    ) -> [String: String] {
        let allowedKeys = Set([
            "PATH",
            "HOME",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE"
        ])
        return source.filter { allowedKeys.contains($0.key) }
    }

    func run(
        _ command: CLICommand
    ) async -> AsyncThrowingStream<CLIProcessEvent, Error> {
        let pair = AsyncThrowingStream<CLIProcessEvent, Error>.makeStream()
        let stream = pair.stream
        let continuation = pair.continuation

        continuation.onTermination = { @Sendable [weak self] reason in
            guard case .cancelled = reason else {
                return
            }
            Task {
                await self?.cancel(sessionID: command.sessionID)
            }
        }

        guard !Self.isDisallowedExecutable(command.executable) else {
            continuation.finish(throwing: CLIProcessRunnerError.disallowedExecutable)
            return stream
        }

        guard active[command.sessionID] == nil else {
            continuation.finish(throwing: CLIProcessRunnerError.duplicateSession)
            return stream
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr

        var environment = Self.sanitizedEnvironment(baseEnvironment)
        for (key, value) in command.environmentOverrides {
            environment[key.rawValue] = value
        }
        process.environment = environment

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            continuation.yield(.stdout(data))
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            continuation.yield(.stderr(data))
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.processDidExit(
                    sessionID: command.sessionID,
                    status: status
                )
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.finish(throwing: CLIProcessRunnerError.launchFailed)
            return stream
        }

        let timeoutNanoseconds = Self.timeoutNanoseconds(command.timeoutSeconds)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.timeout(sessionID: command.sessionID)
        }

        active[command.sessionID] = ActiveProcess(
            process: process,
            stdout: stdout,
            stderr: stderr,
            continuation: continuation,
            timeoutTask: timeoutTask,
            terminalReason: nil
        )

        return stream
    }

    func cancel(sessionID: ModelSessionID) async {
        guard var state = active[sessionID], state.process.isRunning else {
            return
        }

        state.terminalReason = .cancelled
        active[sessionID] = state
        state.process.terminate()
    }

    private func timeout(sessionID: ModelSessionID) {
        guard var state = active[sessionID], state.process.isRunning else {
            return
        }

        state.terminalReason = .timeout
        active[sessionID] = state
        state.process.terminate()
    }

    private func processDidExit(
        sessionID: ModelSessionID,
        status: Int32
    ) {
        guard let state = active.removeValue(forKey: sessionID) else {
            return
        }

        state.timeoutTask.cancel()
        state.stdout.fileHandleForReading.readabilityHandler = nil
        state.stderr.fileHandleForReading.readabilityHandler = nil
        state.process.terminationHandler = nil

        let remainingStdout = state.stdout.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            state.continuation.yield(.stdout(remainingStdout))
        }

        let remainingStderr = state.stderr.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            state.continuation.yield(.stderr(remainingStderr))
        }

        switch state.terminalReason {
        case .cancelled:
            state.continuation.finish(throwing: CLIProcessRunnerError.cancelled)
        case .timeout:
            state.continuation.finish(throwing: CLIProcessRunnerError.timeout)
        case nil:
            state.continuation.yield(.exited(status))
            state.continuation.finish()
        }
    }

    nonisolated private static func isDisallowedExecutable(_ url: URL) -> Bool {
        let forbidden = Set([
            "sh",
            "bash",
            "zsh",
            "fish",
            "ksh",
            "tcsh",
            "csh",
            "dash",
            "env"
        ])
        let originalName = url.lastPathComponent.lowercased()
        let resolvedName = url.resolvingSymlinksInPath().lastPathComponent.lowercased()
        return forbidden.contains(originalName) || forbidden.contains(resolvedName)
    }

    nonisolated private static func timeoutNanoseconds(
        _ timeoutSeconds: TimeInterval
    ) -> UInt64 {
        let boundedSeconds = max(0.01, min(timeoutSeconds, 3_600))
        return UInt64(boundedSeconds * 1_000_000_000)
    }
}
