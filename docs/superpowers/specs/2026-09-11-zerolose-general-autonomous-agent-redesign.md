# ZeroLose General Autonomous Agent Redesign

Date: 2026-09-11
Status: Design approved in chat; implementation pending written-spec approval
Base: `origin/main` at `dd414f72556ea9a97cdd7e36f54fc810c18ae206`

## 1. Problem Statement

ZeroLose has accumulated several product identities at once: interview assistant, teleprompter, cheat-sheet, model playground, local/remote provider router, memory/RAG assistant, and an emerging autonomous desktop agent. The result is an interface and runtime that expose many controls but do not provide one reliable contract from user intent to model reasoning to verified computer action.

The provider layer is the clearest example. Provider selection, credentials, hard-coded model catalogs, OpenCode-specific HTTP transport, Ollama responsibilities, fallback rules, and UI state are tightly coupled across `Constants.swift`, `Secrets.swift`, `OllamaService.swift`, `ContentView.swift`, and `SettingsView.swift`. A provider selected in the UI can still be routed through a different backend. Private or provider-specific session requirements leak into the application. This makes failures difficult to reason about and creates unacceptable behavior for an autonomous agent.

The interview-specific product surface has a similar problem. Interview Vault, active interview roles, interview notes, mock interviews, teleprompter behavior, interview cache rules, and interview-specific retrieval heuristics are spread across the main UI and the intelligence layer. These features are not part of the new product goal and distort every request through interview-specific logic.

The new product goal is narrower and stronger:

> ZeroLose is a general-purpose autonomous macOS agent that can use the user's existing local AI subscriptions through supported local CLIs, optionally use OpenAI through an API key, retrieve only relevant context for each request, and execute computer/browser/file actions through one policy-controlled V2 runtime.

## 2. Product Principles

1. **One product identity.** ZeroLose is a general autonomous desktop agent, not an interview utility.
2. **Provider choice is authoritative.** The selected provider either handles the request or returns its own clear failure. No silent provider fallback is permitted.
3. **Reuse supported subscription surfaces.** Codex, Claude, OpenCode, and Antigravity integrations use supported local CLI/session interfaces where available. ZeroLose does not scrape or copy authentication tokens from another application.
4. **Execution is provider-independent.** A model provider proposes reasoning or structured tool actions; computer mutation occurs only through the V2 Tool Fabric and policy boundaries.
5. **Retrieval is per-request and relevance-based.** Memory and user knowledge are considered on every request, but only relevant context is injected.
6. **Fail closed for unsupported autonomy.** If a provider capability, runtime adapter, credential, computer permission, or recovery path is unavailable, the product reports that state instead of simulating success.
7. **Small visible surface, deep optional inspection.** The main UI focuses on conversation, task execution, provider/model selection, attachments, autonomy mode, and stop controls. Diagnostics and advanced settings remain available but do not dominate the workspace.
8. **Tests describe the product contract.** Provider isolation, settings, retrieval, persistence, autonomy, and migration are release-blocking behavior, not best-effort checks.

## 3. Scope

### 3.1 In scope

- Replace the existing provider/router system with a new `ModelProviderFabric`.
- First-class providers:
  - Codex CLI subscription provider.
  - Claude CLI subscription provider.
  - OpenCode CLI subscription/provider adapter.
  - Antigravity CLI provider when the supported CLI is installed and authenticated.
  - Optional OpenAI API provider using a Keychain-stored API key.
- Remove Ollama from the initial redesigned provider surface and remove `OllamaService` as the central router. A future Ollama-local provider, if requested later, must be a separate `ModelProvider` implementation and a separate scoped feature.
- Replace interview-specific intelligence orchestration with a general `ContextOrchestrator`.
- Define long-term memory, conversation context, active task state, attachments, and runtime evidence as separate context sources.
- Compose the existing V2 Tool Fabric, Policy Kernel, event persistence, task graph, replay/checkpointing, and ComputerAgentCore into the authoritative autonomous path.
- Redesign the main SwiftUI shell around general chat/task execution.
- Redesign settings around providers, autonomy/safety, memory/context, tools/MCP, privacy/data, and diagnostics.
- Remove interview-only UI and behavior.
- Add migration for valuable general-purpose user data while preventing removed interview behavior from reappearing in the new runtime.
- Add a full release test matrix and installation smoke test.

### 3.2 Explicitly out of scope

