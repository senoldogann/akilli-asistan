import Foundation

nonisolated struct ClaudeCLIProvider: ModelProvider {
    let id = ModelProviderID(rawValue: "claude")
    let displayName = "Claude"
    let capabilities: ModelCapabilities = [.textStreaming, .reasoningControl]

    private let locator: any CLIExecutableLocating
    private let runner: any CLIProcessRunning

    init(
        locator: any CLIExecutableLocating,
        runner: any CLIProcessRunning
    ) {
        self.locator = locator
        self.runner = runner
    }

    func status() async -> ProviderStatus {
        ProviderStatus(
            providerID: id,
            displayName: displayName,
            availability: locator.executable(named: "claude") == nil ? .notInstalled : .detected
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
                guard let executable = locator.executable(named: "claude") else {
                    continuation.finish(throwing: ProviderError.providerUnavailable(providerID: id))
                    return
                }

                var arguments = [
                    "-p",
                    CLIModelPromptRenderer.render(request),
                    "--bare",
                    "--tools",
                    "",
                    "--permission-mode",
                    "dontAsk",
                    "--no-chrome",
                    "--no-session-persistence",
                    "--output-format",
                    "stream-json",
                    "--verbose",
                    "--include-partial-messages"
                ]
                if !request.modelID.isEmpty, request.modelID != "default" {
                    arguments += ["--model", request.modelID]
                }

                let command = CLICommand(
                    sessionID: request.sessionID,
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: nil,
                    timeoutSeconds: 300,
                    environmentOverrides: [.noColor: "1"]
                )

                var parser = ClaudeJSONLParser()
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

private nonisolated struct ClaudeJSONLParser {
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
            throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "claude"))
        }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init", !emittedStarted else {
                return []
            }
            emittedStarted = true
            return [.started]

        case "stream_event":
            guard
                let event = object["event"] as? [String: Any],
                event["type"] as? String == "content_block_delta",
                let delta = event["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String,
                !text.isEmpty
            else {
                return []
            }
            return [.textDelta(text)]

        case "result":
            if object["is_error"] as? Bool == true {
                throw ProviderError.malformedOutput(providerID: ModelProviderID(rawValue: "claude"))
            }
            guard !emittedCompleted else { return [] }
            emittedCompleted = true
            return [.completed]

        default:
            return []
        }
    }
}
