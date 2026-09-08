# Computer Agent Runtime V2 Slice 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `ComputerAgentSession` and bounded session-local working memory so runtime state, recent failures/actions/evidence, provider continuity metadata, and event correlation have one deterministic owner without adding persistent storage yet.

**Architecture:** Add focused session/memory value types, keep the existing `ExamRuntimeState` state machine as the correctness source, and make `ExamLoop` consume one session object rather than parallel ad-hoc locals. Working memory stores bounded structured identifiers only; it never stores screenshots, raw typed text, API secrets, Authorization values, or raw request payloads. Existing physical-input, policy, verifier, and recovery boundaries remain unchanged.

**Tech Stack:** Swift 6-compatible Swift Package Manager, XCTest, existing ExamPilotCore runtime.

**Spec:** `docs/superpowers/specs/2026-09-08-computer-agent-runtime-v2-design.md`

## Global Constraints

- macOS-first; preserve ScreenCaptureKit/CoreGraphics execution behavior.
- Runtime correctness must not be delegated to memory or provider output.
- Memory may influence context/recovery ranking but may not weaken stale-state or navigation invariants.
- No persistent SQLite storage in this slice.
- No native OpenAI Computer Use implementation in this slice.
- No AX/DOM sensor fusion in this slice.
- Diagnostic screenshots are not persisted.
- Run `cd ExamPilot && swift test` and `swift build -c release` before completion.

---

### Task 1: Bounded Working Memory

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/AgentWorkingMemory.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/AgentWorkingMemoryTests.swift`

**Interfaces:**
- Produces: `AgentWorkingMemory`, `AgentWorkingMemorySnapshot`, `AgentActionMemory`, `AgentFailureMemory`, `AgentEvidenceMemory`.
- Consumes: `AgentIntentFingerprint`, `AgentFailureReason`, `RecoveryStrategy`, `ExpectedOutcome`, `UInt64 stateVersion/questionGeneration`.

- [ ] **Step 1: Write failing tests** proving: records are bounded FIFO; raw typed text and model summaries are absent from memory/debug descriptions; action/failure/evidence records preserve state version and question generation; current recovery strategy can be set/cleared; snapshot is immutable/equatable.
- [ ] **Step 2: Run** `cd ExamPilot && swift test --filter AgentWorkingMemoryTests` and verify RED because the types do not exist.
- [ ] **Step 3: Implement minimal bounded structs** with configurable capacities clamped to at least 1. Store only structured fingerprints/enums/version counters/timestamps expressed as monotonic sequence numbers supplied by the caller; do not retain `ExamDecision.summary`, `ExamAction.text`, screenshot bytes, headers, or API keys.
- [ ] **Step 4: Run** `cd ExamPilot && swift test --filter AgentWorkingMemoryTests` and verify GREEN.
- [ ] **Step 5: Commit** `feat: add bounded computer agent working memory`.

### Task 2: Provider Conversation State and Session Ownership

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ComputerAgentSession.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ComputerAgentSessionTests.swift`

**Interfaces:**
- Produces: `ComputerAgentSession`, `ComputerAgentTaskProfile`, `ProviderConversationState`, `AgentStopState`.
- Session exposes read-only `id`, `goal`, `taskProfile`, `runtimeState`, `workingMemory`, `providerConversationState`, `stopState` and narrow mutation methods.

- [ ] **Step 1: Write failing tests** proving: explicit session IDs are stable; default IDs are non-empty; runtime transition methods delegate to `ExamRuntimeState`; working memory survives observation cycles; provider `previousResponseID` can be updated/cleared without changing runtime correctness; stop state is monotonic from running to stopRequested/stopped.
- [ ] **Step 2: Run** `cd ExamPilot && swift test --filter ComputerAgentSessionTests` and verify RED because session types do not exist.
- [ ] **Step 3: Implement minimal session model**. Default identifier uses `UUID().uuidString`; task profile initially contains `.exam`; provider state contains only `previousResponseID: String?`; no network/provider logic is added.
- [ ] **Step 4: Run** filtered tests and verify GREEN.
- [ ] **Step 5: Commit** `feat: add computer agent session state owner`.

