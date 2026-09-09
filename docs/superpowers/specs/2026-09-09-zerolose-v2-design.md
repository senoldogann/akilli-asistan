# ZeroLose V2 Design

Date: 2026-09-09
Status: Architecture approved; implementation planning authorized
Repository baseline: `471d025f7ed3477197e0b507aec748fee72a539f`

## 1. Purpose

ZeroLose V2 replaces the legacy model-driven action pipeline with a typed, policy-governed, persistent autonomous runtime for macOS while preserving valuable user data and reusing the working ExamPilot computer-use foundation.

This is a strangler migration, not a clean-room rewrite. Existing ExamPilot correctness primitives are extracted behind reusable boundaries rather than reimplemented. Legacy ZeroLose UI compatibility and legacy agent execution behavior are not goals.

The central invariant is:

```text
proposal
→ schema validation
→ capability validation
→ credential scope
→ PolicyKernel
→ execution
→ receipt/evidence
→ verifier
```

No model response, UI action, checkpoint, memory entry, Full Access mode, MCP annotation, plugin metadata, or compatibility path may bypass this chain.

## 2. Migration Policy B

Migrate valuable user data:

- API keys and credential configuration;
- valuable settings;
- conversation/chat history;
- valuable semantic history where provenance can be preserved.

Do not preserve:

- old ZeroLose UI compatibility as a product requirement;
- legacy agent execution behavior;
- `[ACTION: {...}]` regex compatibility;
- legacy approval semantics;
- accidental behavior encoded in `GhostViewModel`.

## 3. Technology Direction

```text
Trusted kernel/runtime        Swift
TaskRuntime / TaskGraph       Swift
Scheduler / Recovery          Swift
PolicyKernel / Tool Fabric    Swift
ComputerAgentCore             Swift
macOS native integration      Swift
Persistence                   Swift + SQLite
UI                            SwiftUI

Plugin SDK                    TypeScript may be used
MCP servers                   implementation-language agnostic
Optional web surfaces         TypeScript/React may be used
```

TypeScript is an edge/ecosystem language, not a dependency of the trusted execution kernel.

The current ZeroLose target remains in Swift 5 language mode during V2 extraction. SwiftUI-facing observable state is `@MainActor`. Kernel/runtime mutable state uses explicit isolation, normally actor ownership. Cross-isolation DTOs should be immutable/value-oriented and `Sendable` where practical. A Swift 6 language-mode migration is a separate verified slice.

## 4. Authority, Risk, and Policy

Modes:

- Manual / Chat
- Auto
- Autonomous
- Full Access

Default mode: Auto.

Risk classes:

```text
Risk 0  read/search/inspect
Risk 1  reversible local mutation
Risk 2  external communication/publish
Risk 3  financial/external high-impact mutation
Risk 4  irreversible/ownership/credential/destructive
```

Mode controls pre-granted authority. It never bypasses tool safety or kernel policy. Full Access does not bypass `PolicyKernel`, widen credential scope, or implicitly authorize unknown/destructive operations. After restart, historical Full Access restores paused rather than automatically resuming physical mutation.

Emergency controls:

- Pause
- Stop
- Kill physical input
- Revoke tool
- Revoke credential

Provider/MCP risk and read-only annotations are advisory only. `PolicyKernel` computes effective risk from descriptor metadata, actual arguments, destination, credential scope, mode, taint, and task context.

## 5. TaskGraph and Long-Horizon Runtime

Canonical hierarchy:

```text
User Goal
→ AutonomousRuntime
→ Planner
→ TaskGraph
→ Scheduler
→ TaskRuntime
→ Tool / ComputerAgent
→ Verifier
→ RecoveryEngine
```

Hard rules:

- Planner never executes mutations.
- Scheduler never executes tools.
- Task completion requires verifier evidence.
- Goal completion is separately validated by `GoalVerifier` and success criteria.
- Physical actions are never directly replayed from checkpoints.
- Resume re-observes and reconciles external/world state.
- Mutation tasks serialize by default.
- Read/research tasks may parallelize within configured bounds.
- Retry is bounded and an unchanged failed strategy cannot blindly repeat.
- Policy is re-evaluated before each mutation using current policy.
- Checkpoints do not carry stale permission.
- Full Access restart restores paused.
- Graph changes are stored as revisions/events.
- External mutations require idempotency/duplicate protection.
- Cancellation propagates graph → task → tool → native input.