- Recreating OpenCode, Claude, Codex, or Antigravity private HTTP protocols.
- Copying OAuth/session tokens from another vendor's application storage.
- Automatically signing the user into third-party services.
- Building a cloud account system for ZeroLose.
- Shipping a permanent legacy provider compatibility mode.
- Treating model output as verified memory without provenance.
- Reintroducing direct model-to-mouse, model-to-keyboard, model-to-shell, or model-to-browser mutation paths.
- Preserving interview-specific workflows for compatibility.

## 4. Target Architecture

The authoritative request flow is:

```text
User Request / Goal
        |
        v
RequestCoordinator
        |
        +--> ContextOrchestrator
        |      |- ConversationStore
        |      |- MemoryStore
        |      |- AttachmentContext
        |      |- ActiveTaskContext
        |      `- RuntimeEvidence
        |
        v
ModelProviderFabric
        |
        +--> CodexCLIProvider
        +--> ClaudeCLIProvider
        +--> OpenCodeCLIProvider
        +--> AntigravityCLIProvider
        `--> OpenAIAPIProvider
        |
        v
AgentOrchestrator
        |
        v
TaskGraph / Planner
        |
        v
ToolFabric
        |
        v
PolicyKernel
        |
        +--> Read-only tools
        +--> Browser tools
        +--> File/app tools
        `--> ComputerAgentCore mutation gateway
        |
        v
Observation / EventStore / Verification
        |
        +--> Resume / retry / reconcile
        `--> GoalVerifier
```

The model provider layer never owns execution policy. The Tool Fabric never chooses a model provider. The UI never holds a raw execution primitive.

## 5. Provider Fabric

### 5.1 Core contracts

The provider subsystem exposes provider-neutral domain types. Existing `OllamaService.ChatMessage` or provider-specific transport models must not be used as the application-wide message type.

```swift
struct ModelProviderID: Hashable, Sendable {
    let rawValue: String
}

struct ModelDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let providerID: ModelProviderID
    let capabilities: ModelCapabilities
}

struct ModelRequest: Sendable {
    let conversation: [ModelMessage]
    let modelID: String
    let tools: [ModelToolSchema]
    let responseMode: ResponseMode
}

protocol ModelProvider: Sendable {
    var id: ModelProviderID { get }
    func status() async -> ProviderStatus
    func discoverModels() async throws -> [ModelDescriptor]
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    func cancel(sessionID: ModelSessionID) async
}
```

Provider status is explicit and presentation-safe: detected, not installed, signed in/available, login required, misconfigured, unavailable, or unsupported version. It contains no credential values.

### 5.2 No fallback rule

Provider selection is persisted as a provider ID and is authoritative. There is no fallback chain based on which credentials happen to exist. If `codex` is selected and the CLI is unavailable, the request fails with a Codex-specific availability error. If OpenAI API is selected without a key, it fails with an OpenAI API configuration error.

A fallback may only exist as an explicit user-visible future product feature where the user opts into a named fallback policy. That feature is not part of this redesign.

### 5.3 CLI providers

CLI providers launch supported local executables with `Process`/`posix_spawn`-style controlled execution, no shell interpolation, bounded environment propagation, explicit working directory, timeout, cancellation, and incremental stdout/stderr parsing.

#### Codex

- Detect the `codex` executable.
- Use the official non-interactive execution interface supported by the installed CLI version.
- Reuse the CLI's own existing login/session state.
- Parse structured output when supported.
- Do not inspect Codex credential files.

#### Claude

- Detect the `claude` executable.
- Use non-interactive prompt mode with structured/streaming output where supported.
- Reuse Claude CLI login state.
- Do not inspect Claude credential files.

#### OpenCode

- Detect the `opencode` executable.
- Use its supported run/server interface rather than reproducing its private remote API contract.
- Let OpenCode own provider routing/session headers behind its CLI/server boundary.
- ZeroLose exposes models/capabilities only when they can be discovered or proven through the supported OpenCode interface.

#### Antigravity

- Detect the supported Antigravity CLI executable (`agy`) at runtime.
- The installed Antigravity IDE alone is not treated as a provider-ready state.
- If the CLI is absent, UI shows `CLI setup required`.
- If installed but unauthenticated, UI shows `Login required` and provides instructions or launches the supported login flow only after user action.
- ZeroLose does not inspect Antigravity IDE authentication storage.

### 5.4 OpenAI API provider

OpenAI API is a separate provider from Codex subscription access.

