# ZeroLose V2 ComputerAgentCore Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a reusable generic ComputerAgentCore from the proven ExamPilot runtime while preserving ExamPilot behavior and forcing ZeroLose physical actions through Tool Fabric.

**Architecture:** Add generic targets incrementally inside the existing `ExamPilot` Swift package, keep `ExamPilotCore` as the exam profile/compatibility layer, and make ZeroLose depend only on generic core/macOS boundaries. Existing behavior is characterized before moving types. No package-wide rename or clean-room rewrite.

**Tech Stack:** Swift Package Manager, Swift, ScreenCaptureKit, Accessibility, CoreGraphics, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Preserve existing ExamPilot correctness before moving code.
- Keep the 118-test baseline behavior protected.
- ZeroLose production must not depend on `ExamPilotCore` domain logic.
- `questionGeneration`, `answerVerified`, and `ExamUIPhase` are exam-profile concepts, not generic core state.
- Providers propose; they never execute.
- Every ZeroLose physical action re-enters Tool Fabric and current `PolicyKernel`.
- Focus/state/observation are revalidated immediately before input.
- Policy denial cannot be bypassed by provider fallback.
- TDD required for behavior changes; final gate `python3 scripts/verify_all.py`.

---

### Task 1: Characterize current ExamPilot invariants before extraction

**Files:**
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExtractionCharacterizationTests.swift`
- Read-only references: `ComputerAgentSession.swift`, `ComputerAgentProvider.swift`, `ActionBatchPolicy.swift`, `OutcomeVerification.swift`, `RecoveryEngine.swift`.

**Interfaces:** Locks state-version advancement, exam answer/navigation safety, provider continuation, recovery budget, and cancellation.

- [ ] **Step 1: Add characterization tests**

```swift
func testSessionAdvancesStateVersionAfterObservation() {
    let session = ComputerAgentSession(goal: "Run", initialRuntimeState: ExamRuntimeState())
    let old = session.runtimeState.stateVersion
    session.acceptObservation()
    XCTAssertGreaterThan(session.runtimeState.stateVersion, old)
}

