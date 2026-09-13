import Foundation

nonisolated struct CodexCLIProvider: ModelProvider {
    let id = ModelProviderID(rawValue: "codex")
    let displayName = "Codex"
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
            availability: locator.executable(named: "codex") == nil ? .notInstalled : .detected
        )
    }

    /// The Codex CLI publishes its own catalog; this build offers whatever that
    /// catalog lists (with each model's own reasoning levels) instead of a
    /// hardcoded guess. A failed or unreadable catalog simply yields no models,
    /// which leaves the picker on "Default".
    func discoverModels() async throws -> [ModelDescriptor] {
        guard let executable = locator.executable(named: "codex") else {
            return []
        }

        let command = CLICommand(
            sessionID: ModelSessionID(rawValue: "catalog-codex-\(UUID().uuidString)"),
            executable: executable,
            arguments: CodexModelCatalog.arguments,
            workingDirectory: nil,
            timeoutSeconds: CodexModelCatalog.timeoutSeconds,
            environmentOverrides: [.noColor: "1"]
        )

        var stdout = Data()
        do {
            for try await event in await runner.run(command) {
                switch event {
                case .stdout(let data):
                    stdout.append(data)
                case .stderr, .exited:
                    break
                }
            }
        } catch {
            return []
        }

        return CodexModelCatalog.models(from: stdout, providerID: id)
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
                    try createWorkspace(workspace)
                } catch {
                    continuation.finish(throwing: ProviderError.providerUnavailable(providerID: id))
                    return
                }
                defer {
                    removeWorkspace(workspace)
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
                if let effort = request.reasoningEffort, !effort.isEmpty {
                    arguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
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
                var stderrTail = ""
                do {
                    let processEvents = await runner.run(command)
                    for try await processEvent in processEvents {
                        switch processEvent {
                        case .stdout(let data):
                            for event in try parser.consume(data) {
                                continuation.yield(event)
                            }
                        case .stderr(let data):
                            // Kept only to explain a failure; never yielded as model output.
                            stderrTail = CLIProcessFailureText.appendedTail(
                                stderrTail,
                                chunk: data
                            )
                        case .exited(let exitCode):
                            for event in try parser.finish() {
                                continuation.yield(event)
                            }
                            guard exitCode == 0 else {
                                continuation.finish(
                                    throwing: CLIProcessFailureText.failure(
                                        providerID: id,
                                        exitCode: exitCode,
                                        stderrTail: stderrTail
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
            .appendingPathComponent("codex", isDirectory: true)
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

nonisolated enum CLIProcessFailureText {
    private static let maximumTailLength = 2_000

    /// Keeps a bounded tail of a child process's stderr so a failure can be
    /// explained, without unbounded buffering of provider output.
    static func appendedTail(_ existing: String, chunk: Data) -> String {
        guard let text = String(data: chunk, encoding: .utf8) else { return existing }
        let combined = existing + text
        guard combined.count > maximumTailLength else { return combined }
        return String(combined.suffix(maximumTailLength))
    }

    /// Prefers the provider's own structured message and falls back to a bounded,
    /// redacted stderr tail so a bare exit status is never the whole story.
    static func failure(
        providerID: ModelProviderID,
        exitCode: Int32,
        stderrTail: String
    ) -> ProviderError {
        let tail = ProviderDiagnosticText.sanitized(stderrTail)
        guard !tail.isEmpty else {
            return .processFailed(providerID: providerID, exitCode: exitCode)
        }
        return .reportedByProvider(providerID, message: tail)
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

private nonisolated struct CodexJSONLParser {
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

        // Codex reports its own failures here (usage limits, auth problems, the
        // server refusing the turn). Surfacing that text is what makes the error
        // actionable; a bare `.malformedOutput` hides the real cause.
        case "error":
            throw ProviderError.reportedByProvider(
                ModelProviderID(rawValue: "codex"),
                message: Self.message(in: object) ?? ""
            )

        case "turn.failed":
            throw ProviderError.reportedByProvider(
                ModelProviderID(rawValue: "codex"),
                message: Self.message(in: object["error"] as? [String: Any]) ?? Self.message(in: object) ?? ""
            )

        default:
            return []
        }
    }

    private static func message(in object: [String: Any]?) -> String? {
        guard let value = object?["message"] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
