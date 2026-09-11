import Foundation

nonisolated struct OpenCodeCLIProvider: ModelProvider {
    let id = ModelProviderID(rawValue: "opencode")
    let displayName = "OpenCode"
    let capabilities: ModelCapabilities = [.textStreaming, .reasoningControl]

    private let locator: any CLIExecutableLocating
    private let runner: any CLIProcessRunning
    private let workspaceRoot: URL?

    init(
        locator: any CLIExecutableLocating,
        runner: any CLIProcessRunning,
        workspaceRoot: URL? = nil
    ) {
        self.locator = locator
        self.runner = runner
        self.workspaceRoot = workspaceRoot
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: locator.executable(named: "opencode") == nil ? .notInstalled : .detected
        )
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        []
    }

    func stream(
        _ request: ModelRequest
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let executable = locator.executable(named: "opencode") else {
                    continuation.finish(throwing: ProviderError.providerUnavailable(providerID: id))
                    return
                }

                let workspace = sessionWorkspace(for: request.sessionID)
                let configURL = workspace.appendingPathComponent("zerolose-opencode.json")
                do {
                    try createWorkspace(workspace)
                    try OpenCodePermissionConfig.denyAllJSON().write(
                        to: configURL,
                        options: [.atomic]
                    )
                } catch {
                    continuation.finish(throwing: ProviderError.providerUnavailable(providerID: id))
                    return
                }
                defer {
                    removeWorkspace(workspace)
                }

                var arguments = ["run", "--format", "json"]
                if !request.modelID.isEmpty, request.modelID != "default" {
                    arguments += ["--model", request.modelID]
                }
                arguments.append(CLIModelPromptRenderer.render(request))

                let command = CLICommand(
                    sessionID: request.sessionID,
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workspace,
                    timeoutSeconds: 300,
                    environmentOverrides: [
                        .openCodeConfig: configURL.path,
                        .noColor: "1"
                    ]
                )

                var parser = OpenCodeJSONLParser()
                do {
                    let processEvents = await runner.run(command)
                    for try await processEvent in processEvents {
                        switch processEvent {
                        case .stdout(let data):
                            for event in try parser.consume(data) {
                                continuation.yield(event)
                            }
                        case .stderr:
                            break
                        case .exited(let exitCode):
                            for event in try parser.finish() {
                                continuation.yield(event)
                            }
                            guard exitCode == 0 else {
                                continuation.finish(
                                    throwing: ProviderError.processFailed(
                                        providerID: id,
                                        exitCode: exitCode
                                    )
                                )
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch let error as CLIProcessRunnerError {
                    continuation.finish(throwing: mapRunnerError(error))
                } catch {
                    continuation.finish(throwing: ProviderError.malformedOutput(providerID: id))
                }
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        await runner.cancel(sessionID: sessionID)
    }

    private func sessionWorkspace(for sessionID: ModelSessionID) -> URL {
        if let workspaceRoot {
            return workspaceRoot
        }

        let fileManager = FileManager.default
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ZeroLose", isDirectory: true)
            .appendingPathComponent("ProviderWorkspaces", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent(sessionID.rawValue, isDirectory: true)
    }

    private func createWorkspace(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    private func removeWorkspace(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func mapRunnerError(_ error: CLIProcessRunnerError) -> ProviderError {
        switch error {
        case .cancelled:
            return .cancelled(providerID: id)
        case .timeout:
            return .timeout(providerID: id)
        case .launchFailed, .duplicateSession, .disallowedExecutable:
            return .providerUnavailable(providerID: id)
        }
    }
}

private nonisolated struct OpenCodeJSONLParser {
    private var buffer = Data()
    private var emittedStarted = false
    private var emittedCompleted = false

    mutating func consume(_ data: Data) throws -> [ModelEvent] {
        buffer.append(data)
        return try drainCompleteLines()
    }

    mutating func finish() throws -> [ModelEvent] {
        var events = try drainCompleteLines()
        if !buffer.isEmpty {
            events += try parseLine(buffer)
            buffer.removeAll(keepingCapacity: false)
        }
        return events
    }

    private mutating func drainCompleteLines() throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                events += try parseLine(line)
            }
        }
        return events
    }

    private mutating func parseLine(_ line: Data) throws -> [ModelEvent] {
        guard
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String
        else {
            throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "opencode"))
        }

        switch type {
        case "step_start", "step-start":
            guard !emittedStarted else { return [] }
            emittedStarted = true
            return [.started]

        case "text":
            guard let part = object["part"] as? [String: Any] else {
                return []
            }
            if part["synthetic"] as? Bool == true {
                return []
            }
            if
                let metadata = part["metadata"] as? [String: Any],
                metadata["compaction_continue"] as? Bool == true
            {
                return []
            }
            guard let text = part["text"] as? String, !text.isEmpty else {
                return []
            }
            return [.textDelta(text)]

        case "step_finish", "step-finish":
            guard !emittedCompleted else { return [] }
            emittedCompleted = true
            return [.completed]

        case "tool", "tool_use", "tool-use":
            throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "opencode"))

        case "error":
            throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "opencode"))

        default:
            return []
        }
    }
}
