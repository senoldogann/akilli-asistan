# Computer Agent Runtime V2 Slice 6 Persistence and Safe Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local-first append-only event persistence, separate provider-conversation and working-memory stores, and a read-only replay/resume checkpoint that can never restore stale runtime truth directly into physical execution.

**Architecture:** Persistence is split into three protocols with one shared SQLite implementation: `AgentEventStore` is append-only, `AgentConversationStore` owns provider continuation metadata, and `AgentMemoryStore` owns bounded structured working-memory snapshots. Replay projects stored events into read-only state. Resume preparation returns a checkpoint marked `requiresFreshObservation` and `requiresReconciliation`; it does not construct or run an `ExamLoop`, does not invoke `InputDriving`, and does not restore answer/navigation truth or pending provider calls as executable state.

**Tech Stack:** Swift 5.10, SwiftPM, Foundation, system SQLite3, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-08-computer-agent-runtime-v2-design.md`

## Global Constraints

- Model/provider output remains untrusted intent, never executable authority.
- Persist structured state only; never persist screenshots, API keys, Authorization headers, raw typed text, or complete provider payloads.
- Event persistence is append-only: no update/delete API is exposed by `AgentEventStore`.
- Provider continuation state and working-memory state are stored through separate protocols even when they share one SQLite database file.
- Replay is read-only and deterministic.
- Resume may use persisted data only as historical context. It must require a fresh observation and explicit reconciliation before a live runtime can use any restored context.
- Resume never treats persisted `answerVerified`, navigation eligibility, UI phase, state version, or pending computer call as current world truth.
- Existing physical-input, focus, stale-state, answer-before-navigation, verification, recovery, and cancellation invariants remain unchanged.
- `.freebuff/` remains untouched and untracked.

---

### Task 1: Persistence contracts and redacted event records

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/AgentPersistence.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/AgentPersistenceTests.swift`

**Interfaces:**
- Produces `StoredAgentEvent`, `AgentEventStore`, `AgentConversationRecord`, `AgentConversationStore`, `AgentMemoryRecord`, `AgentMemoryStore`, and `AgentPersistenceError`.
- `StoredAgentEvent` owns a monotonically increasing store sequence and a sanitized `AgentEvent`.

- [x] **Step 1: Write failing contract tests** proving event-store API has append/read semantics, persistence models round-trip with Codable, and unsafe event detail is replaced by `redacted_detail` before persistence.
- [x] **Step 2: Run `cd ExamPilot && swift test --filter AgentPersistenceTests` and observe RED** because the persistence contracts do not exist.
- [x] **Step 3: Implement the minimal data models/protocols and one shared detail sanitizer**. The sanitizer accepts only lowercase ASCII `a-z`, digits, `_`, `.`, `-`, maximum 64 characters; every other detail becomes `redacted_detail`.
- [x] **Step 4: Run the focused tests and observe GREEN.**
- [x] **Step 5: Commit only Task 1 files.**

### Task 2: SQLite-backed stores with append-only events

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/SQLiteAgentPersistence.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/SQLiteAgentPersistenceTests.swift`
- Modify: `ExamPilot/Package.swift`

**Interfaces:**
- Produces `SQLiteAgentPersistence`, a single database owner exposing protocol-conforming event, conversation, and memory store operations.
- Schema version 1 contains `agent_events`, `agent_conversations`, and `agent_memory`.
- `agent_events.sequence INTEGER PRIMARY KEY AUTOINCREMENT`; rows are only inserted and selected by the public API.
- Conversation and memory rows are keyed by `session_id` and may be atomically upserted.

- [x] **Step 1: Write failing SQLite tests** using a unique temporary database. Prove event insertion order, session-scoped reads, append-only public surface, conversation replacement, memory replacement, close/reopen persistence, and malformed-record failure classification.
- [x] **Step 2: Run `cd ExamPilot && swift test --filter SQLiteAgentPersistenceTests` and observe RED.**
- [x] **Step 3: Add explicit `sqlite3` linker configuration to `Package.swift` and implement the smallest prepared-statement wrapper.** Use bound parameters only, `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`, and `PRAGMA user_version=1`. Never interpolate stored values into SQL.
- [x] **Step 4: Store event fields in typed columns plus sanitized detail; encode conversation/memory records as bounded JSON blobs.** Reject blobs larger than 64 KiB before writing or after reading.
- [x] **Step 5: Run focused SQLite tests and observe GREEN.**
- [x] **Step 6: Commit Task 2 files.**

### Task 3: Read-only deterministic replay and resume checkpoint

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/AgentReplay.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/AgentReplayTests.swift`

**Interfaces:**
- Produces `AgentReplaySnapshot`, `AgentReplayProjector`, and `AgentResumeCheckpoint`.
- `AgentReplayProjector.project(events:)` folds only stored events and never calls provider, capture, executor, input, or focus services.
- `AgentResumeCheckpoint` exposes persisted conversation/memory as historical context plus `requiresFreshObservation == true` and `requiresReconciliation == true`.
- No API in this task creates an executable `ComputerAgentSession` from persisted runtime coordinates.

