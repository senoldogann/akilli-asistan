# ZeroLose Production Semantic Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fail-closed Agent-mode verifier placeholders with production semantic verification that binds runtime-owned computer freshness, verifies read results deterministically, verifies computer mutations with pre/post observations through ExamPilot `OutcomeVerifier`, and completes goals only from verified task evidence.

**Architecture:** The model supplies action intent and a closed verification expectation, never freshness tokens. A refreshable macOS observation provider owns `stateVersion`/`observationID`; the executor refreshes and captures the exact pre-action window, binds freshness into computer arguments, executes through Tool Fabric/Policy Kernel, refreshes/captures post-action state, and returns a bounded verification artifact. Production task/goal verifiers are deterministic and fail closed; `ZeroLoseRuntimeContainer` remains composition-only.

**Tech Stack:** Swift 5.10+, XCTest, macOS, ScreenCaptureKit, CoreGraphics, existing ZeroLose V2 `ToolFabric`/`PolicyKernel`/`TaskRuntime`/`AgentOrchestrator`, existing ExamPilot `OutcomeVerifier`.

**Spec:** `docs/superpowers/specs/2026-09-12-zerolose-production-semantic-verification-design.md`

## Global Constraints

- Provider final text is never sufficient for task or goal success.
- A `ToolExecutionReceipt` proves execution only; a bare receipt must not produce verified success.
- Computer `stateVersion` and `observationID` are runtime-owned authority data and must never be trusted from model output.
- Observation **refresh** mints a new state token; observation **current** reads the last accepted token without advancing the version.
- Every computer mutation must carry an explicit typed semantic expectation before execution.
- Unknown, missing, stale, ambiguous, unsupported, or inconclusive verification fails closed.
- Reuse ExamPilot `OutcomeVerifier`; do not copy or fork its visual-diff thresholds/algorithms.
- Screenshots/`CGImage` are transient verification inputs only and must not be persisted in `VerificationEvidence`, events, checkpoints, or logs.
- Taint is preserved through task evidence and goal evidence; it is never silently cleared.
- Existing Tool Fabric, Policy Kernel, approval/authority, Emergency Stop, cancellation, replay, and architecture boundaries remain authoritative.
- Behavior changes use TDD: RED -> minimal GREEN -> focused regression -> affected suite.
- Do not push or merge this branch.

---

### Task 1: Make computer observation tokens stable between refresh and execution

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Computer/ToolFabricComputerMutationGateway.swift`
- Modify: `ZeroLose/ZeroLose/V2/Computer/MacOSComputerObservationProvider.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/MacOSComputerObservationProviderTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/ToolFabricComputerMutationGatewayTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/MacOSComputerMutationAdapterTests.swift`

**Interfaces:**
- Consumes: existing `ComputerMutationStateProviding.currentComputerMutationState()` and `MacOSComputerObservationSourceProviding`.
- Produces:
  ```swift
  protocol ComputerMutationStateRefreshing: ComputerMutationStateProviding {
      func refreshComputerMutationState() async throws -> ComputerMutationState
  }
  ```
- `MacOSComputerObservationProvider.currentComputerMutationState()` returns the cached accepted state, refreshing only when no accepted state exists yet.
- `MacOSComputerObservationProvider.refreshComputerMutationState()` performs live fusion, increments `stateVersion`, mints a new `observationID`, and replaces presentation metadata.
- `ToolFabricComputerMutationGateway` requires `any ComputerMutationStateRefreshing` and calls `refreshComputerMutationState()` before each action.
- `MacOSComputerMutationAdapter` continues calling `currentComputerMutationState()` so validating a proposal does not mint a new token.

- [ ] **Step 1: Write RED token-lifecycle tests**

Add tests equivalent to:

```swift
func testCurrentStateDoesNotAdvanceAcceptedObservation() async throws {
    let provider = makeProviderWithStableWindow()

    let first = try await provider.refreshComputerMutationState()
    let current = try await provider.currentComputerMutationState()

    XCTAssertEqual(current, first)
    XCTAssertEqual(await provider.latestPresentationMetadata()?.stateVersion, first.stateVersion)
}