- API key lives only in macOS Keychain.
- No API key is written to UserDefaults, EventStore, logs, memory, or diagnostics exports.
- Model discovery and request transport use the current supported OpenAI API contract.
- Provider-specific errors are normalized into `ProviderError` while preserving a safe user-facing reason such as quota exhausted, invalid key, model unavailable, or rate limited.

### 5.5 Capability negotiation

Each provider/model advertises capabilities such as text streaming, vision input, structured tool calls, JSON output, session resume, and reasoning controls. UI controls appear only when the selected model supports them. The app must not show a reasoning-effort selector or image affordance solely because another provider supports it.

Structured tool capability is separate from autonomous execution. A provider lacking native function calling may still participate in general chat; autonomous task execution that requires safe structured actions is disabled unless a tested adapter can produce the canonical action contract.

## 6. Context and Memory Architecture

### 6.1 Remove interview-specific orchestration

The new runtime removes interview-special-case query detection, interview score thresholds, compensation/self-introduction shortcuts, Interview Vault fast paths, interview notes parsing, mock-interview prompts, and interview-specific response cache logic.

`IntelligenceService` should either be replaced by smaller services or reduced to a thin compatibility shell during migration and then deleted. No single replacement service may become another multi-thousand-line god object.

### 6.2 Context sources

`ContextOrchestrator` evaluates these independent sources on every request:

1. Recent conversation context.
2. Relevant long-term memory.
3. User-provided files/attachments and their derived text/metadata.
4. Active task state and latest observations.
5. Verified runtime/tool evidence useful to the current request.

Each context item includes provenance, timestamp where relevant, source type, stable ID, and a relevance score. Context generation is deterministic for the same source snapshot and query except where a model-based reranker is explicitly enabled.

### 6.3 Retrieval policy

- Retrieval occurs for every user request.
- Injection occurs only when a source passes a relevance threshold or is mandatory for the active task.
- Context has an explicit token/character budget.
- Duplicate or near-duplicate items are collapsed.
- The latest direct user instruction has priority over retrieved memory.
- Unverified model output does not outrank verified user-provided or tool-derived evidence.
- External/web/tool content remains tainted according to existing V2 provenance rules.

### 6.4 Memory write policy

Memory is not an automatic transcript dump.

A candidate memory must be one of:

- Explicit user preference/fact suitable for retention.
- User-approved summary or pinned item.
- Stable task/project information with source provenance.

Provider credentials, authorization headers, raw browser cookies, private provider session IDs, transient tool payloads, and sensitive execution traces are never memory candidates.

## 7. Autonomous Runtime

### 7.1 Two user modes

The primary interaction modes are:

- **Ask**: conversational reasoning and read-only tools. No physical computer mutation.
- **Agent**: creates an explicit goal/task runtime and may perform policy-approved actions through Tool Fabric.

An advanced authority policy may exist under settings, but the primary UI does not expose misleading legacy labels such as `Full Access`.

### 7.2 Agent task lifecycle

```text
created -> planning -> ready -> executing -> observing -> verifying
                         ^                        |
                         |------ retry/replan ----|

terminal: completed | cancelled | blocked | failed | manual-resolution-required
```

A goal is not completed merely because a provider says it succeeded. Completion requires `GoalVerifier` evidence.

### 7.3 Computer and browser actions

All mutation operations must pass:

1. Tool descriptor resolution.
2. Current registry revision validation.
3. Policy evaluation.
4. Credential scope resolution where needed.
5. Approval/authority gate where required.
6. Execution by the registered provider/gateway.
7. New observation.
8. Verification.
9. Event recording/checkpoint update.

There is no string-command escape hatch and no legacy action parser.

### 7.4 Restart and recovery

The existing V2 checkpoint/replay/reconciliation principles remain mandatory:

- Restart restores into a paused/reconciliation state.
- Physical mutations are never blindly replayed.
- Credentials and live policy decisions are refreshed, not serialized as authority.
- Outstanding idempotency/mutation state is reconciled before resuming.
- Unknown high-risk outcomes require manual resolution.

## 8. UI Redesign

### 8.1 Main window

The new UI deliberately removes feature-icon clutter. The primary layout is a single conversation/task workspace.

```text
+------------------------------------------------------------+
| ZeroLose                                      Ready         |
| Provider: Codex v     Model: <model> v       Ask | Agent   |
+------------------------------------------------------------+
|                                                            |
|                 Conversation / Task timeline               |
|                                                            |
|                                                            |
+------------------------------------------------------------+
| +  Ask or assign a task...                         Stop  ^  |
| Context v                           Runtime v               |
+------------------------------------------------------------+
```

