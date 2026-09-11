# ZeroLose Agent Runtime Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Agent mode create and run a real persistent V2 autonomous task whose computer/browser/file mutations can occur only through Tool Fabric, Policy Kernel, fresh observation, reconciliation, and verifier evidence.

**Architecture:** `AgentOrchestrator` coordinates provider-neutral planning, TaskGraph scheduling, TaskRuntime execution, checkpoint/event persistence, and GoalVerifier. Existing ExamPilot `ComputerAgentCore`/`ComputerAgentMacOS`/`ExamPilotCore` are linked as local SwiftPM products for observation/input primitives, but ZeroLose exposes those primitives through one `MacOSComputerMutationAdapter`; every physical action still enters through `ComputerToolProvider -> ComputerMutationGating -> adapter` after ToolFabric/PolicyKernel approval.

**Tech Stack:** Swift 5 actors, ZeroLose V2 autonomy/tool/policy/persistence, local Swift package `../ExamPilot`, `ComputerAgentCore`, `ComputerAgentMacOS`, `ExamPilotCore`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-11-zerolose-general-autonomous-agent-redesign.md`

## Global Constraints

- Ask mode cannot perform physical mutation.
- Agent mode uses one authoritative execution path.
- Provider CLIs remain reasoning-only; they never own host mutation authority.
- Physical mutations are never blindly replayed after restart.
- Goal completion requires `GoalVerifier` evidence.
- Emergency Stop prevents new mutation scheduling and cancels active invocation/input.
- `InputDriving`/`NativeInputDriver` may appear in exactly one ZeroLose production adapter: `V2/Computer/MacOSComputerMutationAdapter.swift`.
- No direct mouse/keyboard/shell/browser primitive may appear in SwiftUI, AgentOrchestrator, Planner, or provider code.
- Preserve `.freebuff/`; do not touch unrelated ExamPilot worktree changes.

---

### Task 1: Link the existing ComputerAgent packages into ZeroLose

**Files:**
- Modify: `ZeroLose/ZeroLose.xcodeproj/project.pbxproj`
- Create: `ZeroLose/ZeroLose/V2/Computer/ComputerAgentPackageProbe.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ComputerAgentPackageIntegrationTests.swift`

**Interfaces:**
- Consumes: local package at repository path `ExamPilot/Package.swift` exporting `ComputerAgentCore`, `ComputerAgentMacOS`, `ExamPilotCore`.
- Produces: ZeroLose target can import those three products.

- [ ] **Step 1: Write the failing import/probe test**

`ComputerAgentPackageProbe.swift` is intentionally absent for RED. The test requires a production probe that returns stable type names without executing input:

```swift
func testZeroLoseLinksExistingComputerAgentPackages() {
    XCTAssertEqual(
        ComputerAgentPackageProbe.linkedProducts,
        ["ComputerAgentCore", "ComputerAgentMacOS", "ExamPilotCore"]
    )
}
```

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ComputerAgentPackageIntegrationTests
```
Expected: missing `ComputerAgentPackageProbe` and/or unavailable package imports.

- [ ] **Step 3: Add the local Swift package dependency**

Add one `XCLocalSwiftPackageReference` pointing to `../ExamPilot` and add `XCSwiftPackageProductDependency` entries for `ComputerAgentCore`, `ComputerAgentMacOS`, and `ExamPilotCore` to the ZeroLose target's `packageProductDependencies` and Frameworks build phase. Do not modify `ExamPilot/Package.swift`.

Create:

```swift
import ComputerAgentCore
import ComputerAgentMacOS
import ExamPilotCore

enum ComputerAgentPackageProbe {
    static let linkedProducts = ["ComputerAgentCore", "ComputerAgentMacOS", "ExamPilotCore"]
}
```

- [ ] **Step 4: Verify package resolution and GREEN**

```bash
xcodebuild -resolvePackageDependencies -project ZeroLose/ZeroLose.xcodeproj
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ComputerAgentPackageIntegrationTests
```
Expected: local package resolves without remote dependency changes and test PASS.

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose.xcodeproj/project.pbxproj ZeroLose/ZeroLose/V2/Computer/ComputerAgentPackageProbe.swift ZeroLose/ZeroLoseTests/V2/ComputerAgentPackageIntegrationTests.swift
git commit -m "build: link ComputerAgent runtime into ZeroLose"
```

### Task 2: Agent session lifecycle domain

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/AgentSession.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/AgentLifecycle.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AgentLifecycleTests.swift`