func testExplicitRefreshAdvancesStateVersionAndObservationID() async throws {
    let provider = makeProviderWithStableWindow()

    let first = try await provider.refreshComputerMutationState()
    let second = try await provider.refreshComputerMutationState()

    XCTAssertEqual(second.stateVersion, first.stateVersion + 1)
    XCTAssertNotEqual(second.observationID, first.observationID)
}
```

Update the gateway fake to record refresh calls and assert one refresh per action. Add an adapter regression proving a proposal created from the accepted state still passes the adapter's `current` comparison without self-invalidating.

- [ ] **Step 2: Run RED**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/MacOSComputerObservationProviderTests \
  -only-testing:ZeroLoseTests/ToolFabricComputerMutationGatewayTests \
  -only-testing:ZeroLoseTests/MacOSComputerMutationAdapterTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failure because `ComputerMutationStateRefreshing` and explicit refresh semantics do not exist.

- [ ] **Step 3: Implement refresh/current semantics**

Use one actor-owned accepted state:

```swift
protocol ComputerMutationStateRefreshing: ComputerMutationStateProviding {
    func refreshComputerMutationState() async throws -> ComputerMutationState
}

actor MacOSComputerObservationProvider: ComputerMutationStateRefreshing {
    private var acceptedState: ComputerMutationState?

    func currentComputerMutationState() async throws -> ComputerMutationState {
        if let acceptedState { return acceptedState }
        return try await refreshComputerMutationState()
    }

    func refreshComputerMutationState() async throws -> ComputerMutationState {
        // Existing source fetch + ComputerObservationEngine fusion.
        // Only after successful fusion: increment version, mint observation ID,
        // update acceptedState + presentationMetadata, and return the new state.
    }
}
```

Change the standalone gateway loop from `currentComputerMutationState()` to `refreshComputerMutationState()` so separate actions never reuse an already-mutated visual state.

- [ ] **Step 4: Run GREEN and computer regressions**

Run the Step 2 command plus:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/AgentComputerCompositionTests \
  -only-testing:ZeroLoseTests/ComputerToolProviderTests \
  -only-testing:ZeroLoseTests/ToolFabricComputerMutationGatewayTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Computer/ToolFabricComputerMutationGateway.swift \
        ZeroLose/ZeroLose/V2/Computer/MacOSComputerObservationProvider.swift \
        ZeroLose/ZeroLoseTests/V2/MacOSComputerObservationProviderTests.swift \
        ZeroLose/ZeroLoseTests/V2/ToolFabricComputerMutationGatewayTests.swift \
        ZeroLose/ZeroLoseTests/V2/MacOSComputerMutationAdapterTests.swift
git commit -m "fix: stabilize computer observation tokens"
```

---