Lifecycle values include `created`, `blocked`, `ready`, `planning`, `running`, `verifying`, `succeeded`, `failed`, `recovering`, `replanned`, `exhausted`, `paused`, `cancelled`, `waitingExternal`, and `waitingApproval`.

Budgets include wall clock, model calls, tool calls, recovery attempts, external spend, parallel tasks, and deadline.

## 6. Unified Tool Fabric

Canonical flow:

```text
TaskRuntime
→ CapabilityResolver
→ ToolRegistry snapshot
→ ToolInvocation
→ schema validation
→ capability validation
→ CredentialBroker scope
→ PolicyKernel
→ provider execution
→ ToolExecutionReceipt / Evidence
→ Verifier
```

Stable namespaces:

```text
builtin.*
computer.*
mcp.<server-or-provider>.*
plugin.<plugin-id>.*
app.<app-id>.*
```

`ToolRegistry` uses immutable snapshots and monotonically increasing `registryRevision`. Every invocation carries tool ID, registry revision, descriptor revision, and schema digest. A stale/revoked invocation never executes directly; it must be re-resolved and revalidated.

Minimum `ToolDescriptor` metadata:

- stable ID;
- provider identity and provenance;
- input/output schema;
- effect class;
- declared/advisory risk metadata;
- required credential scopes;
- idempotency semantics;
- concurrency class;
- enabled/revoked state;
- verification contract.

Providers:

- `BuiltinToolProvider`
- `ComputerToolProvider`
- `MCPToolProvider`
- `PluginToolProvider`
- `AppToolProvider`

Providers implement capability, but approval/policy authority remains centralized.

### Physical computer mutation invariant

A ComputerAgent session does not receive blanket HID authority. Every physical mutation re-enters the mutation gate:

```text
TaskRuntime
→ Tool Fabric
→ ComputerAgentCore
→ physical action proposal
→ Tool Fabric mutation gate
→ PolicyKernel
→ state/version + focus validation
→ native HID executor
→ execution receipt
→ OutcomeVerifier
```

Batch planning is not batch authority. Each physical action is independently gated against current registry, policy, cancellation, focus, and state.

### CredentialBroker

The broker reuses existing Keychain data. The model sees only availability/scope metadata. Raw secrets never appear in ToolDescriptor, prompts, runtime events, memory, or replay. Executors receive scoped opaque handles. Full Access cannot widen scope. Credential revocation invalidates pending invocations.

### MCP

MCP is a first-class provider with initialize/discovery, `tools/list`, runtime refresh, enable/disable, hot revoke, and registry revision events. MCP descriptions/results and external web/email/document content preserve untrusted provenance/taint. MCP annotations are advisory.

### Plugins

Plugin is not equivalent to MCP. The first production plugin format is a declarative manifest containing capabilities, permissions, credential requirements, optional MCP configuration, provenance, and version. Arbitrary in-process third-party Swift loading is not part of V2.

## 7. Persistent Memory, Event Store, Checkpoints, and Replay

Storage concerns are separated:

```text
ConversationStore
EventStore
MemoryStore
CheckpointStore
```

Credentials remain only behind CredentialBroker/Keychain.

`EventStore` is the append-only runtime journal. The canonical event envelope includes:

- eventID;
- streamID;
- sequence;
- schemaVersion;
- goalID/taskID/sessionID;
- eventKind;
- causationID/correlationID;
- taskGraphRevision;
- toolRegistryRevision;
- policyRevision;
- payload;
- redaction class;
- provenance/taint;
- recordedAt.

Sequence, not wall-clock timestamp, is the deterministic ordering authority. Existing ExamPilot `AgentEvent` remains a diagnostic DTO and must not become the database schema.