**Interfaces:**
- Produces: `AgentSessionID`, `AgentLifecycle`, `AgentSessionSnapshot`, `AgentLifecycleError`.

- [ ] **Step 1: Write RED transition tests**

```swift
func makeSession(_ lifecycle: AgentLifecycle) -> AgentSessionSnapshot {
    AgentSessionSnapshot(
        id: AgentSessionID(rawValue: "a1"),
        goalID: GoalID(rawValue: "g1"),
        lifecycle: lifecycle,
        verificationEvidenceID: nil
    )
}

func testCompletionRequiresVerificationEvidence() throws {
    var state = makeSession(.verifying)
    XCTAssertThrowsError(try state.transition(to: .completed, verificationEvidenceID: nil))
    try state.transition(to: .completed, verificationEvidenceID: "evidence-1")
    XCTAssertEqual(state.lifecycle, .completed)
    XCTAssertEqual(state.verificationEvidenceID, "evidence-1")
}

func testCancelledAndManualResolutionAreTerminal() throws {
    var cancelled = makeSession(.executing)
    try cancelled.transition(to: .cancelled, verificationEvidenceID: nil)
    XCTAssertThrowsError(try cancelled.transition(to: .planning, verificationEvidenceID: nil))

    var manual = makeSession(.observing)
    try manual.transition(to: .manualResolutionRequired, verificationEvidenceID: nil)
    XCTAssertThrowsError(try manual.transition(to: .executing, verificationEvidenceID: nil))
}
```

Add table-driven tests for allowed path `created -> planning -> ready -> executing -> observing -> verifying`, verifier rejection back to planning/replan, and blocked/failed terminal paths.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AgentLifecycleTests
```

- [ ] **Step 3: Implement explicit state machine**

```swift
struct AgentSessionID: Hashable, Codable, Sendable { let rawValue: String }

enum AgentLifecycle: String, Codable, Sendable {
    case created, planning, ready, executing, observing, verifying
    case completed, cancelled, blocked, failed, manualResolutionRequired
}

enum AgentLifecycleError: Error, Equatable {
    case invalidTransition(from: AgentLifecycle, to: AgentLifecycle)
    case completionRequiresEvidence
}

struct AgentSessionSnapshot: Sendable, Equatable {
    let id: AgentSessionID
    let goalID: GoalID
    private(set) var lifecycle: AgentLifecycle
    private(set) var verificationEvidenceID: String?

    mutating func transition(
        to next: AgentLifecycle,
        verificationEvidenceID: String?
    ) throws {
        let allowed: Set<AgentLifecycle>
        switch lifecycle {
        case .created: allowed = [.planning, .cancelled, .failed]
        case .planning: allowed = [.ready, .blocked, .failed, .cancelled]
        case .ready: allowed = [.executing, .blocked, .cancelled]
        case .executing: allowed = [.observing, .blocked, .failed, .cancelled, .manualResolutionRequired]
        case .observing: allowed = [.verifying, .planning, .blocked, .failed, .cancelled, .manualResolutionRequired]
        case .verifying: allowed = [.completed, .planning, .blocked, .failed, .cancelled]
        case .completed, .cancelled, .blocked, .failed, .manualResolutionRequired:
            allowed = []
        }
        guard allowed.contains(next) else {
            throw AgentLifecycleError.invalidTransition(from: lifecycle, to: next)
        }
        if next == .completed && verificationEvidenceID == nil {
            throw AgentLifecycleError.completionRequiresEvidence
        }
        lifecycle = next
        if next == .completed { self.verificationEvidenceID = verificationEvidenceID }
    }
}
```

`AgentSessionSnapshot.transition` owns the transition table. No UI or orchestrator may assign lifecycle directly.

- [ ] **Step 4: Run GREEN**
- [ ] **Step 5: Commit `feat: add autonomous agent lifecycle`**

### Task 3: Provider-neutral planning adapter

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/ModelPlanningAdapter.swift`
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/Planner.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ModelPlanningAdapterTests.swift`

**Interfaces:**
- Consumes: `ModelProviderFabric` and a new explicit `PlanningContext` carrying `ContextBundle` plus current `ToolRegistrySnapshot`.
- Produces: existing `PlanningProposal` values only after schema validation. Existing `Planning` conformers/tests are migrated in this task; no hidden global context/registry lookup is permitted.

- [ ] **Step 1: Write RED tests for structured-plan validation**

Use `RecordingModelProvider` from the provider plan. Feed a valid JSON plan fixture and assert task ID/dependencies/tool ID are preserved. Feed unknown tool ID, cyclic dependency, missing task ID, or free-form text and assert `PlanningError.invalidProposal` without invoking any tool.

Define the planning context explicitly:

```swift
struct PlanningContext: Sendable, Equatable {
    let retrievedContext: ContextBundle
    let registry: ToolRegistrySnapshot
}