### Task 2: Add typed verification expectations and planner-safe computer schemas

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Autonomy/VerificationExpectation.swift`
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/TaskNode.swift`
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/ModelPlanningAdapter.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/ModelPlanningAdapterTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/AgentOrchestratorTests.swift` only where fixtures require the new field.

**Interfaces:**
- Produces:
  ```swift
  enum VerificationExpectation: String, Codable, Sendable, Equatable {
      case readResult
      case computerNone
      case computerAnswerMutation
      case computerViewportChange
      case computerNavigation
  }
  ```
- `PlannedToolInvocation.verificationExpectation` is optional only for backward decoding of old checkpoints/tests; newly decoded model plans must provide a non-nil compatible value.
- `VerificationExpectation.isCompatible(toolID:verificationContract:)` implements this closed table:
  - `read-result` -> `readResult`
  - `computer.wait` -> `computerNone`
  - `computer.scroll` -> `computerViewportChange`
  - `computer.keyboard.type` -> `computerAnswerMutation`
  - `computer.pointer.click` -> `computerAnswerMutation` or `computerNavigation`
  - `computer.keyboard.press` -> `computerAnswerMutation` or `computerNavigation`
  - all unknown contract/tool combinations -> false.
- Planner-visible schemas for `fresh-computer-observation` remove `stateVersion` and `observationID` from both `properties` and `required`.
- Model plans that include either reserved freshness key in `arguments` are rejected before task creation.

- [ ] **Step 1: Write RED structured-plan tests**

Update the valid JSON fixture to include expectations:

```json
{"tasks":[{"id":"inspect","dependencies":[],"toolID":"builtin.system_status","arguments":{},"verificationExpectation":"readResult"}]}
```

Add tests:

```swift
func testMissingVerificationExpectationFailsClosed() async
func testIncompatibleVerificationExpectationFailsClosed() async
func testPlannerSuppliedComputerFreshnessFailsClosed() async
func testComputerPlannerPromptOmitsRuntimeOwnedFreshnessFields() async throws
```

The prompt test uses a `computer.scroll` descriptor whose registered input schema contains `stateVersion` and `observationID`; assert the provider request shown to the model omits both fields from that tool schema while preserving `amount`.

- [ ] **Step 2: Run RED**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ModelPlanningAdapterTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the model-plan schema/expectation type does not exist.

- [ ] **Step 3: Implement expectation domain and validation**

`PlannedToolInvocation` becomes backward-decodable:

```swift
struct PlannedToolInvocation: Codable, Equatable, Sendable {
    let toolID: ToolID
    let argumentsJSON: Data
    let verificationExpectation: VerificationExpectation?

    init(
        toolID: ToolID,
        argumentsJSON: Data,
        verificationExpectation: VerificationExpectation? = nil
    ) {
        self.toolID = toolID
        self.argumentsJSON = argumentsJSON
        self.verificationExpectation = verificationExpectation
    }
}
```

Extend `ModelPlanTask` with required `verificationExpectation: VerificationExpectation`. Before constructing a node:

```swift
guard task.verificationExpectation.isCompatible(
    toolID: toolID,
    verificationContract: descriptor.verificationContract
) else {
    throw PlanningError.invalidProposal
}

guard !containsReservedComputerFreshnessKeys(
    task.arguments,
    descriptor: descriptor
) else {
    throw PlanningError.invalidProposal
}
```

Update the system prompt schema to include `"verificationExpectation":"..."` and include each enabled tool's verification contract plus planner-visible input schema in the user prompt.

- [ ] **Step 4: Run GREEN and planning/orchestrator regressions**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ModelPlanningAdapterTests \
  -only-testing:ZeroLoseTests/AgentOrchestratorTests \
  -only-testing:ZeroLoseTests/AgentRestartIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/VerificationExpectation.swift \
        ZeroLose/ZeroLose/V2/Autonomy/TaskNode.swift \
        ZeroLose/ZeroLose/V2/Autonomy/ModelPlanningAdapter.swift \
        ZeroLose/ZeroLoseTests/V2/ModelPlanningAdapterTests.swift \
        ZeroLose/ZeroLoseTests/V2/AgentOrchestratorTests.swift
git commit -m "feat: add typed agent verification expectations"
```

---

### Task 3: Make TaskRuntime preserve execution artifacts and add deterministic production verifiers

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/TaskRuntime.swift`
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/TaskVerifier.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/ProductionAgentTaskVerifier.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/ProductionAgentGoalVerifier.swift`
- Create: `ZeroLose/ZeroLose/V2/Computer/ComputerVerificationArtifact.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/TaskRuntimeTests.swift`
- Create: `ZeroLose/ZeroLoseTests/V2/ProductionAgentTaskVerifierTests.swift`
- Create: `ZeroLose/ZeroLoseTests/V2/ProductionAgentGoalVerifierTests.swift`
- Modify: test verifier doubles in `AgentOrchestratorTests.swift`, `AgentRestartIntegrationTests.swift`, and `AutonomousRuntimeResumeTests.swift` for the new `TaskVerifying` signature.