The exact visual styling may use native SwiftUI/Liquid Glass where appropriate, but information architecture is fixed:

- Provider.
- Model.
- Ask/Agent mode.
- Conversation/task timeline.
- Attachment control.
- Submit/Stop/Emergency Stop as context requires.
- Optional Context inspector.
- Optional Runtime inspector.

No Interview Vault, Mock Interview, Teleprompter, Cheat Sheet, interview-role button, or interview-specific header action remains.

### 8.2 Provider selector

Provider menu/status screen shows only real availability:

```text
Codex          Signed in / Ready
Claude         Signed in / Ready
OpenCode       Ready
Antigravity    CLI setup required
OpenAI API     Not configured
```

The UI never infers `signed in` simply from executable presence. Provider adapters report the state.

### 8.3 Runtime inspector

Runtime inspector is secondary UI and shows:

- Current goal/task state.
- Current provider/model.
- Current/last action.
- Pending approvals.
- Recent event timeline.
- Blocked/manual-resolution reason.
- Pause/Resume/Cancel when a real runtime supports them.
- Emergency Stop when mutation execution is active.

Controls that have no production command target are not shown as enabled.

### 8.4 Context inspector

Context inspector lets the user see why information was included:

- Conversation.
- Memory.
- File/attachment.
- Task state.
- Tool/runtime evidence.

It shows source labels and relevance summaries but not hidden chain-of-thought or provider credentials.

## 9. Settings Redesign

Settings contains these sections only:

### Provider Accounts

- Codex detection/status and refresh.
- Claude detection/status and refresh.
- OpenCode detection/status and refresh.
- Antigravity CLI detection/status and setup guidance.
- OpenAI API Key add/update/remove/test.

### Model Defaults

- Default provider.
- Per-provider default model chosen from discovered supported models.
- Optional capability-based defaults if proven necessary; no large hard-coded provider/model matrix.

### Autonomy & Safety

- Default Ask/Agent mode.
- Approval policy for mutation risk classes.
- Emergency stop behavior.
- Permission status for Accessibility/screen capture where required.

### Memory & Context

- Enable/disable long-term memory usage.
- Context budget.
- Inspect/pin/forget user-visible memory entries.
- Clear conversation/history controls with explicit scope.

### Tools & MCP

- Tool enable/disable.
- MCP server enable/disable/status.
- No direct raw execution button.

### Privacy & Data

- Data locations.
- Clear local runtime/event history.
- Clear conversation data.
- Export non-secret diagnostics.

### Diagnostics

- App/build version.
- Provider status.
- Runtime status.
- Recent sanitized errors.
- Verification/build diagnostics useful for support.

## 10. Legacy Removal and Data Migration

### 10.1 Remove from product/runtime

The following product behavior is deleted after new-path parity tests pass:

- Interview Vault UI and service behavior.
- Mock Interview UI/service.
- Teleprompter window and interview note behavior.
- Cheat Sheet interview data UI.
- Active interview role UI/service where it has no general-purpose equivalent.
- Interview-specific knowledge matcher and interview response cache paths.
- Interview-only prompt rules and response profiles.
- OpenCode Zen/Go direct HTTP provider implementations.
- Automatic OpenCode credential import from another application's auth file.
- Provider credential fallback selection.
- Hard-coded OpenCode model catalogs used as authoritative availability.
- `OllamaService` as global model-provider router.

### 10.2 Preserve valuable data without preserving obsolete behavior

Migration must not silently delete user-owned files or databases. Existing interview-specific databases/exports remain untouched at their current paths during this redesign and are no longer loaded by the new context runtime. They are not automatically moved, transformed, or deleted. A later explicit cleanup operation may remove them only after separate user approval.

General conversation history, general memory records, tool/event persistence, and user files should be migrated or retained when their schemas are still valid.

Keychain entries for obsolete providers may be left untouched during initial migration so rollback is possible, but the new app does not read them. A later explicit cleanup action may remove them with user approval.

### 10.3 Migration properties

Migration is:

- Versioned.
- Idempotent.
- Restart-safe.
- Readback-verified before marking complete.
- Non-destructive until the new system has verified its own durable state.

## 11. Error Handling

Errors are normalized into domain errors with safe presentation fields.

Provider errors distinguish:

- Executable not installed.
- Login required.
- Unsupported CLI version.
- Selected model unavailable.
- Unsupported model capability.
- Process timeout.
- Process exited with failure.
- Malformed structured output.
- User cancelled.
- API key invalid.
- API quota/rate limit.

Runtime errors distinguish:

- Policy denied.
- Approval required.
- Permission missing.
- Tool disabled/revoked.
- Stale registry revision.
- Observation failed.
- Verification failed.
- Manual reconciliation required.

The product never rewrites a provider failure into another provider request automatically.

## 12. Observability and Privacy

Structured logs record provider ID, model ID, lifecycle phase, duration, exit status category, tool ID, policy result category, event sequence, and sanitized error code. They do not record API keys, CLI auth tokens, authorization headers, cookies, raw credential files, or hidden chain-of-thought.

Provider stdout that contains model-visible answer content may be processed for the current request but is not written wholesale to OS logs. Diagnostics exports are sanitized and exclude Keychain values.

## 13. Test Strategy

Testing is a product requirement. CI must not require real personal subscriptions or secrets.

### 13.1 Provider unit/contract tests

For every provider adapter:

- Executable detection.
- Availability/status mapping.
- Argument construction without shell interpolation.
- Environment allowlist.
- Streaming parser.
- Structured event parser.
- Cancellation.
- Timeout.
- Nonzero exit handling.
- Malformed output handling.
- Model discovery parsing where supported.
- Unsupported-version behavior.
- Provider selection isolation.

Fake executable/process fixtures provide deterministic CI behavior.

### 13.2 Provider integration smoke tests

Opt-in local tests detect installed CLIs and perform only safe, non-destructive probes. Missing providers are reported as skipped/not configured, not failed. These tests never print token values.

### 13.3 OpenAI API tests

- Keychain add/read/delete through credential abstraction.
- No UserDefaults secret persistence.
- Request schema.
- Streaming response parsing.
- Rate limit/quota/error normalization.
- Mock transport tests run in CI; live API smoke test is opt-in.

### 13.4 Context tests

- Every request invokes retrieval.
- Irrelevant memory is excluded.
- Relevant memory is included within budget.
- Conversation recency behavior.
- Attachment relevance.
- Active task context priority.
- Provenance retention.
- Duplicate collapse.
- Tainted evidence remains tainted.
- Credential/session strings are excluded from context/memory.

### 13.5 Autonomous runtime tests

- Ask mode cannot perform physical mutation.
- Agent mode creates a real task/goal runtime.
- Tool invocation always passes Tool Fabric and Policy Kernel.
- Revoked/disabled tool fails closed.
- Approval-required mutation does not execute before approval.
- Emergency Stop cancels active execution and prevents new mutation scheduling.
- Restart restores paused/reconciliation state.
- Physical proposal is not replayed after restart.
- Outstanding mutation reconciliation.
- Goal completion requires verifier evidence.
- Browser/computer same-layout navigation and observation identity regression coverage remains intact.

### 13.6 UI/settings tests

- Main UI contains only approved primary controls.
- Removed interview surfaces are absent from production tree and navigation.
- Provider selector reflects adapter status.
- Unsupported capabilities are not shown/enabled.
- Settings persist non-secret values correctly.
- Provider default/model settings round-trip.
- OpenAI secret field never reflects raw stored key after save.
- Ask/Agent mode round-trip.
- Memory/context settings round-trip.
- Tool/MCP enable/disable routing uses typed commands.
- Runtime controls are disabled when no real runtime exists.

### 13.7 Migration tests

- Upgrade from current production settings/history fixture.
- Migration rerun produces no duplicate data.
- Interrupted migration resumes safely.
- Legacy interview data is not injected into new general context.
- General-purpose conversation/memory survives migration.
- Obsolete provider credentials are not automatically imported/read by the new provider runtime.

### 13.8 Release gates

A release candidate must pass:

1. Focused provider/context/runtime/UI test suites.
2. Full ZeroLose XCTest suite.
3. ExamPilot tests and release build where repository verification still covers that product.
4. `python3 scripts/verify_all.py`.
5. `git diff --check`.
6. Forbidden-symbol scans for deleted interview/provider runtime paths.
7. Release macOS app build.
8. Code-sign verification appropriate to local/distribution mode.
9. Fresh local install to `/Applications/ZeroLose.app` in acceptance environment.
10. Launch smoke test with process survival and main-window creation.
11. Exact-head CI before merge.
12. Post-merge `main` CI on the merge SHA.

## 14. Implementation Slices