func testExamNavigationStillRequiresVerifiedAnswer() {
    var state = ExamRuntimeState()
    XCTAssertFalse(state.navigationAllowed)
    state.recordAnswerVerified()
    XCTAssertTrue(state.navigationAllowed)
}
```

- [ ] **Step 2: Confirm current GREEN**

```bash
cd ExamPilot
swift test --filter ExtractionCharacterizationTests
```

Expected: PASS; this task establishes a refactor safety net rather than changing behavior.

- [ ] **Step 3: Add deterministic continuation/recovery characterization**

Cover current previous-response/pending-computer-call state, repeated-intent budget, outcome verification, and stop propagation without production edits.

- [ ] **Step 4: Run complete ExamPilot suite**

```bash
cd ExamPilot
swift test
```

- [ ] **Step 5: Commit**

```bash
git add ExamPilot/Tests/ExamPilotCoreTests/ExtractionCharacterizationTests.swift
git commit -m "test: characterize ExamPilot extraction invariants"
```

### Task 2: Add generic ComputerAgentCore target

**Files:**
- Modify: `ExamPilot/Package.swift`
- Create: `ExamPilot/Sources/ComputerAgentCore/ComputerAgentSession.swift`
- Create: `ExamPilot/Sources/ComputerAgentCore/ComputerObservation.swift`
- Create: `ExamPilot/Sources/ComputerAgentCore/ComputerAgentProvider.swift`
- Test: `ExamPilot/Tests/ComputerAgentCoreTests/ComputerAgentSessionTests.swift`

**Interfaces:** Produces generic session/observation/provider context/proposal types with no exam-specific state.

- [ ] **Step 1: Write failing stale-observation test**

```swift
func testProposalMustMatchCurrentObservationAndStateVersion() {
    var session = ComputerAgentSession(sessionID: "s1", goalID: "g1", taskID: "t1", goal: "Fill form", profileID: "generic")
    let first = session.acceptObservation(id: "o1")
    let second = session.acceptObservation(id: "o2")
    XCTAssertFalse(session.isCurrent(observationID: first.observationID, stateVersion: first.stateVersion))
    XCTAssertTrue(session.isCurrent(observationID: second.observationID, stateVersion: second.stateVersion))
}
```

- [ ] **Step 2: Observe RED**

```bash
cd ExamPilot
swift test --filter ComputerAgentSessionTests
```

- [ ] **Step 3: Add package target and minimal generic types**

```swift
.library(name: "ComputerAgentCore", targets: ["ComputerAgentCore"]),
.target(name: "ComputerAgentCore"),
.testTarget(name: "ComputerAgentCoreTests", dependencies: ["ComputerAgentCore"]),
```

Generic provider context contains session/task/goal/stateVersion/observationID/bounded working memory/provider continuation only.

- [ ] **Step 4: Verify GREEN**

```bash
cd ExamPilot
swift test
swift build -c release
```

- [ ] **Step 5: Commit**

```bash
git add ExamPilot/Package.swift ExamPilot/Sources/ComputerAgentCore ExamPilot/Tests/ComputerAgentCoreTests
git commit -m "feat: add generic ComputerAgentCore target"
```

### Task 3: Split generic computer safety from ExamTaskProfile

**Files:**
- Create: `ExamPilot/Sources/ComputerAgentCore/ComputerTaskProfile.swift`
- Create: `ExamPilot/Sources/ComputerAgentCore/ComputerAgentSafetyPolicy.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/ExamTaskProfile.swift`
- Test: `ExamPilot/Tests/ComputerAgentCoreTests/ComputerAgentSafetyPolicyTests.swift`
- Test: `ExamPilot/Tests/ExamPilotCoreTests/ExamTaskProfileTests.swift`

**Interfaces:** Generic safety checks action shape/bounds, stale state/observation, focus/cancellation preconditions. Exam profile owns answer/navigation semantics.

- [ ] **Step 1: Write failing separation tests**

```swift
func testGenericSafetyRejectsStaleObservationWithoutExamKnowledge() {
    let result = ComputerAgentSafetyPolicy().validate(.test(stateVersion: 1, observationID: "o1"), context: .init(currentStateVersion: 2, currentObservationID: "o2"))
    XCTAssertEqual(result, .denied(.staleObservation))
}

func testExamProfileRejectsNavigationUntilAnswerVerified() {
    XCTAssertFalse(ExamTaskProfile(state: ExamRuntimeState()).navigationAllowed)
}
```

- [ ] **Step 2: Observe RED**

```bash
cd ExamPilot
swift test --filter ComputerAgentSafetyPolicyTests
swift test --filter ExamTaskProfileTests
```

- [ ] **Step 3: Implement layers and adapt ActionBatchPolicy**

Keep `ActionBatchPolicy` as a thin compatibility adapter composing generic safety + `ExamTaskProfile`; do not delete it yet.

- [ ] **Step 4: Verify full ExamPilot suite**

```bash
cd ExamPilot
swift test
```

- [ ] **Step 5: Commit**

```bash
git add ExamPilot/Sources/ComputerAgentCore ExamPilot/Sources/ExamPilotCore/ExamTaskProfile.swift ExamPilot/Tests
git commit -m "refactor: separate computer safety from exam policy"
```

### Task 4: Add ComputerAgentMacOS observation/focus boundary

**Files:**
- Modify: `ExamPilot/Package.swift`
- Create: `ExamPilot/Sources/ComputerAgentMacOS/ComputerObservationEngine.swift`
- Create: `ExamPilot/Sources/ComputerAgentMacOS/ObservationFusion.swift`
- Create: `ExamPilot/Sources/ComputerAgentMacOS/FocusValidator.swift`
- Test: `ExamPilot/Tests/ComputerAgentMacOSTests/ObservationFusionTests.swift`

**Interfaces:** Combines ScreenCaptureKit, Accessibility, browser semantics and vision/OCR into `ComputerObservation`. Conflicting process/window identities require re-observation.

- [ ] **Step 1: Write failing identity-mismatch test**

```swift
func testFusionRejectsMismatchedWindowIdentity() {
    let result = ObservationFusion().fuse(screen: .test(processID: 10, windowID: 100), accessibility: .test(processID: 11, windowID: 200))
    XCTAssertEqual(result, .reobserve(.identityMismatch))
}
```

- [ ] **Step 2: Observe RED**

```bash
cd ExamPilot
swift test --filter ObservationFusionTests
```

- [ ] **Step 3: Add macOS target and wrap existing primitives first**

```swift
.library(name: "ComputerAgentMacOS", targets: ["ComputerAgentMacOS"]),
.target(name: "ComputerAgentMacOS", dependencies: ["ComputerAgentCore"]),
.testTarget(name: "ComputerAgentMacOSTests", dependencies: ["ComputerAgentMacOS", "ComputerAgentCore"]),
```

Do not move existing capture/focus implementation until parity tests prove the wrapper.

- [ ] **Step 4: Verify GREEN**

```bash
cd ExamPilot
swift test
swift build -c release
```

- [ ] **Step 5: Commit**

```bash
git add ExamPilot/Package.swift ExamPilot/Sources/ComputerAgentMacOS ExamPilot/Tests/ComputerAgentMacOSTests
git commit -m "feat: add reusable macOS computer observation boundary"
```

### Task 5: ToolFabric-backed ZeroLose physical mutation gateway

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Computer/ComputerActionToolMapper.swift`
- Create: `ZeroLose/ZeroLose/V2/Computer/ToolFabricComputerMutationGateway.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ToolFabricComputerMutationGatewayTests.swift`