protocol Planning: Sendable {
    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) async throws -> PlanningProposal
}
```

For the unknown-tool test, construct `GoalSnapshot(id: GoalID(rawValue: "g1"), objective: "check status")`, `TaskGraphSnapshot(goalID: GoalID(rawValue: "g1"), revision: 0, tasks: [:])`, a finite `RuntimeBudgetSnapshot`, `ContextBundle(items: [], excluded: [], usedCharacters: 0)`, and a `ToolRegistrySnapshot` whose only enabled descriptor is `builtin.system_status`. Use ordinary `do/catch` plus `XCTFail("expected invalid proposal")`; no custom async assertion helper is required.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ModelPlanningAdapterTests
```

- [ ] **Step 3: Implement canonical JSON planning schema and adapter**

Modify `Planner.swift` to add `PlanningContext` and the fourth `context:` parameter to `Planning.propose`. Update every existing test fake/conformer in the same commit. The adapter requests `.json` response mode and parses only:

```swift
private struct ModelPlan: Decodable {
    let tasks: [ModelPlanTask]
}
private struct ModelPlanTask: Decodable {
    let id: String
    let dependencies: [String]
    let toolID: String
    let arguments: JSONValue
}
```

Map only tool IDs present and enabled in the supplied registry snapshot. Reuse existing `PlanningProposal` validation for graph limits/dependency correctness; do not add any direct execution method.

- [ ] **Step 4: Run GREEN plus planner contracts**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ModelPlanningAdapterTests -only-testing:ZeroLoseTests/PlannerContractTests
```

- [ ] **Step 5: Commit `feat: adapt model providers to V2 planning proposals`**

### Task 4: AgentOrchestrator execution loop

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/AgentOrchestrator.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AgentOrchestratorTests.swift`

**Interfaces:**
- Consumes: `TaskGraph`, `Scheduler`, planning adapter through existing Planner boundary, `TaskRuntime`, `CheckpointStoring`, `EventStoring`, `GoalVerifying`, `RuntimeBudget`.
- Produces: `start(goal:)`, `pause()`, `resume()`, `cancel()`, `emergencyStop()`, `snapshot()`.

- [ ] **Step 1: Write RED happy-path test with one read-only task**

Fake planner returns one `builtin.system_status` task; fake `TaskInvocationExecuting` returns executed receipt; fake task verifier produces verification evidence; fake GoalVerifier completes. Assert event/lifecycle ordering `planning -> ready -> executing -> observing -> verifying -> completed` and one checkpoint after stable state changes.

- [ ] **Step 2: Write RED failure/cancellation tests**

Assert: policy denial maps to `.blocked`; task verification rejection returns to planning within `RuntimeBudget`; exhausted recovery budget ends `.failed`; `cancel()` invokes `TaskRuntime.cancel()` and ends `.cancelled`; `emergencyStop()` also prevents scheduler from starting any later ready node.

- [ ] **Step 3: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AgentOrchestratorTests
```

- [ ] **Step 4: Implement actor loop**

`AgentOrchestrator` may call Planner/Scheduler/TaskRuntime/EventStore/CheckpointStore/GoalVerifier only. It must not import CoreGraphics, AppKit input APIs, `ExamPilotCore`, or any `InputDriving` type. Persist lifecycle events using existing `RuntimeEvent`/checkpoint contracts. Pause stops scheduling new nodes after the current safe boundary; cancel/emergency stop propagates cancellation to TaskRuntime.

- [ ] **Step 5: Run focused autonomy regression**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AgentOrchestratorTests -only-testing:ZeroLoseTests/TaskRuntimeTests -only-testing:ZeroLoseTests/SchedulerTests -only-testing:ZeroLoseTests/TaskGraphTests
```

