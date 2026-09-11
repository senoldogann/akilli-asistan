# ZeroLose Provider Fabric Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy provider router with provider-neutral contracts, safe local CLI adapters for Codex/Claude/OpenCode/Antigravity, and a separate OpenAI API provider with authoritative no-fallback selection.

**Architecture:** `ModelProviderFabric` owns provider registration and authoritative selection, while each provider adapter owns only its supported transport/session surface. CLI providers run through a single safe child-process abstraction with no shell interpolation or auth-file scraping; OpenAI API uses Keychain-backed credentials and its own transport.

**Tech Stack:** Swift 5, Swift Concurrency, Foundation `Process`, URLSession, macOS Keychain, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-11-zerolose-general-autonomous-agent-redesign.md`

## Global Constraints

- Work on isolated Git worktrees/branches; do not overwrite unrelated local work.
- Preserve `.freebuff/` and never stage it.
- Behavior changes use RED -> minimal GREEN -> focused regression -> affected/full suite.
- No `@unchecked Sendable`, `nonisolated(unsafe)`, or `Task.detached` as convenience fixes without a documented invariant and removal plan.
- Do not persist credentials, auth/session tokens, authorization headers, or CredentialBroker handles.
- Provider choice is authoritative; no silent provider fallback.
- Do not inspect or copy Codex, Claude, OpenCode, or Antigravity credential files.
- Initial provider surface: Codex CLI, Claude CLI, OpenCode CLI, Antigravity CLI, OpenAI API. Ollama is not part of this slice.

---

### Task 1: Provider-neutral domain contracts

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Providers/ModelProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/ModelProviderFabric.swift`
- Create: `ZeroLose/ZeroLoseTests/V2/ProviderTestDoubles.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ModelProviderFabricTests.swift`

**Interfaces:**
- Consumes: none.
- Produces: `ModelProviderID`, `ModelSessionID`, `ModelCapabilities`, `ModelDescriptor`, `ModelMessage`, `ModelRequest`, `ModelEvent`, `ProviderAvailability`, `ProviderStatus`, `ProviderError`, `ModelProvider`, `ModelProviderFabric`.

Use this exact test double in `ProviderTestDoubles.swift` so later provider tests share one contract:

```swift
actor RecordingModelProvider: ModelProvider {
    let id: ModelProviderID
    let displayName: String
    let capabilities: ModelCapabilities
    private let emittedEvents: [ModelEvent]
    private let terminalError: ProviderError?
    private(set) var requestCount = 0
    private(set) var cancelledSessions: [ModelSessionID] = []

    init(id: String, events: [ModelEvent] = [.completed], error: ProviderError? = nil) {
        self.id = ModelProviderID(rawValue: id)
        self.displayName = id.capitalized
        self.capabilities = [.textStreaming]
        self.emittedEvents = events
        self.terminalError = error
    }

    func status() async -> ProviderStatus {
        ProviderStatus(providerID: id, displayName: displayName, availability: .ready)
    }

    func discoverModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "default", displayName: "Default", providerID: id, capabilities: capabilities)]
    }

    nonisolated func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.recordRequest()
                if let error = await self.terminalErrorValue() { continuation.finish(throwing: error); return }
                for event in await self.eventsValue() { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async { cancelledSessions.append(sessionID) }
    private func recordRequest() { requestCount += 1 }
    private func eventsValue() -> [ModelEvent] { emittedEvents }
    private func terminalErrorValue() -> ProviderError? { terminalError }
}

extension ModelRequest {
    static func fixture(providerModel: String = "default") -> Self {
        ModelRequest(
            sessionID: ModelSessionID(rawValue: "s1"),
            conversation: [ModelMessage(role: .user, content: "hello")],
            modelID: providerModel,
            tools: [],
            responseMode: .text
        )
    }
}
```

- [ ] **Step 1: Write the failing provider-isolation tests**

