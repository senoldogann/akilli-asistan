# ZeroLose V2 Persistence and Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable append-only runtime events, authority-free checkpoints, scoped memory stores, deterministic non-mutating replay, and restart reconciliation primitives.

**Architecture:** SQLite implements storage protocols. Event history is authoritative and append-only; memory is derived knowledge rather than execution authority. Replay reconstructs control flow from recorded normalized data using replay/null executors only.

**Tech Stack:** Swift, SQLite3, Codable, Swift actors, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Never persist raw credentials, Authorization headers, CredentialBroker handles, private chain-of-thought, private typed content, or raw screenshots by default.
- Event `sequence`, not wall-clock time, is deterministic ordering authority.
- Unknown event schema versions fail closed.
- Replay never uses live network, live model, physical input, real mutation, or external communication.
- Checkpoints carry no executable authority.
- Unknown high-risk external mutation state never blindly retries.
- TDD required; final gate `python3 scripts/verify_all.py`.

---

### Task 1: SQLiteEventStore

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Persistence/SQLiteDatabase.swift`
- Create: `ZeroLose/ZeroLose/V2/Persistence/SQLiteEventStore.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/SQLiteEventStoreTests.swift`

**Interfaces:** Implements `EventStoring` over SQLite with append-only rows and unique `(stream_id, sequence)`.

- [ ] **Step 1: Write failing ordering/version tests**

```swift
func testEventsReturnInSequenceOrder() async throws {
    let store = try SQLiteEventStore(databaseURL: temporaryDatabaseURL())
    try await store.append(.test(streamID: "g1", sequence: 2))
    try await store.append(.test(streamID: "g1", sequence: 1))
    XCTAssertEqual(try await store.events(streamID: "g1", after: 0).map(\.sequence), [1, 2])
}