### Task 3: Session-Correlated Structured Events

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`

**Interfaces:**
- `AgentEvent` gains `sessionID: String` with an initializer default preserving existing call sites until `ExamLoop` integration.

- [ ] **Step 1: Add failing tests** proving encoded events contain the session ID and still exclude Authorization/API-key/raw typed-text values.
- [ ] **Step 2: Run** `cd ExamPilot && swift test --filter AgentEventTests`; verify RED on missing `sessionID`.
- [ ] **Step 3: Add `sessionID`** and preserve all existing event kinds/details.
- [ ] **Step 4: Run** filtered tests; verify GREEN.
- [ ] **Step 5: Commit** `feat: correlate agent events by session`.

### Task 4: Provider-Facing Working Memory Snapshot

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/VisionAgent.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/OpenAIResponsesVisionAgent.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/OpenAIResponsesVisionAgentTests.swift`

**Interfaces:**
- `ExamObservationState` gains `sessionID` and `workingMemory: AgentWorkingMemorySnapshot`.
- Existing structured-vision provider prompt receives only compact structured memory metadata: recent failure identifiers/count, recent evidence outcomes, current recovery strategy, and provider continuity presence. It must not receive raw prior typed text from working memory.

- [ ] **Step 1: Add failing request/prompt tests** asserting session ID and compact memory fields appear, while a sentinel private answer is absent.
- [ ] **Step 2: Run** `cd ExamPilot && swift test --filter OpenAIResponsesVisionAgentTests`; verify RED on missing fields.
- [ ] **Step 3: Implement minimal state/prompt extension**. Preserve current Responses request schema and `detail: high` in this slice; provider API modernization belongs to Slice 5.
- [ ] **Step 4: Run** filtered tests; verify GREEN.
- [ ] **Step 5: Commit** `feat: expose bounded working memory to planner`.

### Task 5: Integrate Session into ExamLoop

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopSessionTests.swift`
- Modify existing loop tests only when constructor compatibility requires it.

**Interfaces:**
- `ExamLoop` initializer accepts optional `session: ComputerAgentSession?`; when omitted, create a session from the current `initialRuntimeState` to preserve callers.
- Replace local runtime/summary ownership with session-owned state and working memory.
- Record proposed intent, classified failures/recovery decisions, verified outcomes, and successful navigation/answer evidence into working memory.
- All emitted events use `session.id`.

- [ ] **Step 1: Write failing tests** proving: the same session ID reaches all loop events; policy denial/recovery writes bounded failure memory; verified answer writes evidence memory; successful navigation updates session runtime generation; existing unanswered-navigation zero-input invariant remains true.
- [ ] **Step 2: Run** `cd ExamPilot && swift test --filter ExamLoopSessionTests`; verify RED on missing integration.
- [ ] **Step 3: Implement minimal integration** without changing physical executor behavior, policy rules, verifier thresholds, or recovery budgets.
- [ ] **Step 4: Run** `cd ExamPilot && swift test`; all tests must pass.
- [ ] **Step 5: Commit** `feat: integrate computer agent session into exam loop`.

### Task 6: Slice Verification and Scope Gate

**Files:**
- No production behavior beyond fixes required by failing tests.

- [ ] **Step 1: Run** `cd ExamPilot && swift test` and record exact test count/zero failures.
- [ ] **Step 2: Run** `cd ExamPilot && swift build -c release` and require success.
- [ ] **Step 3: Review changed files** and confirm no SQLite, native Computer Use, AX/DOM fusion, benchmark/replay, or package rename leaked into this slice.
- [ ] **Step 4: Review privacy**: no screenshots/base64, Authorization/API key, raw typed answer/code, or raw request payload are retained by working memory or events.
- [ ] **Step 5: Commit only if verification-driven corrections were needed**.

## Self-Review

- Spec coverage: implements migration step 7 only: `ComputerAgentSession` + working memory; provider continuity is represented as data but not yet used for Responses continuation.
- Placeholder scan: no TODO/TBD/deferred implementation placeholders are present.
- Type consistency: session owns `ExamRuntimeState` and `AgentWorkingMemory`; provider state is an opaque continuation identifier only; persistent memory remains a future protocol/storage slice.
- Scope boundary: no changes to physical input semantics or current hard runtime invariants are permitted.
