# ZeroLose V2 Autonomous Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the persistent TaskGraph, Scheduler, TaskRuntime, planner/verifier contracts, budgets, cancellation propagation, and restart reconciliation needed for long-horizon autonomous execution.

**Architecture:** Planner changes plans only through graph revisions; Scheduler chooses ready work but never executes tools; TaskRuntime owns one task lifecycle and invokes Tool Fabric or ComputerAgentCore; verifier evidence alone completes tasks and goals. Mutation tasks serialize by default while bounded read tasks may run concurrently.

**Tech Stack:** Swift actors, structured concurrency, EventStore/CheckpointStore, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Planner never executes mutations.
- Scheduler never executes tools.
- Task completion requires verifier evidence; goal completion requires `GoalVerifier`.
- Mutation tasks serialize by default.
- Read tasks use bounded concurrency.
- Retry and recovery are bounded; unchanged failed strategies cannot blindly repeat.
- Policy is re-evaluated before each mutation.
- Cancellation propagates to active child work/native input.
- Restore never executes checkpointed physical proposals.
- TDD required; final gate `python3 scripts/verify_all.py`.

---

### Task 1: TaskGraph revisions and lifecycle reducer

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/TaskLifecycle.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/TaskNode.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/TaskGraph.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/TaskGraphTests.swift`

**Interfaces:** Actor-owned graph with monotonic revision, dependencies, legal lifecycle transitions, EventStore emission. `succeeded` requires verification evidence.

- [ ] **Step 1: Write failing revision/evidence tests**

```swift
func testAddingTaskCreatesNewGraphRevision() async {
    let graph = TaskGraph(goalID: .init(rawValue: "g1"))
    XCTAssertEqual(await graph.revision, 0)
    await graph.add(.test(id: "t1"))
    XCTAssertEqual(await graph.revision, 1)
}