func testUnknownSchemaVersionFailsClosed() async throws {
    let store = try SQLiteEventStore(databaseURL: temporaryDatabaseURL())
    try insertRawEvent(schemaVersion: 999, into: store)
    await XCTAssertThrowsErrorAsync(try await store.events(streamID: "g1", after: 0))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/SQLiteEventStoreTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement actor-isolated SQLite persistence**

Create an append-only events table containing the complete canonical envelope. Do not add update APIs that rewrite historical runtime events.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Persistence ZeroLose/ZeroLoseTests/V2/SQLiteEventStoreTests.swift
git commit -m "feat: persist V2 runtime events in SQLite"
```

### Task 2: Authority-free CheckpointStore

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Checkpoint/RuntimeCheckpoint.swift`
- Create: `ZeroLose/ZeroLose/V2/Checkpoint/CheckpointStore.swift`
- Create: `ZeroLose/ZeroLose/V2/Checkpoint/SQLiteCheckpointStore.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RuntimeCheckpointTests.swift`

**Interfaces:** Checkpoint contains event cursor, TaskGraph revision/snapshot, lifecycle/budgets, bounded working memory, provider continuation metadata. It excludes credential handles, approval tokens, policy decisions, executable ToolInvocations, and physical permission.

- [ ] **Step 1: Write failing restore/authority tests**

```swift
func testRestoredCheckpointStartsPausedReconciling() {
    let restored = RuntimeCheckpoint.test().restoredRuntimeState()
    XCTAssertEqual(restored.lifecycle, .paused)
    XCTAssertTrue(restored.requiresReconciliation)
}
```

Add a source-level test ensuring `RuntimeCheckpoint.swift` contains no stored `CredentialHandle`, `PolicyDecision`, or `ToolInvocation`.

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeCheckpointTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement checkpoint contracts**

```swift
struct RuntimeCheckpoint: Codable, Sendable {
    let streamID: String
    let eventSequence: UInt64
    let taskGraphRevision: UInt64
    let boundedWorkingMemory: Data
    let providerContinuationMetadata: Data?
    let createdAt: Date
}
```

Restore always returns paused/reconciling state.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Checkpoint ZeroLose/ZeroLoseTests/V2/RuntimeCheckpointTests.swift
git commit -m "feat: add authority-free V2 checkpoints"
```

### Task 3: Scoped episodic, semantic, procedural memory

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Memory/MemoryModels.swift`
- Create: `ZeroLose/ZeroLose/V2/Memory/MemoryStore.swift`
- Create: `ZeroLose/ZeroLose/V2/Memory/SQLiteMemoryStore.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MemoryStoreTests.swift`

**Interfaces:** Memory scopes: session, goal, workspace/project, application, user. Provenance/taint survive promotion. Procedural memory requires multiple evidence points and never becomes policy authority.

- [ ] **Step 1: Write failing taint/promotion tests**

```swift
func testSemanticFactPreservesTaint() async throws {
    let store = try SQLiteMemoryStore(databaseURL: temporaryDatabaseURL())
    try await store.save(.testSemantic(id: "f1", tainted: true, provenance: .externalDocument))
    XCTAssertEqual(try await store.semantic(id: "f1")?.tainted, true)
}

func testOneSuccessDoesNotPromoteProcedure() {
    XCTAssertFalse(ProceduralPromotionPolicy(minimumSuccesses: 3).shouldPromote(successes: 1, failures: 0))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/MemoryStoreTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement typed memory records and store**

Store structured episode summaries, facts, strategy IDs/statistics, confidence, scope, provenance, taint, created/confirmed/invalidated timestamps. Do not store raw screenshots or private typed strings.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Memory ZeroLose/ZeroLoseTests/V2/MemoryStoreTests.swift
git commit -m "feat: add scoped V2 memory stores"
```

### Task 4: Deterministic ReplayRuntime

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Replay/ReplayArtifact.swift`
- Create: `ZeroLose/ZeroLose/V2/Replay/ReplayToolExecutor.swift`
- Create: `ZeroLose/ZeroLose/V2/Replay/ReplayRuntime.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ReplayRuntimeTests.swift`

**Interfaces:** Consumes EventStore, recorded normalized provider proposals and evidence. Produces reconstructed state only.

- [ ] **Step 1: Write failing no-live-mutation test**

```swift
func testReplayNeverCallsLiveExecutor() async throws {
    let live = RecordingLiveExecutor()
    let replay = ReplayRuntime(events: [.testToolExecution()], executor: ReplayToolExecutor(), forbiddenLiveExecutor: live)
    _ = try await replay.run()
    XCTAssertEqual(await live.executionCount, 0)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ReplayRuntimeTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement replay-only reducer/executor**

```swift
protocol ReplayExecuting: Sendable {
    func receipt(for recordedEvent: RuntimeEvent) async throws -> ToolExecutionReceipt
}
```

Replay artifacts may include visual fingerprints, normalized AX/browser evidence, target confidence, UI stability and verifier inputs. No live provider/network/native-input dependency is allowed.

- [ ] **Step 4: Verify and scan dependencies**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
git grep -n 'CoreGraphics\|URLSession\|InputDriving' -- ZeroLose/ZeroLose/V2/Replay
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Replay ZeroLose/ZeroLoseTests/V2/ReplayRuntimeTests.swift
git commit -m "feat: add deterministic non-mutating replay"
```

### Task 5: External mutation journal and reconciliation

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Persistence/ExternalMutationJournal.swift`
- Create: `ZeroLose/ZeroLose/V2/Persistence/MutationReconciler.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MutationReconcilerTests.swift`

**Interfaces:** Persists logical operation ID, idempotency key, attempt, receipt, verification, external reference/state. Outcomes include already applied, not applied, unknown.

- [ ] **Step 1: Write failing high-risk unknown-state test**

```swift
func testUnknownHighRiskMutationIsNotBlindlyRetried() async {
    let reconciler = MutationReconciler(policy: .failClosedForUnknownHighRisk)
    let decision = await reconciler.decide(record: .test(risk: .highImpactExternalMutation, externalState: .unknown))
    XCTAssertEqual(decision, .requiresManualResolution)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/MutationReconcilerTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement persistent journal/reconciler**

```swift
struct ExternalMutationRecord: Codable, Sendable {
    let logicalOperationID: String
    let idempotencyKey: String
    let invocationID: InvocationID
    let attempt: UInt32
    let receipt: Data?
    let verification: Data?
}
```

- [ ] **Step 4: Verify GREEN and repository gate**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
python3 scripts/verify_all.py
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Persistence ZeroLose/ZeroLoseTests/V2/MutationReconcilerTests.swift
git commit -m "feat: persist external mutation reconciliation state"
```

### Track completion gate

```bash
python3 scripts/verify_all.py
git diff --check
```

Expected: PASS; replay cannot mutate, checkpoints contain no authority, and persistence contains no raw secret material.