**Interfaces:**
- `TaskVerifying` receives the complete execution result:
  ```swift
  protocol TaskVerifying: Sendable {
      func verify(
          task: TaskNode,
          executionResult: TaskExecutionResult
      ) async -> TaskVerificationResult
  }
  ```
- Preserve the existing `.toolReceipt` case specifically as a **bare receipt** path so production verification can reject it.
- Add a rich verified-tool case:
  ```swift
  struct ToolVerificationArtifact: @unchecked Sendable {
      let receipt: ToolExecutionReceipt
      let descriptor: ToolDescriptor
      let expectation: VerificationExpectation
      let computer: ComputerVerificationArtifact?
  }

  enum TaskExecutionResult: @unchecked Sendable {
      case modelFinalText(String)
      case toolReceipt(ToolExecutionReceipt)
      case toolVerification(ToolVerificationArtifact)
      case evidence([VerificationEvidence])
  }
  ```
- Transient computer data:
  ```swift
  struct ComputerVerificationFrame: @unchecked Sendable {
      let state: ComputerMutationState
      let processID: Int32
      let windowID: UInt32
      let provenance: [String]
      let tainted: Bool
      let confidence: Double
      let image: CGImage
  }

  struct ComputerVerificationArtifact: @unchecked Sendable {
      let before: ComputerVerificationFrame
      let after: ComputerVerificationFrame
      let uiStable: Bool
  }
  ```
- `ProductionAgentTaskVerifier` injects `any OutcomeVerifying` (default `OutcomeVerifier()`) and accepts only supported rich artifacts.
- `ProductionAgentGoalVerifier` depends only on `GoalSnapshot` + `TaskGraphSnapshot` and never calls a model.

- [ ] **Step 1: Write RED TaskRuntime artifact-preservation tests**

Add a recording verifier:

```swift
private actor RecordingTaskVerifier: TaskVerifying {
    private(set) var receivedToolID: ToolID?

    func verify(
        task: TaskNode,
        executionResult: TaskExecutionResult
    ) async -> TaskVerificationResult {
        if case .toolReceipt(let receipt) = executionResult {
            receivedToolID = receipt.toolID
        }
        return .rejected(reason: "test")
    }
}
```

Assert `TaskRuntime` passes the original receipt/result to the verifier rather than reducing it to `[]` evidence. Keep the existing receipt-only-does-not-succeed invariant.

- [ ] **Step 2: Write RED production task-verifier tests**

Required deterministic cases:

```swift
func testBareReceiptIsRejected() async
func testValidReadResultProducesBoundedEvidenceWithoutRawText() async
func testUnknownVerificationContractIsRejected() async
func testComputerVerificationRejectsMissingArtifact() async
func testComputerVerificationRejectsNonMonotonicState() async
func testComputerVerificationRejectsChangedWindowIdentity() async
func testComputerVerificationRejectsNoVisibleEffect() async
func testComputerNavigationRejectsUnstableUI() async
func testVerifiedAnswerMutationProducesEvidence() async
func testVerifiedViewportChangeProducesEvidence() async
func testVerifiedNavigationProducesEvidence() async
```

Create tiny synthetic `CGImage` fixtures with `CGContext`: one unchanged image pair and one pair with a deterministic changed rectangle. Tests inspect evidence summary/provenance to ensure raw tool result text is absent.

- [ ] **Step 3: Write RED production goal-verifier tests**

Required cases:

```swift
func testGoalRejectsEmptyGraph() async throws
func testGoalRejectsAnyNonSucceededTask() async throws
func testGoalRejectsSucceededTaskWithoutEvidence() async throws
func testGoalCompletesFromVerifiedTasks() async throws
func testGoalEvidencePreservesTaint() async throws
func testGoalRejectsGraphForDifferentGoal() async throws
```

For the taint test, one task evidence is `tainted: true`; assert returned goal evidence is also tainted.

- [ ] **Step 4: Run RED**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/TaskRuntimeTests \
  -only-testing:ZeroLoseTests/ProductionAgentTaskVerifierTests \
  -only-testing:ZeroLoseTests/ProductionAgentGoalVerifierTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failures for the new verifier contract/artifacts.