func testSucceededRequiresVerificationEvidence() async {
    let graph = TaskGraph(goalID: .init(rawValue: "g1"))
    await graph.add(.test(id: "t1"))
    await XCTAssertThrowsErrorAsync(try await graph.transition(taskID: .init(rawValue: "t1"), to: .succeeded, evidence: nil))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/TaskGraphTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement approved lifecycle**

```swift
enum TaskLifecycle: String, Codable, Sendable {
    case created, blocked, ready, planning, running, verifying, succeeded, failed, recovering, replanned, exhausted, paused, cancelled, waitingExternal, waitingApproval
}
```

Every graph mutation increments revision and appends a graph revision/state event.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/TaskLifecycle.swift ZeroLose/ZeroLose/V2/Autonomy/TaskNode.swift ZeroLose/ZeroLose/V2/Autonomy/TaskGraph.swift ZeroLose/ZeroLoseTests/V2/TaskGraphTests.swift
git commit -m "feat: add persistent V2 task graph"
```

### Task 2: Planner contract and progressive decomposition

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/Planner.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/PlanningProposal.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/PlannerContractTests.swift`

**Interfaces:** Planner consumes immutable goal/graph/budget snapshots and returns graph changes only. It has no ToolFabric/native executor reference.

- [ ] **Step 1: Write failing contract/source tests**

```swift
func testPlanningProposalContainsGraphChangesOnly() {
    let proposal = PlanningProposal(addTasks: [.test(id: "inspect")], addDependencies: [], markBlocked: [])
    XCTAssertEqual(proposal.addTasks.count, 1)
}
```

Architecture test: `Planner.swift` must not contain `ToolFabric`, `InputDriving`, or `ComputerMutationGating` stored dependencies.

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/PlannerContractTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement planner boundary**

```swift
protocol Planning: Sendable {
    func propose(goal: GoalSnapshot, graph: TaskGraphSnapshot, budgets: RuntimeBudgetSnapshot) async throws -> PlanningProposal
}
```

Planner may progressively add near-term tasks as evidence arrives rather than creating one immutable mega-plan.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/Planner.swift ZeroLose/ZeroLose/V2/Autonomy/PlanningProposal.swift ZeroLose/ZeroLoseTests/V2/PlannerContractTests.swift
git commit -m "feat: define non-executing V2 planner contract"
```

### Task 3: Scheduler with serialized mutation and bounded reads

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/ConcurrencyClass.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/Scheduler.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/SchedulerTests.swift`

**Interfaces:** Scheduler returns ready task IDs only. Mutation concurrency defaults to 1; reads are bounded by configuration.

- [ ] **Step 1: Write failing concurrency tests**

```swift
func testMutationTasksAreSerializedByDefault() async {
    let scheduler = Scheduler(maxParallelReads: 4)
    let ready = [TaskNode.test(id: "m1", concurrency: .mutation), TaskNode.test(id: "m2", concurrency: .mutation)]
    XCTAssertEqual(await scheduler.select(from: ready).count, 1)
}

func testReadsRespectConfiguredBound() async {
    let scheduler = Scheduler(maxParallelReads: 2)
    let ready = (1...5).map { TaskNode.test(id: "r\($0)", concurrency: .read) }
    XCTAssertEqual(await scheduler.select(from: ready).count, 2)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/SchedulerTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement pure scheduling selection**

```swift
enum ConcurrencyClass: String, Codable, Sendable { case read, mutation }
```

`Scheduler` stores no tool/provider/native executor dependency.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/ConcurrencyClass.swift ZeroLose/ZeroLose/V2/Autonomy/Scheduler.swift ZeroLose/ZeroLoseTests/V2/SchedulerTests.swift
git commit -m "feat: add bounded V2 scheduler"
```

### Task 4: RuntimeBudget and verified TaskRuntime

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/RuntimeBudget.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/TaskVerifier.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/TaskRuntime.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/TaskRuntimeTests.swift`

**Interfaces:** Budget dimensions: wall clock, model calls, tool calls, recovery attempts, external spend, parallel tasks, deadline. Task completion requires `VerificationEvidence`; cancellation propagates to active children.

- [ ] **Step 1: Write failing self-report/cancellation tests**

```swift
func testModelFinalTextDoesNotCompleteTaskWithoutVerifierEvidence() async throws {
    let runtime = makeTaskRuntime(toolResult: .finalText("done"), verifier: .rejecting)
    XCTAssertNotEqual(try await runtime.run(.test()).lifecycle, .succeeded)
}

func testCancellationCancelsActiveChildInvocation() async throws {
    let child = BlockingChildInvocation()
    let runtime = makeTaskRuntime(child: child)
    let task = Task { try await runtime.run(.test()) }
    await runtime.cancel()
    _ = try? await task.value
    XCTAssertTrue(await child.wasCancelled)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/TaskRuntimeTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement budgets/verifier/recovery bound**

```swift
struct RuntimeBudgetSnapshot: Sendable, Equatable {
    let remainingModelCalls: Int
    let remainingToolCalls: Int
    let remainingRecoveryAttempts: Int
    let remainingExternalSpend: Decimal
    let deadline: Date?
}

protocol TaskVerifying: Sendable {
    func verify(task: TaskNode, evidence: [VerificationEvidence]) async -> TaskVerificationResult
}
```

The same failure fingerprint cannot repeat an unchanged strategy beyond configured recovery budget.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/RuntimeBudget.swift ZeroLose/ZeroLose/V2/Autonomy/TaskVerifier.swift ZeroLose/ZeroLose/V2/Autonomy/TaskRuntime.swift ZeroLose/ZeroLoseTests/V2/TaskRuntimeTests.swift
git commit -m "feat: add verified V2 task runtime"
```

### Task 5: AutonomousRuntime restore/reconciliation and GoalVerifier

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/GoalVerifier.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/AutonomousRuntime.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AutonomousRuntimeResumeTests.swift`

**Interfaces:** Restore sequence: checkpoint → event replay → paused/reconciling → registry refresh → discard credential handles → current policy → world re-observation → mutation reconciliation → readiness rebuild. Goal completion is independently verified.

- [ ] **Step 1: Write failing restart/goal tests**

```swift
func testResumeNeverExecutesCheckpointedPhysicalProposal() async throws {
    let executor = RecordingPhysicalExecutor()
    let runtime = makeAutonomousRuntime(checkpoint: .withPendingPhysicalProposal(), executor: executor)
    try await runtime.restore()
    XCTAssertEqual(await executor.executionCount, 0)
    XCTAssertEqual(await runtime.lifecycle, .paused)
}

func testGoalCompletionRequiresGoalVerifier() async throws {
    let runtime = makeAutonomousRuntime(goalVerifier: .rejecting)
    XCTAssertFalse(try await runtime.evaluateGoalCompletion().completed)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/AutonomousRuntimeResumeTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement restore state machine**

Never restore stale approval, credential handle, old PolicyKernel decision, executable invocation, physical permission, or Full Access continuation authority.

- [ ] **Step 4: Verify affected suite and repository gate**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
python3 scripts/verify_all.py
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/GoalVerifier.swift ZeroLose/ZeroLose/V2/Autonomy/AutonomousRuntime.swift ZeroLose/ZeroLoseTests/V2/AutonomousRuntimeResumeTests.swift
git commit -m "feat: add restart-safe autonomous runtime"
```

### Track completion gate

```bash
python3 scripts/verify_all.py
```

Expected: PASS; Planner/Scheduler contain no execution authority and all task/goal success claims require verifier evidence.