Memory hierarchy:

- working;
- episodic;
- semantic;
- procedural.

Scopes:

- session;
- goal;
- workspace/project;
- application;
- user.

Never persist in Event/Memory:

- raw credentials/API keys/Authorization headers;
- CredentialBroker handles;
- complete provider requests/responses;
- model private reasoning;
- raw screenshots by default;
- private physical typed content.

Procedural memory provides strategy priors only. It cannot mutate or bypass `PolicyKernel` hard rules.

### Replay

Replay is not physical re-execution. Replay mode has network OFF, live model calls OFF, physical input OFF, real mutations OFF, and external communication OFF. Recorded normalized provider proposals, observations, evidence, policy/verifier inputs, and replay artifacts are fed through deterministic reducers and replay/null executors.

### Checkpoints and resume

Checkpoint is a replay-acceleration snapshot, not a replacement for history and not an authority token. It may contain graph snapshot/revision, task lifecycle, budgets, bounded working memory, provider continuation metadata, event cursor, and memory projection version.

It must not contain live credential handles, old approval tokens, old PolicyKernel decisions, executable ToolInvocations, physical input permission, or Full Access continuation authority.

Restart flow:

```text
load checkpoint
→ replay subsequent events
→ restore paused/reconciling
→ refresh ToolRegistry
→ discard credential handles
→ load current PolicyKernel
→ re-observe external/world state
→ reconcile outstanding mutations/idempotency
→ rebuild readiness
→ resume scheduler
```

Unknown high-risk external mutation state is never blindly retried.

## 8. ComputerAgentCore Extraction

Do not rewrite ExamPilot.

Target structure:

```text
ComputerAgentCore
↑
ComputerAgentMacOS
↑
├── ExamPilotCore
└── ZeroLose V2
```

ZeroLose must not depend on ExamPilot domain logic.

Generic session state contains session/goal/task/profile IDs, stateVersion, currentObservationID, bounded working memory, provider continuation, stop state, and lifecycle. `questionGeneration`, `answerVerified`, and `ExamUIPhase` are exam-profile concerns and leave generic core.

Three policy layers exist:

1. `PolicyKernel` for global authority/security;
2. `ComputerAgentSafetyPolicy` for generic computer-use safety/correctness;
3. `TaskProfilePolicy` for domain-specific correctness.

Observation fusion combines ScreenCaptureKit, Accessibility, browser semantics, and vision/OCR into a `ComputerObservation`, while preserving identity, provenance, taint, and confidence. Conflicting process/window identities cause re-observation rather than a fabricated combined observation.

Providers produce proposals, never execute. OpenAI Computer Use and structured vision fallback normalize into the same `ComputerActionProposal` path. Policy denial must not be bypassed by switching provider.

ExecutionReceipt is not semantic success, and ComputerAgent success is not TaskRuntime/Goal success. Recovery never blindly replays physical actions.

Standalone ExamPilot may use its validated standalone mutation gateway. ZeroLose production must use the ToolFabric-backed mutation gateway.

## 9. ZeroLose UI V2

Keep the useful SwiftUI/macOS visual shell, but separate it from execution.

```text
SwiftUI Views
→ V2 ViewModels
→ ApplicationFacade / Commands
→ ZeroLose Kernel V2
```

Views and view models do not directly execute tools, call model providers, decide policy, access raw credentials, regex-parse actions, or perform memory consolidation.

Focused view models may include `ChatViewModel`, `TaskRuntimeViewModel`, `ApprovalViewModel`, `ToolManagementViewModel`, `MemoryInspectorViewModel`, and `SettingsViewModel`.

Typed application commands include goal/chat submit, pause/resume/cancel, approval decisions, tool/MCP enable-disable, memory pin/forget, and authority-mode change.

Timeline is an EventStore projection. UI success is shown only after verifier evidence. Approval UI presents operation, tool/provider, effect/risk, destination, credential scope, external mutation status, taint/untrusted input, and reason approval is required.

Presentation preferences such as font/theme/opacity may remain in UserDefaults/AppStorage. Authority, permissions, credential scopes, and policy grants are not UserDefaults strings.