This redesign is too large for one atomic code change. It is implemented in ordered slices, each independently tested and merged before destructive legacy deletion proceeds.

### Slice 1 — Provider domain and process runner

Introduce provider-neutral messages/events/capabilities, safe child-process execution abstraction, provider registry/fabric, fake-process fixtures, and no-fallback selection semantics. No UI cutover yet.

### Slice 2 — CLI providers

Add Codex, Claude, OpenCode, and Antigravity adapters with availability/model/cancellation/streaming tests. Antigravity remains unavailable when `agy` is absent. No auth-file scraping.

### Slice 3 — OpenAI API provider and credential settings

Add isolated OpenAI API transport and Keychain lifecycle. Keep it separate from Codex subscription provider.

### Slice 4 — ContextOrchestrator

Introduce general relevance-based retrieval and memory policy. Migrate general context consumers. Remove interview-specific decisions from the request path after parity tests.

### Slice 5 — General RequestCoordinator and Ask mode

Move normal chat/attachment requests to provider-neutral contracts and ContextOrchestrator. Remove `OllamaService` as central request router.

### Slice 6 — Authoritative Agent mode composition

Connect UI goal submission to persistent task runtime, Tool Fabric, Policy Kernel, ComputerAgentCore, event/checkpoint/replay/reconciliation, and GoalVerifier. Keep unsupported mutations fail-closed until a concrete production gateway exists.

### Slice 7 — UI and settings redesign

Replace the primary shell and settings information architecture. Remove interview-specific navigation and controls. Expose provider status, Ask/Agent mode, context inspector, runtime inspector, and emergency stop.

### Slice 8 — Legacy demolition and migration

Delete interview-specific runtime/UI/services, direct OpenCode HTTP, provider fallback logic, obsolete model catalogs, obsolete settings, and old router responsibilities after deterministic parity. Preserve/migrate valuable general user data.

### Slice 9 — Acceptance, installation, cleanup

Run all release gates, exact-head CI, merge, post-merge CI, install the final application, run smoke tests, and remove merged feature worktrees/branches.

## 15. Acceptance Criteria

The redesign is complete only when all of the following are true:

- Selecting Codex, Claude, OpenCode, Antigravity, or OpenAI API never silently routes to another provider.
- Installed/authenticated local CLI providers can be used without copying their authentication tokens into ZeroLose.
- Missing/unavailable providers display explicit state and fail closed.
- Antigravity IDE presence alone does not masquerade as CLI readiness.
- OpenAI API is independent from Codex subscription access and its key remains Keychain-only.
- The primary UI contains no Interview Vault, Mock Interview, Teleprompter, Cheat Sheet, or interview-role workflow.
- No interview-specific retrieval logic participates in normal requests.
- Every user request evaluates general context relevance.
- Only relevant context within budget is injected.
- Autonomous computer/browser/file mutation passes through Tool Fabric and Policy Kernel.
- Ask mode cannot trigger physical mutation.
- Agent completion requires verifier evidence.
- Restart/replay never blindly replays physical mutation.
- Runtime, provider, context, settings, migration, and UI behavior are covered by deterministic tests.
- CI requires no personal provider credentials.
- Final release build installs and launches successfully on the target Mac.
- Exact-head and post-merge repository verification are green.

## 16. Non-Negotiable Engineering Constraints

- Work on isolated Git worktrees/branches; do not overwrite unrelated local work.
- Preserve `.freebuff/` and never stage it.
- Behavior changes use RED -> minimal GREEN -> focused regression -> affected/full suite.
- No `@unchecked Sendable`, `nonisolated(unsafe)`, or `Task.detached` as convenience fixes without a documented invariant and removal plan.
- Do not persist credentials, auth/session tokens, authorization headers, or CredentialBroker handles.
- Do not reintroduce legacy `[ACTION: ...]` parsing or direct model-to-input execution.
- Legacy deletion occurs only after new-path parity is proven.
- Do not claim completion from local tests alone; exact-head CI and post-merge CI are required.

## 17. Final Product Definition

After this redesign, ZeroLose is not a bundle of interview tools with an autonomous layer attached. It is a provider-independent autonomous macOS agent with a small user-facing surface, explicit execution authority, durable task state, relevance-based context, and testable local-subscription integrations.

The user can choose an available local AI subscription, ask a normal question, attach context, or assign an autonomous task such as working through a browser flow. The chosen model reasons; the V2 runtime decides and verifies execution; the UI exposes only the controls needed to understand and stop that work.