- [ ] **Step 5: Implement minimal production verifier rules**

Read-result acceptance requires all of:

```swift
descriptor.verificationContract.kind == "read-result"
expectation == .readResult
receipt.toolID == descriptor.id
receipt.resultProvenance?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
receipt.resultJSON decodes to a top-level [String: Any]
```

Create evidence with bounded/static summary such as `"Verified read result: builtin.system_status"`; do not include payload text. Preserve `receipt.resultTainted`.

Computer acceptance requires descriptor contract `fresh-computer-observation`, matching tool/expectation, monotonic state version, different observation IDs, same process/window identity, and `OutcomeVerifier` success. Map:

```swift
.readResult -> reject for computer contract
.computerNone -> .none
.computerAnswerMutation -> .answerMutation
.computerViewportChange -> .viewportChange
.computerNavigation -> .navigation
```

Map `.pending` and `.failure` to `.rejected`. Evidence taint is the OR of receipt/before/after taint.

Goal acceptance requires same goal ID, non-empty graph, every task `.succeeded`, and at least one evidence item per task. Goal evidence taint is `true` if any contributing evidence is tainted.

- [ ] **Step 6: Run GREEN and autonomy regressions**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/TaskRuntimeTests \
  -only-testing:ZeroLoseTests/ProductionAgentTaskVerifierTests \
  -only-testing:ZeroLoseTests/ProductionAgentGoalVerifierTests \
  -only-testing:ZeroLoseTests/AgentOrchestratorTests \
  -only-testing:ZeroLoseTests/AutonomousRuntimeResumeTests \
  -only-testing:ZeroLoseTests/AgentRestartIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Autonomy/TaskRuntime.swift \
        ZeroLose/ZeroLose/V2/Autonomy/TaskVerifier.swift \
        ZeroLose/ZeroLose/V2/Autonomy/ProductionAgentTaskVerifier.swift \
        ZeroLose/ZeroLose/V2/Autonomy/ProductionAgentGoalVerifier.swift \
        ZeroLose/ZeroLose/V2/Computer/ComputerVerificationArtifact.swift \
        ZeroLose/ZeroLoseTests/V2/TaskRuntimeTests.swift \
        ZeroLose/ZeroLoseTests/V2/ProductionAgentTaskVerifierTests.swift \
        ZeroLose/ZeroLoseTests/V2/ProductionAgentGoalVerifierTests.swift \
        ZeroLose/ZeroLoseTests/V2/AgentOrchestratorTests.swift \
        ZeroLose/ZeroLoseTests/V2/AgentRestartIntegrationTests.swift \
        ZeroLose/ZeroLoseTests/V2/AutonomousRuntimeResumeTests.swift
git commit -m "feat: add production agent verifiers"
```

---

### Task 4: Bind runtime freshness and produce live pre/post computer verification artifacts

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Computer/ComputerInvocationFreshnessBinder.swift`
- Create: `ZeroLose/ZeroLose/V2/Computer/MacOSComputerVerificationCapture.swift`
- Create: `ZeroLose/ZeroLose/V2/Autonomy/AgentToolInvocationExecutor.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift` to remove the private executor implementation after cutover.
- Create: `ZeroLose/ZeroLoseTests/V2/ComputerInvocationFreshnessBinderTests.swift`
- Create: `ZeroLose/ZeroLoseTests/V2/AgentToolInvocationExecutorTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/MacOSComputerObservationProviderTests.swift` only if metadata exposure needs additional regression coverage.

**Interfaces:**
- Freshness binder:
  ```swift
  enum ComputerInvocationFreshnessBinderError: Error, Equatable {
      case invalidArguments
      case reservedFreshnessField
  }

  struct ComputerInvocationFreshnessBinder: Sendable {
      func bind(
          argumentsJSON: Data,
          state: ComputerMutationState
      ) throws -> Data
  }
  ```
  It requires a top-level JSON object, rejects existing `stateVersion`/`observationID`, injects the runtime values, and serializes with sorted keys.