## 10. Migration and Legacy Demolition

Migration is versioned, idempotent, restart-safe, and transactional where practical. V2 verification occurs before valuable legacy data is deleted.

Legacy `commandApprovalMode` maps:

```text
ask  → Manual / Chat
auto → Auto
full → Auto
```

Legacy `full` must never silently migrate to V2 Full Access.

Legacy chat/history moves to `ConversationStore`, with optional derived semantic indexing. Existing Keychain credentials remain in Keychain and are wrapped by CredentialBroker.

No new V2 feature is added to `GhostViewModel`.

Demolition order after parity:

1. native structured V2 invocation becomes authoritative;
2. ComputerAgentCore V2 path becomes authoritative;
3. Tool Fabric parity completes;
4. UI V2 uses ApplicationFacade;
5. valuable data migration is verified;
6. remove ACTION prompt generation;
7. remove action regex;
8. remove `handleActions`;
9. remove broken-JSON recovery;
10. remove native-tool → ACTION conversion;
11. remove AgentCapabilityRegistry execution dependency;
12. remove legacy approval semantics;
13. remove direct UI → ZeroOperator mutation path;
14. remove obsolete computer-use paths;
15. remove GhostViewModel after all valuable consumers have moved;
16. remove dead adapters.

No permanent dual runtime remains.

## 11. Hard Invariants

1. Unknown tool IDs fail closed.
2. Stale/revoked descriptors do not execute.
3. Raw credentials never reach the model.
4. Provider risk metadata cannot override PolicyKernel.
5. Full Access cannot bypass policy or credential boundaries.
6. External content provenance/taint is preserved.
7. Mutation completion requires execution receipt plus verifier evidence.
8. External mutations require idempotency/duplicate protection.
9. ComputerAgent cannot bypass Tool Fabric for ZeroLose physical execution.
10. `[ACTION: {...}]` compatibility does not exist at the V2 boundary.
11. Replay never executes real mutation.
12. Checkpoints carry no executable authority.
13. Resume always re-observes/reconciles the world.
14. Raw screenshot is not persisted by default.
15. Private physical typed content is not stored in autonomous memory/event history.
16. Conversation history and autonomous memory are separate concerns.
17. Procedural memory cannot change/bypass PolicyKernel.
18. Event schema is versioned; unknown versions fail closed.
19. ComputerAgent provider only proposes; it never performs physical execution.
20. Batch planning is not batch authority.
21. Focus/target identity is verified immediately before physical input.
22. Policy denial cannot be bypassed through provider fallback.
23. Cancellation reaches active native input.
24. UI does not execute tools or own security authority.
25. Legacy `full` does not auto-migrate to V2 Full Access.
26. New V2 features are not added to GhostViewModel.
27. Legacy demolition occurs only after verified V2 parity.

## 12. Testing and Implementation Strategy

Runtime behavior changes use TDD:

```text
RED
→ minimal GREEN
→ focused verification
→ affected suite
```

Existing ExamPilot behavior is protected with characterization/regression tests before extraction. Architecture guard tests must prevent V2 from importing ExamPilot domain types, bypassing Tool Fabric, or reintroducing legacy ACTION execution.

Implementation is split into independently reviewable tracks rather than one mega-PR:

1. V2 foundation contracts;
2. Unified Tool Fabric providers;
3. persistence, memory, checkpoint and replay;
4. ComputerAgentCore extraction;
5. AutonomousRuntime/TaskGraph/Scheduler;
6. UI migration and legacy demolition.

Before repository-wide completion:

```bash
python3 scripts/verify_all.py
```

The architecture is considered implemented only when all real mutations are current-policy gated and verified, credentials remain hidden, replay is non-mutating, persistent restart reconstruction is safe, ComputerAgentCore is generic, ZeroLose cannot bypass Tool Fabric for input, V2 UI is projection/command based, valuable user data migration is verified, legacy ACTION execution is deleted, GhostViewModel is removed after parity, ExamPilot regressions remain protected, and repository-wide verification passes.