```swift
func testSelectedProviderNeverFallsBack() async throws {
    let codex = RecordingModelProvider(id: "codex", error: .loginRequired(providerID: .init(rawValue: "codex")))
    let claude = RecordingModelProvider(id: "claude", events: [.textDelta("wrong-provider"), .completed])
    let fabric = ModelProviderFabric(providers: [codex, claude], selectedProviderID: codex.id)

    var thrown: ProviderError?
    do {
        let stream = try await fabric.stream(.fixture())
        for try await _ in stream {}
    } catch let error as ProviderError {
        thrown = error
    }

    XCTAssertEqual(thrown, .loginRequired(providerID: codex.id))
    let claudeRequests = await claude.requestCount
    XCTAssertEqual(claudeRequests, 0)
}

func testProviderStatusContainsNoCredentialMaterial() {
    let status = ProviderStatus(
        providerID: .init(rawValue: "codex"),
        displayName: "Codex",
        availability: .ready
    )
    let rendered = String(describing: status).lowercased()
    XCTAssertFalse(rendered.contains("token"))
    XCTAssertFalse(rendered.contains("authorization"))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:
```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ModelProviderFabricTests
```
Expected: compile failure because provider-neutral types do not exist.

- [ ] **Step 3: Implement the minimal contracts and fabric**

```swift
struct ModelProviderID: Hashable, Sendable, Codable { let rawValue: String }
struct ModelSessionID: Hashable, Sendable, Codable { let rawValue: String }

enum ModelRole: String, Codable, Sendable { case system, user, assistant }
struct ModelMessage: Codable, Sendable, Equatable { let role: ModelRole; let content: String }
struct ModelToolSchema: Codable, Sendable, Equatable { let name: String; let description: String; let inputSchemaJSON: Data }
enum ResponseMode: String, Codable, Sendable { case text, json }

struct ModelCapabilities: OptionSet, Sendable, Codable {
    let rawValue: UInt16
    static let textStreaming = Self(rawValue: 1 << 0)
    static let vision = Self(rawValue: 1 << 1)
    static let structuredTools = Self(rawValue: 1 << 2)
    static let jsonOutput = Self(rawValue: 1 << 3)
    static let sessionResume = Self(rawValue: 1 << 4)
    static let reasoningControl = Self(rawValue: 1 << 5)
}

struct ModelDescriptor: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let providerID: ModelProviderID
    let capabilities: ModelCapabilities
}

struct ModelRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversation: [ModelMessage]
    let modelID: String
    let tools: [ModelToolSchema]
    let responseMode: ResponseMode
}

enum ModelEvent: Sendable, Equatable {
    case started
    case textDelta(String)
    case toolCall(name: String, argumentsJSON: Data)
    case completed
}

enum ProviderAvailability: String, Sendable, Equatable {
    case ready, detected, notInstalled, loginRequired, configurationRequired, unavailable, unsupportedVersion
}

struct ProviderStatus: Sendable, Equatable {
    let providerID: ModelProviderID
    let displayName: String
    let availability: ProviderAvailability
}

enum ProviderError: Error, Sendable, Equatable {
    case providerUnavailable(providerID: ModelProviderID)
    case loginRequired(providerID: ModelProviderID)
    case configurationRequired(providerID: ModelProviderID)
    case unsupportedVersion(providerID: ModelProviderID)
    case processFailed(providerID: ModelProviderID, exitCode: Int32)
    case timeout(providerID: ModelProviderID)
    case cancelled(providerID: ModelProviderID)
    case malformedOutput(providerID: ModelProviderID)
    case quotaExhausted(providerID: ModelProviderID)
    case rateLimited(providerID: ModelProviderID)
    case invalidCredential(providerID: ModelProviderID)
}

protocol ModelProvider: Sendable {
    var id: ModelProviderID { get }
    var displayName: String { get }
    var capabilities: ModelCapabilities { get }
    func status() async -> ProviderStatus
    func discoverModels() async throws -> [ModelDescriptor]
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    func cancel(sessionID: ModelSessionID) async
}