- [ ] **Step 6: Commit `feat: coordinate persistent autonomous agent tasks`**

### Task 5: Complete the physical action vocabulary through one adapter

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Computer/ComputerActionToolMapper.swift`
- Create: `ZeroLose/ZeroLose/V2/Computer/MacOSComputerMutationAdapter.swift`
- Modify: `ZeroLose/ZeroLose/V2/Tools/Providers/ComputerToolProvider.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MacOSComputerMutationAdapterTests.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AgentComputerMutationBoundaryTests.swift`

**Interfaces:**
- Consumes: `ComputerMutationGating`, `InputDriving`, current `ComputerMutationState`.
- Produces: physical actions `click`, `type`, `pressKey`, `scroll`, `wait`, each requiring matching `observationID` and `stateVersion` where mutation-sensitive.

- [ ] **Step 1: Write RED mapper tests for full bounded vocabulary**

Add mapper cases:

```swift
enum ToolFabricComputerAction: Sendable, Equatable {
    case click(x: Double, y: Double)
    case type(String)
    case pressKey(String)
    case scroll(amount: Int)
    case wait(milliseconds: Int)
}
```

Tests reject non-finite coordinates, scroll outside the existing safe bound, wait above 5 seconds, empty observation ID, and unsupported key names before physical execution.

- [ ] **Step 2: Write RED stale-state and input-recording tests**

Create a `RecordingInputDriver: InputDriving` in tests. `MacOSComputerMutationAdapter` receives a `ComputerMutationStateProviding`; it must compare proposal state/observation with the latest state immediately before input. Stale state throws without recording input. Current state maps action to exactly one driver call.

- [ ] **Step 3: Write RED architecture guard**

Scan `ZeroLose/ZeroLose` and assert `InputDriving`, `NativeInputDriver`, and `import ExamPilotCore` occur only in `V2/Computer/MacOSComputerMutationAdapter.swift` (test files excluded). Assert `AgentOrchestrator.swift`, provider files, and SwiftUI files contain none of them.

- [ ] **Step 4: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/MacOSComputerMutationAdapterTests -only-testing:ZeroLoseTests/AgentComputerMutationBoundaryTests
```

- [ ] **Step 5: Implement adapter and mapper**

`MacOSComputerMutationAdapter` is `ComputerMutationGating`. It owns an `InputDriving` dependency and a state provider, validates proposal freshness, decodes bounded action-specific arguments, performs the single matching driver call, and returns a receipt. It never makes policy decisions; ToolFabric/PolicyKernel already did that before `ComputerToolProvider` reached this adapter. Production construction uses `NativeInputDriver` with Emergency Stop closure.

- [ ] **Step 6: Run computer regressions**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/MacOSComputerMutationAdapterTests -only-testing:ZeroLoseTests/AgentComputerMutationBoundaryTests -only-testing:ZeroLoseTests/ToolFabricComputerMutationGatewayTests -only-testing:ZeroLoseTests/ComputerToolProviderTests
cd ExamPilot && swift test
```
Expected: PASS.

- [ ] **Step 7: Commit `feat: add policy-gated macOS computer mutation adapter`**

### Task 6: Fresh observation state provider

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Computer/MacOSComputerObservationProvider.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MacOSComputerObservationProviderTests.swift`

**Interfaces:**
- Consumes: `ComputerAgentMacOS.ComputerObservationEngine`, screen/accessibility source snapshots supplied by existing macOS observation services.
- Produces: `ComputerMutationStateProviding.currentComputerMutationState()` and presentation-safe observation metadata.

- [ ] **Step 1: Write RED identity tests**

Fixtures with matching process/window IDs return incremented stateVersion + observation ID. Missing/mismatched process/window IDs return reobserve/fail-closed and never fabricate state. A stale prior observation cannot be returned after a new accepted observation.

- [ ] **Step 2: Run RED**
- [ ] **Step 3: Implement actor provider using `ComputerObservationEngine` fusion semantics**

Keep screenshot bytes/AX raw values out of `ComputerMutationState`; only identity/version IDs flow into ToolFabric action arguments. Any missing permission or identity mismatch returns an explicit unavailable/reobserve error.

- [ ] **Step 4: Run GREEN plus existing ComputerAgentMacOS tests**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/MacOSComputerObservationProviderTests
cd ExamPilot && swift test --filter ComputerAgentMacOSTests
```

- [ ] **Step 5: Commit `feat: add fresh macOS computer observation provider`**

### Task 7: Compose computer tools through ToolFabric and PolicyKernel

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AgentComputerCompositionTests.swift`