**Interfaces:** Each physical action becomes a fresh child ToolInvocation such as `computer.pointer.click` or `computer.keyboard.type`; no batch-wide approval token exists.

- [ ] **Step 1: Write failing per-action gate test**

```swift
func testThreePhysicalActionsCreateThreeFreshInvocations() async throws {
    let fabric = RecordingToolFabric()
    let gateway = ToolFabricComputerMutationGateway(toolFabric: fabric)
    try await gateway.execute([.click(x: 10, y: 10), .type("hello"), .click(x: 20, y: 20)], parentInvocationID: .init(rawValue: "parent"))
    XCTAssertEqual(await fabric.invocationCount, 3)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ToolFabricComputerMutationGatewayTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement fresh child invocation mapping**

Every child reads current registry revision/current state immediately before submission. Never reuse PolicyKernel decisions across physical actions.

- [ ] **Step 4: Verify both products**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
cd ExamPilot && swift test
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Computer ZeroLose/ZeroLoseTests/V2/ToolFabricComputerMutationGatewayTests.swift
git commit -m "feat: gate computer mutations through Tool Fabric"
```

### Task 6: Make ExamLoop a compatibility facade

**Files:**
- Create: `ExamPilot/Sources/ComputerAgentCore/ComputerAgentRuntime.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Create: `ZeroLose/ZeroLoseTests/V2/ArchitectureBoundaryTests.swift`

**Interfaces:** `ExamLoop` composes generic runtime + `ExamTaskProfile`; ZeroLose must never import `ExamPilotCore`.

- [ ] **Step 1: Add boundary test**

```swift
func testZeroLoseSourcesDoNotImportExamPilotCore() throws {
    for source in try allSwiftSources(under: "ZeroLose/ZeroLose") {
        XCTAssertFalse(source.contents.contains("import ExamPilotCore"), source.path)
    }
}
```

- [ ] **Step 2: Run boundary test**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ArchitectureBoundaryTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Move generic orchestration behind ComputerAgentRuntime**

Preserve provider continuation, UI stability, verifier evidence, recovery and cancellation semantics; `ExamLoop` stays as a thin compatibility facade.

- [ ] **Step 4: Run all gates**

```bash
cd ExamPilot
swift test
swift build -c release
cd ..
python3 scripts/verify_all.py
```

- [ ] **Step 5: Commit**

```bash
git add ExamPilot/Sources/ComputerAgentCore/ComputerAgentRuntime.swift ExamPilot/Sources/ExamPilotCore/ExamLoop.swift ZeroLose/ZeroLoseTests/V2/ArchitectureBoundaryTests.swift
git commit -m "refactor: make ExamLoop a generic runtime facade"
```

### Track completion gate

```bash
python3 scripts/verify_all.py
```

Expected: PASS; ExamPilot behavior remains correct, ZeroLose has no exam-domain dependency, and ZeroLose physical input uses the Tool Fabric-backed gateway.