actor ModelProviderFabric {
    private let providers: [ModelProviderID: any ModelProvider]
    private var selectedProviderID: ModelProviderID

    init(providers: [any ModelProvider], selectedProviderID: ModelProviderID) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.selectedProviderID = selectedProviderID
    }

    func select(_ providerID: ModelProviderID) { selectedProviderID = providerID }

    func stream(_ request: ModelRequest) throws -> AsyncThrowingStream<ModelEvent, Error> {
        guard let provider = providers[selectedProviderID] else {
            throw ProviderError.providerUnavailable(providerID: selectedProviderID)
        }
        return provider.stream(request)
    }

    func selectedStatus() async -> ProviderStatus {
        guard let provider = providers[selectedProviderID] else {
            return ProviderStatus(providerID: selectedProviderID, displayName: selectedProviderID.rawValue, availability: .unavailable)
        }
        return await provider.status()
    }

    func statuses() async -> [ProviderStatus] {
        var result: [ProviderStatus] = []
        for provider in providers.values {
            result.append(await provider.status())
        }
        return result.sorted { $0.providerID.rawValue < $1.providerID.rawValue }
    }

    func discoverModels(for providerID: ModelProviderID) async throws -> [ModelDescriptor] {
        guard let provider = providers[providerID] else {
            throw ProviderError.providerUnavailable(providerID: providerID)
        }
        return try await provider.discoverModels()
    }

    func cancel(sessionID: ModelSessionID) async {
        guard let provider = providers[selectedProviderID] else { return }
        await provider.cancel(sessionID: sessionID)
    }
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Use the command from Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Providers/ModelProvider.swift ZeroLose/ZeroLose/V2/Providers/ModelProviderFabric.swift ZeroLose/ZeroLoseTests/V2/ProviderTestDoubles.swift ZeroLose/ZeroLoseTests/V2/ModelProviderFabricTests.swift
git commit -m "feat: add provider-neutral model fabric"
```

### Task 2: Safe local CLI process runner

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/CLIProcessRunner.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/CLIExecutableLocator.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/CLIProcessRunnerTests.swift`

**Interfaces:**
- Consumes: `ModelSessionID`, `ProviderError`.
- Produces: `CLICommand`, `CLIProcessEvent`, `CLIProcessRunning`, `CLIExecutableLocating`, `CLIProcessRunner`, `CLIExecutableLocator`.

- [ ] **Step 1: Write failing tests for argv isolation and environment sanitation**

```swift
func testCommandNeverUsesShellInterpolation() {
    let command = CLICommand(
        sessionID: .init(rawValue: "s1"),
        executable: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["%s", "$(touch /tmp/never)"],
        workingDirectory: nil,
        timeoutSeconds: 10,
        environmentOverrides: [:]
    )
    XCTAssertNotEqual(command.executable.path, "/bin/sh")
    XCTAssertEqual(command.arguments, ["%s", "$(touch /tmp/never)"])
}

func testSanitizedEnvironmentDropsCredentialVariables() {
    let env = CLIProcessRunner.sanitizedEnvironment([
        "PATH": "/usr/bin",
        "HOME": "/Users/test",
        "LANG": "en_US.UTF-8",
        "OPENAI_API_KEY": "secret",
        "ANTHROPIC_API_KEY": "secret",
        "OPENCODE_SERVER_PASSWORD": "secret"
    ])
    XCTAssertEqual(env["PATH"], "/usr/bin")
    XCTAssertEqual(env["HOME"], "/Users/test")
    XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    XCTAssertNil(env["OPENAI_API_KEY"])
    XCTAssertNil(env["ANTHROPIC_API_KEY"])
    XCTAssertNil(env["OPENCODE_SERVER_PASSWORD"])
}
```

- [ ] **Step 2: Write failing process lifecycle tests using `/usr/bin/printf` and `/usr/bin/false`**