- Capture boundary:
  ```swift
  protocol ComputerVerificationCapturing: Sendable {
      func capture(
          metadata: MacOSComputerObservationPresentationMetadata
      ) async throws -> ComputerVerificationFrame
  }
  ```
- `ScreenCaptureKitComputerVerificationCapturer` finds the exact `SCWindow.windowID == metadata.windowID`, captures only that window, and returns a transient frame. A missing window fails closed.
- `AgentToolInvocationExecutor` moves out of `ZeroLoseRuntimeContainer.swift` and accepts:
  - `ToolRegistry`
  - `ToolFabric`
  - `AgentMutationExecutionState`
  - optional `any ComputerMutationStateRefreshing`
  - optional `any ComputerVerificationCapturing`
  - `ComputerInvocationFreshnessBinder`
  - `shouldStop: @Sendable () -> Bool`
  - injectable bounded settle closure for deterministic tests.

- [ ] **Step 1: Write RED freshness-binder tests**

```swift
func testBinderInjectsRuntimeFreshness() throws
func testBinderRejectsPlannerSuppliedStateVersion() throws
func testBinderRejectsPlannerSuppliedObservationID() throws
func testBinderRejectsNonObjectArguments() throws
```

Assert the output keeps original action keys and contains exactly the supplied runtime state token.

- [ ] **Step 2: Write RED executor tests with fakes**

Required cases:

```swift
func testReadToolReturnsRichVerificationArtifact() async throws
func testComputerToolRefreshesBeforeExecutionAndAfterExecution() async throws
func testComputerToolBindsExactPreActionStateIntoToolFabricInvocation() async throws
func testComputerToolCapturesExactPreAndPostMetadata() async throws
func testComputerToolFailsClosedWhenObservationOrCaptureUnavailable() async
func testComputerToolDoesNotPromotePostStopReceiptToVerificationArtifact() async
func testUnknownVerificationContractFailsBeforeExecution() async
```

The fake state provider records `refresh`/`current` calls. The fake Tool Fabric decodes its received JSON and asserts the pre-action state token, proving the model did not author it.

- [ ] **Step 3: Run RED**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ComputerInvocationFreshnessBinderTests \
  -only-testing:ZeroLoseTests/AgentToolInvocationExecutorTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because binder/capture/executor production types do not exist.

- [ ] **Step 4: Implement binder and ScreenCaptureKit exact-window capture**

Capture logic must select by authoritative window ID rather than application name:

```swift
let content = try await SCShareableContent.excludingDesktopWindows(
    false,
    onScreenWindowsOnly: true
)
guard let window = content.windows.first(where: { $0.windowID == metadata.windowID }) else {
    throw MacOSComputerVerificationCaptureError.windowUnavailable
}
let filter = SCContentFilter(desktopIndependentWindow: window)
let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: configuration
)
```

Do not JPEG-encode or persist the image.

- [ ] **Step 5: Implement production executor flow**

For `read-result`, execute unchanged arguments through Tool Fabric and return `.toolVerification(...)` with no computer artifact.

For `fresh-computer-observation`:

```swift
let preState = try await stateProvider.refreshComputerMutationState()
let preMetadata = try requireMetadata(matching: preState)
let before = try await capturer.capture(metadata: preMetadata)
let boundArguments = try binder.bind(argumentsJSON: planned.argumentsJSON, state: preState)
let receipt = try await toolFabric.execute(makeInvocation(argumentsJSON: boundArguments))
if Task.isCancelled || shouldStop() { throw CancellationError() }
try await settle()
let postState = try await stateProvider.refreshComputerMutationState()
let postMetadata = try requireMetadata(matching: postState)
let after = try await capturer.capture(metadata: postMetadata)
if Task.isCancelled || shouldStop() { throw CancellationError() }
return .toolVerification(
    ToolVerificationArtifact(
        receipt: receipt,
        descriptor: descriptor,
        expectation: expectation,
        computer: ComputerVerificationArtifact(before: before, after: after, uiStable: true)
    )
)
```