- [x] **Step 1: Write failing replay tests** proving deterministic fold order, latest runtime coordinates, current question answer evidence derived from event history, and that an empty event list produces an inert snapshot.
- [x] **Step 2: Write failing resume tests** proving persisted `answerVerified`, transitioning UI state, and pending provider call IDs do not become executable runtime state; checkpoint always requires fresh observation and reconciliation.
- [x] **Step 3: Run `cd ExamPilot && swift test --filter AgentReplayTests` and observe RED.**
- [x] **Step 4: Implement the minimal projector/checkpoint.** Replay may describe historical state but must not expose `navigationAllowed` as live authority.
- [x] **Step 5: Run focused tests and observe GREEN.**
- [x] **Step 6: Commit Task 3 files.**

### Task 4: Persistent event sink and session checkpoint coordinator

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/AgentPersistenceCoordinator.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/AgentPersistenceCoordinatorTests.swift`

**Interfaces:**
- Produces `PersistentAgentEventSink`, `CompositeAgentEventSink`, and `AgentPersistenceCoordinator`.
- `PersistentAgentEventSink.record(_:)` appends a sanitized event and reports storage errors through a bounded callback without leaking record content.
- `AgentPersistenceCoordinator.checkpoint(session:)` stores provider-conversation and working-memory snapshots separately.
- `prepareResume(sessionID:)` returns `AgentResumeCheckpoint`; it never mutates physical state.

- [x] **Step 1: Write failing tests** proving composite sinks preserve ordering, persistence failures expose only a stable error identifier, session checkpointing writes conversation/memory separately, and resume preparation is read-only.
- [x] **Step 2: Run `cd ExamPilot && swift test --filter AgentPersistenceCoordinatorTests` and observe RED.**
- [x] **Step 3: Implement the minimal sink/coordinator.** Do not wire persistence into the default CLI in this slice; default runtime behavior therefore cannot regress because a database is unavailable.
- [x] **Step 4: Run focused tests and observe GREEN.**
- [x] **Step 5: Commit Task 4 files.**

### Task 5: Security and repository verification

**Files:**
- Modify: `ExamPilot/README.md`
- Modify: `docs/superpowers/plans/2026-09-09-computer-agent-runtime-v2-slice6.md`

**Interfaces:**
- Documents the three-store boundary, SQLite location being caller-controlled, append-only event semantics, bounded/redacted persistence, and the fact that replay/resume does not execute physical input.

- [x] **Step 1: Add focused regression tests** asserting raw typed text and deliberately credential-shaped strings are not persisted in event detail and that resume never restores a verified answer as current authority.
- [x] **Step 2: Run `cd ExamPilot && swift test` and require all tests green.**
- [x] **Step 3: Run `cd ExamPilot && swift build -c release` and require success.**
- [x] **Step 4: Run `python3 scripts/verify_all.py` from repository root and require success.**
- [x] **Step 5: Run `git diff --check` and inspect the final diff for secret/logging/input-boundary regressions.**
- [x] **Step 6: Update this plan's checkboxes to reflect completed evidence and commit docs.**

## Verification Evidence

- Baseline before Slice 6: repository gate green with 118 ExamPilot tests.
- Task 1 RED: persistence contract types missing; GREEN: 4 focused tests.
- Task 2 RED: `SQLiteAgentPersistence` missing; GREEN: 7 focused tests.
- Task 3 RED: replay/checkpoint types missing; GREEN: 6 focused tests.
- Task 4 RED: persistence sink/coordinator types missing; GREEN: 5 focused tests.
- Final `swift test`: 140 tests, 0 failures.
- Final `swift build -c release`: success.
- Final `python3 scripts/verify_all.py`: success, including 140 ExamPilot tests, release build, CLI help verification, and ZeroLose unsigned Xcode build.
- Final architecture scan: no replay/persistence source references to physical input, capture, focus, provider implementations, or API credential environment symbols.
- Final `git diff --check`: clean.

## Definition of Done

- `AgentEventStore` has no update/delete API and SQLite event rows are inserted in monotonic sequence order.
- Conversation and working-memory persistence are separate interfaces.
- Persisted event detail is bounded/redacted before storage.
- No screenshot, raw typed text, API key, Authorization header, or complete provider payload is persisted by this slice.
- Replay is deterministic and read-only.
- Resume preparation cannot directly produce a live verified-answer/navigation state and always requires fresh observation plus reconciliation.
- No new code path calls `InputDriving`, `ActionBatchExecutor`, focus services, or provider APIs from replay/resume.
- Existing 118-test baseline and the full repository gate remain green on final head, with new tests added on top.