```swift
func testRunnerStreamsStdoutThenExit() async throws {
    let runner = CLIProcessRunner(baseEnvironment: ["PATH": "/usr/bin", "HOME": "/tmp"])
    let command = CLICommand(
        sessionID: .init(rawValue: "s1"),
        executable: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["hello"],
        workingDirectory: nil,
        timeoutSeconds: 5,
        environmentOverrides: [:]
    )
    var events: [CLIProcessEvent] = []
    for try await event in await runner.run(command) { events.append(event) }
    XCTAssertTrue(events.contains(.stdout(Data("hello".utf8))))
    XCTAssertEqual(events.last, .exited(0))
}
```

- [ ] **Step 3: Run tests and verify RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/CLIProcessRunnerTests
```
Expected: compile failure because CLI process types do not exist.

- [ ] **Step 4: Implement the runner and locator**

```swift
enum CLIEnvironmentKey: String, Sendable, Hashable {
    case openCodeConfig = "OPENCODE_CONFIG"
    case noColor = "NO_COLOR"
}

struct CLICommand: Sendable, Equatable {
    let sessionID: ModelSessionID
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL?
    let timeoutSeconds: TimeInterval
    let environmentOverrides: [CLIEnvironmentKey: String]
}

enum CLIProcessEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
}

protocol CLIProcessRunning: Sendable {
    func run(_ command: CLICommand) async -> AsyncThrowingStream<CLIProcessEvent, Error>
    func cancel(sessionID: ModelSessionID) async
}

protocol CLIExecutableLocating: Sendable {
    func executable(named name: String) -> URL?
}