The executor rejects a missing expectation, unknown verification contract, unavailable state/capture provider, or stop/cancel signal. Mutation-active tracking remains scoped around the actual mutation execution path.

- [ ] **Step 6: Run GREEN and Tool Fabric/computer regressions**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ComputerInvocationFreshnessBinderTests \
  -only-testing:ZeroLoseTests/AgentToolInvocationExecutorTests \
  -only-testing:ZeroLoseTests/AgentComputerCompositionTests \
  -only-testing:ZeroLoseTests/MacOSComputerMutationAdapterTests \
  -only-testing:ZeroLoseTests/ToolFabricComputerMutationGatewayTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Computer/ComputerInvocationFreshnessBinder.swift \
        ZeroLose/ZeroLose/V2/Computer/MacOSComputerVerificationCapture.swift \
        ZeroLose/ZeroLose/V2/Autonomy/AgentToolInvocationExecutor.swift \
        ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift \
        ZeroLose/ZeroLoseTests/V2/ComputerInvocationFreshnessBinderTests.swift \
        ZeroLose/ZeroLoseTests/V2/AgentToolInvocationExecutorTests.swift \
        ZeroLose/ZeroLoseTests/V2/MacOSComputerObservationProviderTests.swift
git commit -m "feat: produce semantic computer verification artifacts"
```

---

### Task 5: Cut production Agent mode over to semantic task/goal verification

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/AgentComputerCompositionTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/AgentApplicationCommandTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/ArchitectureBoundaryTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/RuntimeDashboardStateTests.swift` only if lifecycle assertions need the now-reachable `.completed` state.

**Interfaces:**
- `AgentComputerToolComposition` exposes the concrete `MacOSComputerObservationProvider?` used by both the mutation adapter and the Agent executor so both paths share one state-token authority.
- Production composition uses exactly one `ProductionAgentTaskVerifier` and one `ProductionAgentGoalVerifier`.
- `FailClosedAgentTaskVerifier` and `FailClosedAgentGoalVerifier` are deleted.
- `AgentToolInvocationExecutor` receives the same observation provider instance used by `MacOSComputerMutationAdapter`, plus `ScreenCaptureKitComputerVerificationCapturer`.
- When computer permissions/readiness are absent, computer descriptors remain unavailable; read-only Agent tasks can still verify.

- [ ] **Step 1: Write RED production-composition tests**

Add assertions equivalent to:

```swift
func testProductionCompositionUsesSharedObservationAuthority() async throws
func testReadOnlyAgentTaskCanReachCompletedWithProductionVerifiers() async throws
func testBareReceiptCannotReachCompleted() async throws
func testEmergencyStopStillCancelsMutationBeforeVerificationSuccess() async throws
func testProductionSourceContainsNoFailClosedAgentVerifierPlaceholder() throws
```

The read-only completion test uses a deterministic fake planning/provider path that returns a `builtin.system_status` task with `readResult`; assert the session reaches `.completed` and has a verification evidence ID.

- [ ] **Step 2: Run RED**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/AgentComputerCompositionTests \
  -only-testing:ZeroLoseTests/AgentApplicationCommandTests \
  -only-testing:ZeroLoseTests/ArchitectureBoundaryTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL while production container still wires placeholder verifiers / does not expose shared observation authority.

- [ ] **Step 3: Wire production verifiers and shared observation authority**

Change composition so one observation provider instance is created and returned:

```swift
struct AgentComputerToolComposition {
    let providers: [any ToolProviding]
    let descriptors: [ToolDescriptor]
    let observationProvider: MacOSComputerObservationProvider?
}
```

Container wiring becomes conceptually:

```swift
let taskExecutor = AgentToolInvocationExecutor(
    registry: registry,
    toolFabric: toolFabric,
    mutationExecutionState: mutationExecutionState,
    computerStateProvider: toolComposition.observationProvider,
    computerCapturer: toolComposition.observationProvider == nil
        ? nil
        : ScreenCaptureKitComputerVerificationCapturer(),
    shouldStop: { emergencyStopState.isStopped }
)
let taskRuntime = TaskRuntime(
    executor: taskExecutor,
    verifier: ProductionAgentTaskVerifier(),
    budget: agentBudget
)
let orchestrator = AgentOrchestrator(
    ...,
    goalVerifier: ProductionAgentGoalVerifier(),
    ...
)
```

Delete the private placeholder verifier structs and the old private executor from the container.

- [ ] **Step 4: Run focused Agent regression matrix**

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ArchitectureBoundaryTests \
  -only-testing:ZeroLoseTests/AgentApplicationCommandTests \
  -only-testing:ZeroLoseTests/AgentComputerCompositionTests \
  -only-testing:ZeroLoseTests/AgentToolInvocationExecutorTests \
  -only-testing:ZeroLoseTests/ProductionAgentTaskVerifierTests \
  -only-testing:ZeroLoseTests/ProductionAgentGoalVerifierTests \
  -only-testing:ZeroLoseTests/ModelPlanningAdapterTests \
  -only-testing:ZeroLoseTests/AgentOrchestratorTests \
  -only-testing:ZeroLoseTests/TaskRuntimeTests \
  -only-testing:ZeroLoseTests/AutonomousRuntimeResumeTests \
  -only-testing:ZeroLoseTests/AgentRestartIntegrationTests \
  -only-testing:ZeroLoseTests/RuntimeDashboardStateTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Run boundary/privacy source scans**

Run:

```bash
rg -n 'FailClosedAgent(Task|Goal)Verifier|shouldStop:\s*\{\s*false\s*\}' ZeroLose/ZeroLose
rg -n 'CGImage|jpegData|screenshot' ZeroLose/ZeroLose/V2/Autonomy/ProductionAgentTaskVerifier.swift ZeroLose/ZeroLose/V2/Autonomy/ProductionAgentGoalVerifier.swift
```

Expected: first command returns no matches for placeholders/disabled stop wiring. The second may mention transient image input types but must show no persistence/event/checkpoint serialization code.

- [ ] **Step 6: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift \
        ZeroLose/ZeroLoseTests/V2/AgentComputerCompositionTests.swift \
        ZeroLose/ZeroLoseTests/V2/AgentApplicationCommandTests.swift \
        ZeroLose/ZeroLoseTests/V2/ArchitectureBoundaryTests.swift \
        ZeroLose/ZeroLoseTests/V2/RuntimeDashboardStateTests.swift
git commit -m "feat: enable production semantic agent verification"
```

---

### Task 6: Final review and repository-wide verification

**Files:**
- No planned production changes. If verification exposes a defect, fix only the directly affected files with a RED regression test and create one narrowly-scoped corrective commit before rerunning this task from the start.

**Interfaces:**
- Produces fresh completion evidence for the committed branch HEAD.

- [ ] **Step 1: Inspect branch scope**

Run:

```bash
git status --short
git diff --check
git log --oneline --decorate -15
```

Expected: clean worktree, no whitespace errors, semantic-verification commits only on top of the existing branch work.

- [ ] **Step 2: Run the full focused ZeroLose Agent matrix from Task 5 again on committed HEAD**

Expected: PASS with no uncommitted changes.

- [ ] **Step 3: Run ExamPilot regressions because ZeroLose reuses `OutcomeVerifier`**

Run:

```bash
cd ExamPilot && swift test
```

Expected: all ExamPilot tests PASS without modifying ExamPilot production behavior.

- [ ] **Step 4: Run repository-wide verification**

Run from repository root:

```bash
python3 scripts/verify_all.py
```

Expected: exit 0 and `[OK] repository verification completed successfully`.

- [ ] **Step 5: Invoke verification-before-completion and inspect final state**

Run:

```bash
git status
git log -8 --oneline --decorate
```

Expected: clean worktree; branch remains local/ahead of `origin/main`; no push/merge performed.