**Interfaces:**
- Consumes: `MacOSComputerMutationAdapter`, `MacOSComputerObservationProvider`, `ComputerToolProvider`, `ToolFabric`.
- Produces: registered `computer.pointer.click`, `computer.keyboard.type`, `computer.keyboard.press`, `computer.scroll`, `computer.wait` descriptors when required macOS permissions are available; otherwise explicit unavailable capability.

- [ ] **Step 1: Write RED composition test**

Use recording PolicyKernel/provider fakes and prove a computer request follows registry resolution -> policy -> ComputerToolProvider -> mutation adapter. Policy denial/approval-required states must produce zero input calls. Disabled descriptor must fail before adapter invocation.

- [ ] **Step 2: Run RED**
- [ ] **Step 3: Wire concrete computer provider into production container**

Use the existing `ToolRegistry.register(_:)` API unchanged. Registration depends on permission/observation readiness; do not register a functional mutation provider when Accessibility/screen observation prerequisites are absent. Preserve read-only tools independently.

- [ ] **Step 4: Run ToolFabric + computer suite**
- [ ] **Step 5: Commit `feat: compose computer tools through V2 policy fabric`**

### Task 8: Restart/replay/reconciliation integration

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/AgentOrchestrator.swift`
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/AutonomousRuntime.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AgentRestartIntegrationTests.swift`

**Interfaces:**
- Consumes: existing `ReplayRuntime`, checkpoint store, mutation reconciler, registry/credential/policy/world refresh boundaries.
- Produces: `restore(sessionID:)` that ends paused until reconciliation passes.

- [ ] **Step 1: Write RED restart test with checkpointed physical proposal**

The checkpoint/event fixture contains a click-like prior proposal. Restore must load checkpoint, replay subsequent events read-only, refresh registry, discard credential handles, reload current policy, re-observe world, reconcile outstanding mutations, rebuild readiness, and remain paused. Recording input driver invocation count must stay zero throughout restore.

- [ ] **Step 2: Write RED failed-reconciliation test**

Unknown high-risk mutation state ends `manualResolutionRequired`; resume is rejected until externally resolved.

- [ ] **Step 3: Run RED**
- [ ] **Step 4: Integrate existing `AutonomousRuntime.restore()` stages into AgentOrchestrator session restore**
- [ ] **Step 5: Run GREEN plus `AutonomousRuntimeResumeTests`, `ReplayRuntimeTests`, `MutationReconcilerTests`**
- [ ] **Step 6: Commit `feat: restore autonomous sessions through reconciliation`**

### Task 9: Application commands for real Agent mode and Emergency Stop

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/ApplicationCommand.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/ApplicationFacade.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/TaskRuntimeViewModel.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/AgentApplicationCommandTests.swift`

**Interfaces:**
- Consumes: `AgentOrchestrator`.
- Produces: submit goal, pause, resume, cancel, emergency stop mapped to real runtime methods.

- [ ] **Step 1: Write RED command-routing tests**

`submitUserGoal` must call `AgentOrchestrator.start`, not chat. Pause/resume/cancel require a real active session ID. `emergencyStop` invokes orchestrator stop and the shared NativeInputDriver stop flag.

- [ ] **Step 2: Write RED UI-state test**

`TaskRuntimeViewModel` enables Pause/Cancel only for an active nonterminal session; Resume only while paused; Emergency Stop only while mutation-capable execution is active. No placeholder command is shown as enabled.

- [ ] **Step 3: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AgentApplicationCommandTests
```

- [ ] **Step 4: Replace current goal placeholder with orchestrator wiring**

Add `.emergencyStop` to the typed command surface. Remove any `Autonomous runtime not configured` placeholder path once the real orchestrator is composed. Keep unsupported provider/model structured-planning capability fail-closed with an explicit blocked reason.

- [ ] **Step 5: Run focused autonomy/application suites**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AgentApplicationCommandTests -only-testing:ZeroLoseTests/AgentOrchestratorTests -only-testing:ZeroLoseTests/TaskRuntimeTests -only-testing:ZeroLoseTests/AutonomousRuntimeResumeTests
```

- [ ] **Step 6: Commit `feat: expose authoritative Agent mode commands`**