struct CLIExecutableLocator: CLIExecutableLocating, Sendable {
    let searchPaths: [URL]
    func executable(named name: String) -> URL? {
        searchPaths
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

actor CLIProcessRunner: CLIProcessRunning {
    private var active: [ModelSessionID: Process] = [:]
    private let baseEnvironment: [String: String]

    static func sanitizedEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"])
        return source.filter { allowed.contains($0.key) }
    }

    func cancel(sessionID: ModelSessionID) async {
        active[sessionID]?.terminate()
    }
}
```

The production `run` implementation must set `Process.executableURL` directly, assign `arguments` as an array, use `Pipe` for stdout/stderr, emit `.exited(terminationStatus)`, remove the process from `active` on all terminal paths, and race process completion against a bounded timeout task owned by the actor. Start from `sanitizedEnvironment(baseEnvironment)`, then map only typed `CLIEnvironmentKey` overrides to their fixed raw names. No arbitrary environment key API exists. It must not invoke `/bin/sh`, `/usr/bin/env`, `bash`, `zsh`, or concatenate a shell command string.

- [ ] **Step 5: Run focused tests and verify GREEN**

Use Step 3 command. Expected: PASS, including timeout/cancellation tests.

- [ ] **Step 6: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Providers/CLI/CLIProcessRunner.swift ZeroLose/ZeroLose/V2/Providers/CLI/CLIExecutableLocator.swift ZeroLose/ZeroLoseTests/V2/CLIProcessRunnerTests.swift
git commit -m "feat: add safe CLI process runner"
```

### Task 3: Codex and Claude subscription providers

**Files:**
- Modify: `ZeroLose/ZeroLoseTests/V2/ProviderTestDoubles.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/CodexCLIProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/ClaudeCLIProvider.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/CodexCLIProviderTests.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ClaudeCLIProviderTests.swift`

**Interfaces:**
- Consumes: `ModelProvider`, `CLIProcessRunning`, `CLIExecutableLocating`.
- Produces: provider IDs `codex` and `claude`.

Add these reusable fakes before the provider-specific tests:

```swift
struct StubCLIExecutableLocator: CLIExecutableLocating {
    let paths: [String: URL]
    func executable(named name: String) -> URL? { paths[name] }
}

actor FixtureCLIProcessRunner: CLIProcessRunning {
    let events: [CLIProcessEvent]
    private(set) var commands: [CLICommand] = []
    private(set) var cancelled: [ModelSessionID] = []

    init(events: [CLIProcessEvent]) { self.events = events }

    func run(_ command: CLICommand) async -> AsyncThrowingStream<CLIProcessEvent, Error> {
        commands.append(command)
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(sessionID: ModelSessionID) async { cancelled.append(sessionID) }
}
```

- [ ] **Step 1: Write RED tests for Codex command isolation and parsing**

Use JSONL fixtures that match the current supported Codex `exec --json` event shape. The command test must assert exact safety properties, not only successful parsing:

```swift
func testCodexRunsReasoningOnlyInReadOnlyIsolatedWorkspace() async throws {
    let runner = FixtureCLIProcessRunner(events: [.exited(0)])
    let locator = StubCLIExecutableLocator(paths: ["codex": URL(fileURLWithPath: "/opt/homebrew/bin/codex")])
    let workspace = URL(fileURLWithPath: "/tmp/zerolose-provider-s1")
    let provider = CodexCLIProvider(locator: locator, runner: runner, workspaceRoot: workspace)

    _ = provider.stream(.fixture())
    let command = try XCTUnwrap(await runner.commands.first)
    XCTAssertEqual(command.executable.path, "/opt/homebrew/bin/codex")
    XCTAssertEqual(Array(command.arguments.prefix(2)), ["exec", "--json"])
    XCTAssertTrue(command.arguments.contains("--sandbox"))
    XCTAssertTrue(command.arguments.contains("read-only"))
    XCTAssertTrue(command.arguments.contains("--skip-git-repo-check"))
    XCTAssertTrue(command.arguments.contains("-C"))
    XCTAssertTrue(command.arguments.contains(workspace.path))
    XCTAssertFalse(command.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
}
```

Also add one fixture test that feeds a started event, assistant text item, and completion event and asserts `ModelEvent.started`, `.textDelta(...)`, `.completed` ordering. A nonzero process exit maps to `.processFailed(providerID: .codex, exitCode: ...)`.

- [ ] **Step 2: Write RED tests for Claude command isolation and streaming**

```swift
func testClaudeDisablesNativeToolsAndProjectHooks() async throws {
    let runner = FixtureCLIProcessRunner(events: [.exited(0)])
    let locator = StubCLIExecutableLocator(paths: ["claude": URL(fileURLWithPath: "/opt/homebrew/bin/claude")])
    let provider = ClaudeCLIProvider(locator: locator, runner: runner)

    _ = provider.stream(.fixture())
    let command = try XCTUnwrap(await runner.commands.first)
    XCTAssertEqual(command.executable.path, "/opt/homebrew/bin/claude")
    XCTAssertTrue(command.arguments.contains("-p"))
    XCTAssertTrue(command.arguments.contains("--bare"))
    XCTAssertTrue(command.arguments.contains("--tools"))
    let toolsIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--tools"))
    XCTAssertEqual(command.arguments[toolsIndex + 1], "")
    XCTAssertTrue(command.arguments.contains("--permission-mode"))
    XCTAssertTrue(command.arguments.contains("dontAsk"))
    XCTAssertTrue(command.arguments.contains("--no-chrome"))
    XCTAssertTrue(command.arguments.contains("--no-session-persistence"))
    XCTAssertTrue(command.arguments.contains("--output-format"))
    XCTAssertTrue(command.arguments.contains("stream-json"))
    XCTAssertTrue(command.arguments.contains("--include-partial-messages"))
}
```

Add stream-json fixtures for partial assistant deltas and completion. Assert cancellation delegates to `runner.cancel(sessionID:)`.

- [ ] **Step 3: Run both suites and verify RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/CodexCLIProviderTests -only-testing:ZeroLoseTests/ClaudeCLIProviderTests
```
Expected: compile failure because the provider adapters do not exist.

- [ ] **Step 4: Implement `CodexCLIProvider`**

The provider builds this argv shape for a normal request:

```text
codex exec --json --sandbox read-only --skip-git-repo-check -C <isolated-session-workspace> [--model <id>] <rendered-provider-prompt>
```

`<isolated-session-workspace>` is created under ZeroLose's Application Support temporary provider workspace, contains no user project files, and is removed after the session. The prompt contains only `ModelRequest` conversation/context and canonical tool descriptions needed for reasoning; Codex cannot mutate the user's actual workspace. Parse supported JSONL items into canonical `ModelEvent` values. Do not inspect Codex auth/config files.

- [ ] **Step 5: Implement `ClaudeCLIProvider`**

The provider builds this argv shape:

```text
claude -p <rendered-provider-prompt> --bare --tools '' --permission-mode dontAsk --no-chrome --no-session-persistence --output-format stream-json --verbose --include-partial-messages [--model <id>]
```

Parse stream-json deltas into canonical events. Do not enable Claude tools, hooks, Chrome integration, MCP, or project memory. Do not inspect Claude credential files.

- [ ] **Step 6: Run focused suites and verify GREEN**

Use Step 3 command. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Providers/CLI/CodexCLIProvider.swift ZeroLose/ZeroLose/V2/Providers/CLI/ClaudeCLIProvider.swift ZeroLose/ZeroLoseTests/V2/ProviderTestDoubles.swift ZeroLose/ZeroLoseTests/V2/CodexCLIProviderTests.swift ZeroLose/ZeroLoseTests/V2/ClaudeCLIProviderTests.swift
git commit -m "feat: add Codex and Claude subscription providers"
```

### Task 4: OpenCode and Antigravity CLI providers

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/OpenCodeCLIProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/AntigravityCLIProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/CLI/OpenCodePermissionConfig.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/OpenCodeCLIProviderTests.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AntigravityCLIProviderTests.swift`

**Interfaces:**
- Consumes: provider/CLI contracts and shared fakes.
- Produces: provider IDs `opencode` and `antigravity`.

- [ ] **Step 1: Write RED OpenCode reasoning-only tests**

```swift
func testOpenCodeRunsWithEphemeralDenyAllPermissions() async throws {
    let runner = FixtureCLIProcessRunner(events: [.exited(0)])
    let locator = StubCLIExecutableLocator(paths: ["opencode": URL(fileURLWithPath: "/opt/homebrew/bin/opencode")])
    let provider = OpenCodeCLIProvider(locator: locator, runner: runner, workspaceRoot: URL(fileURLWithPath: "/tmp/zero-opencode"))

    _ = provider.stream(.fixture())
    let command = try XCTUnwrap(await runner.commands.first)
    XCTAssertEqual(Array(command.arguments.prefix(2)), ["run", "--format"])
    XCTAssertTrue(command.arguments.contains("json"))
    XCTAssertFalse(command.arguments.contains("--auto"))
    XCTAssertFalse(command.arguments.contains(where: { $0.contains("opencode.ai/") }))
    XCTAssertFalse(command.arguments.contains(where: { $0.lowercased().contains("session") && $0.lowercased().contains("header") }))
}
```

Add a test for `OpenCodePermissionConfig.denyAllJSON()` that decodes the generated JSON and proves all supported permission classes resolve to `deny`. The provider creates an isolated workspace with an ephemeral OpenCode config containing that deny-all policy; it does not point OpenCode at the user's project. Parse `opencode run --format json` events into canonical model events.

- [ ] **Step 2: Write RED Antigravity availability/sandbox tests**

```swift
func testAntigravityWithoutAgyIsNotInstalled() async {
    let provider = AntigravityCLIProvider(
        locator: StubCLIExecutableLocator(paths: [:]),
        runner: FixtureCLIProcessRunner(events: [])
    )
    let status = await provider.status()
    XCTAssertEqual(status.availability, .notInstalled)
}

func testAntigravityNeverSkipsPermissions() async throws {
    let runner = FixtureCLIProcessRunner(events: [.exited(0)])
    let locator = StubCLIExecutableLocator(paths: ["agy": URL(fileURLWithPath: "/opt/homebrew/bin/agy")])
    let provider = AntigravityCLIProvider(locator: locator, runner: runner, workspaceRoot: URL(fileURLWithPath: "/tmp/zero-agy"))
    _ = provider.stream(.fixture())
    let command = try XCTUnwrap(await runner.commands.first)
    XCTAssertTrue(command.arguments.contains("--sandbox"))
    XCTAssertTrue(command.arguments.contains("-p"))
    XCTAssertFalse(command.arguments.contains("--dangerously-skip-permissions"))
}
```

- [ ] **Step 3: Run both suites and verify RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/OpenCodeCLIProviderTests -only-testing:ZeroLoseTests/AntigravityCLIProviderTests
```
Expected: missing provider/config types.

- [ ] **Step 4: Implement OpenCode adapter**

Use `opencode run --format json [--model <id>] <prompt>` from an isolated empty session workspace. Create a temporary OpenCode config whose permission map denies file edits, shell/bash, web/browser actions, MCP/tool execution, and any other supported mutation permission, and pass its path only through `environmentOverrides: [.openCodeConfig: configURL.path]`. Never pass `--auto`. Delete the temporary config/workspace after the request. OpenCode owns its own login/provider session; ZeroLose neither reads `~/.local/share/opencode/auth.json` nor reproduces `x-opencode-session`.

- [ ] **Step 5: Implement Antigravity adapter**

Resolve only the `agy` CLI. IDE application presence alone does not make status ready. Use `agy --sandbox -p <prompt> [--model <id>]` with a bounded `--print-timeout` when supported by the installed version. Never use `--dangerously-skip-permissions`. If `agy` is absent return `.notInstalled`; if its safe status probe indicates authentication is required return `.loginRequired`.

- [ ] **Step 6: Run focused suites and verify GREEN**

Use Step 3 command. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Providers/CLI/OpenCodeCLIProvider.swift ZeroLose/ZeroLose/V2/Providers/CLI/AntigravityCLIProvider.swift ZeroLose/ZeroLose/V2/Providers/CLI/OpenCodePermissionConfig.swift ZeroLose/ZeroLoseTests/V2/OpenCodeCLIProviderTests.swift ZeroLose/ZeroLoseTests/V2/AntigravityCLIProviderTests.swift
git commit -m "feat: add OpenCode and Antigravity CLI providers"
```

### Task 5: OpenAI API provider and Keychain credential boundary

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Providers/OpenAI/OpenAIAPIProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/OpenAI/OpenAITransport.swift`
- Create: `ZeroLose/ZeroLose/V2/Providers/OpenAI/OpenAIModels.swift`
- Modify: `ZeroLose/ZeroLose/V2/Credentials/KeychainCredentialBrokerAdapter.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/OpenAIAPIProviderTests.swift`

**Interfaces:**
- Consumes: `ModelProvider`, Keychain credential abstraction.
- Produces: provider ID `openai-api`, `OpenAITransporting` test seam.

- [ ] **Step 1: Write RED tests for Keychain-only status and transport isolation**

```swift
func testMissingKeyIsConfigurationRequired() async {
    let credentials = StubOpenAIKeyStore(value: nil)
    let provider = OpenAIAPIProvider(credentials: credentials, transport: RecordingOpenAITransport())
    XCTAssertEqual((await provider.status()).availability, .configurationRequired)
}

func testProviderStatusNeverContainsStoredKey() async {
    let secret = "sk-test-do-not-render"
    let provider = OpenAIAPIProvider(credentials: StubOpenAIKeyStore(value: secret), transport: RecordingOpenAITransport())
    XCTAssertFalse(String(describing: await provider.status()).contains(secret))
}
```

Define `OpenAIKeyStoring` in the provider module with only `hasKey()`, `withKey(_:)`, `store(_:)`, `remove()`; do not expose a UI-readable raw-key getter. Add a UserDefaults scan test that stores a key and proves no defaults value equals it.

- [ ] **Step 2: Write RED error-normalization tests with a fake transport**

Fixtures: HTTP 401 invalid key → `.invalidCredential`, HTTP 429 `insufficient_quota`/`credit_balance_exhausted` → `.quotaExhausted`, other HTTP 429 → `.rateLimited`, malformed response → `.malformedOutput`. The normalized error contains no response Authorization header or key.

- [ ] **Step 3: Run focused suite and verify RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/OpenAIAPIProviderTests
```

- [ ] **Step 4: Implement `OpenAITransport` and provider**

At implementation time, verify the current official OpenAI API request/streaming contract before coding. `OpenAITransport` alone constructs `Authorization: Bearer <key>` and URLRequest. It exposes only parsed response/status data to the provider. No Authorization header, API key, or raw secret-bearing URLRequest is emitted through logs/events/diagnostics.

- [ ] **Step 5: Run focused suite and provider aggregate regression**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ModelProviderFabricTests -only-testing:ZeroLoseTests/CLIProcessRunnerTests -only-testing:ZeroLoseTests/CodexCLIProviderTests -only-testing:ZeroLoseTests/ClaudeCLIProviderTests -only-testing:ZeroLoseTests/OpenCodeCLIProviderTests -only-testing:ZeroLoseTests/AntigravityCLIProviderTests -only-testing:ZeroLoseTests/OpenAIAPIProviderTests
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Providers/OpenAI ZeroLose/ZeroLose/V2/Credentials/KeychainCredentialBrokerAdapter.swift ZeroLose/ZeroLoseTests/V2/OpenAIAPIProviderTests.swift
git commit -m "feat: add isolated OpenAI API provider"
```

### Task 6: Provider composition and non-regression guard

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Create: `ZeroLose/ZeroLoseTests/V2/ProviderCompositionTests.swift`
- Modify: `scripts/verify_all.py`

**Interfaces:**
- Consumes: all provider adapters.
- Produces: one `ModelProviderFabric` instance exposed only through provider-neutral application services.

- [ ] **Step 1: Write RED production composition test**

Read `ZeroLoseRuntimeContainer.swift` as source and assert it registers exactly the redesigned provider IDs `codex`, `claude`, `opencode`, `antigravity`, `openai-api`. Assert the new V2 provider directory contains no `OllamaService`, `fallbackProvider`, `importOpenCodeKeysIfNeeded`, `opencode.ai/zen`, `/zen/go/`, or auth-file path literals.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ProviderCompositionTests
```
Expected: container does not yet compose the new provider fabric.

- [ ] **Step 3: Wire provider fabric into `ZeroLoseRuntimeContainer`**

Construct one shared `CLIExecutableLocator`, one `CLIProcessRunner`, the four CLI providers, and one `OpenAIAPIProvider`; pass them to `ModelProviderFabric`. Persist only the selected provider ID/default model ID as non-secret settings. Do not delete old router yet; normal chat cutover occurs in the context/request plan and destructive provider removal occurs in the legacy-demolition plan.

- [ ] **Step 4: Add repository guard for the new provider module**

Extend `scripts/verify_all.py` so `ZeroLose/ZeroLose/V2/Providers` fails verification if it contains direct OpenCode remote URLs, credential-file paths, shell executable strings, `fallbackProvider`, or provider-to-provider retry logic. Do not make the guard reject old legacy files yet; those are still needed until cutover parity.

- [ ] **Step 5: Run focused provider aggregate and hygiene**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ModelProviderFabricTests -only-testing:ZeroLoseTests/CLIProcessRunnerTests -only-testing:ZeroLoseTests/CodexCLIProviderTests -only-testing:ZeroLoseTests/ClaudeCLIProviderTests -only-testing:ZeroLoseTests/OpenCodeCLIProviderTests -only-testing:ZeroLoseTests/AntigravityCLIProviderTests -only-testing:ZeroLoseTests/OpenAIAPIProviderTests -only-testing:ZeroLoseTests/ProviderCompositionTests
git diff --check
```
Expected: PASS / exit 0.

- [ ] **Step 6: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift ZeroLose/ZeroLoseTests/V2/ProviderCompositionTests.swift scripts/verify_all.py
git commit -m "feat: compose ZeroLose model provider fabric"
```
