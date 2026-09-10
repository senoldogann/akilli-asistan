import Foundation

nonisolated struct CodexCLIProvider: ModelProvider {
    let id = ModelProviderID(rawValue: "codex")
    let displayName = "Codex"
    let capabilities: ModelCapabilities = [.textStreaming, .reasoningControl]

    private let locator: any CLIExecutableLocating
    private let runner: any CLIProcessRunning
    private let workspaceRoot: URL?
    private let fileManager: FileManager

    init(
        locator: any CLIExecutableLocating,
        runner: any CLIProcessRunning,
        workspaceRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.locator = locator
        self.runner = runner
        self.workspaceRoot = workspaceRoot
        self.fileManager = fileManager
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: locator.executable(named: "codex") == nil ? .notInstalled : .detected
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
                guard let executable = locator.executable(named: "codex") else {
                    continuation.finish(throwing: ProviderError.providerUnavailable(providerID: id))
                    return
                }

                let workspace = sessionWorkspace(for: request.sessionID)
                do {
                    try fileManager.createDirectory(
                        at: workspace,
                        withIntermediateDirectories: true
                    )
                } catch {
                    continuation.finish(throwing: ProviderError.providerUnavailable(providerID: id))
                    return
                }
                defer {
                    try? fileManager.removeItem(at: workspace)
                }

                var arguments = [
                    "exec",
                    "--json",
                    "--sandbox",
                    "read-only",
                    "--skip-git-repo-check",
                    "-C",
                    workspace.path
                ]
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
                    environmentOverrides: [.noColor: "1"]
                )

                var parser = CodexJSONLParser()
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

        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ZeroLose", isDirectory: true)
            .appendingPathComponent("ProviderWorkspaces", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent(sessionID.rawValue, isDirectory: true)
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

nonisolated enum CLIModelPromptRenderer {
    static func render(_ request: ModelRequest) -> String {
        var sections = [
            "You are a reasoning-only model provider inside ZeroLose.",
            "Do not execute tools or mutate the computer. Return reasoning/output only.",
            "Conversation:"
        ]
        sections.append(
            request.conversation
                .map { "\($0.role.rawValue.uppercased()): \($0.content)" }
                .joined(separator: "\n")
        )

        if !request.tools.isEmpty {
            sections.append("Available canonical tools (descriptions only; do not execute them):")
            sections.append(
                request.tools.map { tool in
                    let schema = String(data: tool.inputSchemaJSON, encoding: .utf8) ?? "{}"
                    return "- \(tool.name): \(tool.description) input_schema=\(schema)"
                }.joined(separator: "\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }
}

private struct CodexJSONLParser {
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
            throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "codex"))
        }

        switch type {
        case "thread.started", "turn.started":
            guard !emittedStarted else { return [] }
            emittedStarted = true
            return [.started]

        case "item.completed":
            guard
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                let text = item["text"] as? String,
                !text.isEmpty
            else {
                return []
            }
            return [.textDelta(text)]

        case "turn.completed":
            guard !emittedCompleted else { return [] }
            emittedCompleted = true
            return [.completed]

        case "turn.failed", "error":
            throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "codex"))

        default:
            return []
        }
    }
}
