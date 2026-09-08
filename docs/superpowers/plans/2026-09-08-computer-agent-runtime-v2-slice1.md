# Computer Agent Runtime V2 Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the reported `Next Question` skip loop by introducing runtime-owned exam state, state-aware boundary policy, UI-stability gating, and structured diagnostics without replacing the existing native macOS capture/input primitives.

**Architecture:** This slice keeps `ExamLoop`, `ScreenCaptureService`, `NativeInputDriver`, and the structured vision provider, but inserts deterministic runtime state and policy between model proposals and physical input. A protected boundary is never executed while the current question is unverified; if a proposal contains answer actions followed by a boundary, the boundary is deferred so the answer can be executed and verified first. Boundary transitions are not presented to the model again until consecutive frames are stable.

**Tech Stack:** Swift 5.10, macOS 14+, Swift Package Manager, XCTest, ScreenCaptureKit/CoreGraphics through existing ExamPilot abstractions, GitHub Actions `macos-15` CI.

**Spec:** `docs/superpowers/specs/2026-09-08-computer-agent-runtime-v2-design.md`

## Global Constraints

- Preserve the existing native ScreenCaptureKit observation and CoreGraphics input path.
- Runtime correctness is not delegated to prompt wording or model confidence.
- Physical mutation fails closed when state is stale, unstable, or a protected transition is illegal.
- No blind physical retry of the same stale proposal.
- `finish` remains legal when the session is visibly terminal; protected-boundary rules apply to non-finish boundary actions.
- This slice does not add persistent memory, native OpenAI Computer Use, DOM/CDP actuation, or package-wide renaming.
- Existing emergency-stop, process/window focus, coordinate bounds, action-count, key, wait, and scroll protections must remain green.
- Local execution is unavailable in the current conversation environment; RED/GREEN verification is performed through the existing `ExamPilot` GitHub Actions pull-request workflow until local macOS execution becomes available.

---

## File Structure

- Create `ExamPilot/Sources/ExamPilotCore/ExamRuntimeState.swift`: runtime-owned lifecycle, state-version, answer verification, and transition state.
- Modify `ExamPilot/Sources/ExamPilotCore/Models.swift`: bind validated batches to a state version and expose conservative mutation/boundary metadata.
- Modify `ExamPilot/Sources/ExamPilotCore/ActionBatchPolicy.swift`: defer or deny protected boundaries when navigation is not allowed.
- Modify `ExamPilot/Sources/ExamPilotCore/VisionAgent.swift`: carry runtime state to the provider as read-only context.
- Modify `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`: own `ExamRuntimeState`, enforce stale-batch checks, verify answer mutations, and gate boundary transitions on UI stability.
- Create `ExamPilot/Sources/ExamPilotCore/UIStabilityDetector.swift`: deterministic consecutive-frame stability predicate.
- Create `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`: structured diagnostic event model and sink.
- Modify `ExamPilot/Sources/ExamPilotCore/OpenAIResponsesVisionAgent.swift`: expose the new runtime state in the prompt; do not change provider protocol or output schema in this slice.
- Create `ExamPilot/Tests/ExamPilotCoreTests/ExamRuntimeStateTests.swift`.
- Modify `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchPolicyTests.swift`.
- Modify `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopTests.swift`.
- Create `ExamPilot/Tests/ExamPilotCoreTests/UIStabilityDetectorTests.swift`.
- Create `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`.

---

### Task 1: Runtime-owned exam lifecycle and state versioning

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ExamRuntimeState.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExamRuntimeStateTests.swift`

**Interfaces:**
- Produces: `ExamRuntimeState`, `ExamAnswerState`, `ExamUIPhase`.
- Later tasks consume: `stateVersion`, `navigationAllowed`, `acceptObservation()`, `recordAnswerVerified()`, `beginBoundaryTransition()`, `completeBoundaryTransition()`, `cancelBoundaryTransition()`.

- [ ] **Step 1: Write the failing runtime-state tests**

```swift
import XCTest
@testable import ExamPilotCore

final class ExamRuntimeStateTests: XCTestCase {
    func testNavigationIsDeniedUntilAnswerIsVerified() {
        var state = ExamRuntimeState()
        XCTAssertFalse(state.navigationAllowed)

        state.recordAnswerVerified()

        XCTAssertTrue(state.navigationAllowed)
    }

    func testBoundaryCompletionStartsFreshUnansweredQuestion() {
        var state = ExamRuntimeState()
        state.recordAnswerVerified()
        let previousQuestion = state.questionGeneration

        state.beginBoundaryTransition()
        XCTAssertEqual(state.uiPhase, .transitioning)
        XCTAssertFalse(state.navigationAllowed)

        state.completeBoundaryTransition()

        XCTAssertEqual(state.questionGeneration, previousQuestion + 1)
        XCTAssertEqual(state.answerState, .unanswered)
        XCTAssertEqual(state.uiPhase, .stable)
        XCTAssertFalse(state.navigationAllowed)
    }

    func testAcceptedObservationsAdvanceStateVersionMonotonically() {
        var state = ExamRuntimeState()
        let initial = state.stateVersion

        state.acceptObservation()
        let first = state.stateVersion
        state.acceptObservation()

        XCTAssertGreaterThan(first, initial)
        XCTAssertGreaterThan(state.stateVersion, first)
    }
}
```

- [ ] **Step 2: Commit only the failing tests and verify RED through PR CI**

Commit message:

```text
test: define exam runtime lifecycle invariants
```

Expected GitHub Actions result: Swift test job fails because `ExamRuntimeState`, `ExamAnswerState`, and `ExamUIPhase` do not exist.

- [ ] **Step 3: Implement the minimal runtime state**

```swift
import Foundation

public enum ExamAnswerState: String, Codable, Equatable {
    case unanswered
    case verified
}

public enum ExamUIPhase: String, Codable, Equatable {
    case stable
    case transitioning
}

public struct ExamRuntimeState: Codable, Equatable {
    public private(set) var stateVersion: UInt64
    public private(set) var questionGeneration: UInt64
    public private(set) var answerState: ExamAnswerState
    public private(set) var uiPhase: ExamUIPhase

    public init(
        stateVersion: UInt64 = 0,
        questionGeneration: UInt64 = 1,
        answerState: ExamAnswerState = .unanswered,
        uiPhase: ExamUIPhase = .stable
    ) {
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.answerState = answerState
        self.uiPhase = uiPhase
    }

    public var navigationAllowed: Bool {
        uiPhase == .stable && answerState == .verified
    }

    public mutating func acceptObservation() {
        advanceVersion()
    }

    public mutating func recordAnswerVerified() {
        answerState = .verified
        uiPhase = .stable
        advanceVersion()
    }

    public mutating func beginBoundaryTransition() {
        uiPhase = .transitioning
        advanceVersion()
    }

    public mutating func completeBoundaryTransition() {
        if questionGeneration < UInt64.max {
            questionGeneration += 1
        }
        answerState = .unanswered
        uiPhase = .stable
        advanceVersion()
    }

    public mutating func cancelBoundaryTransition() {
        uiPhase = .stable
        advanceVersion()
    }

    private mutating func advanceVersion() {
        if stateVersion < UInt64.max {
            stateVersion += 1
        }
    }
}
```

- [ ] **Step 4: Verify GREEN through PR CI**

Expected: `ExamRuntimeStateTests` pass and existing ExamPilot tests remain green.

- [ ] **Step 5: Commit implementation**

```text
feat: add exam runtime lifecycle state
```

---

### Task 2: State-aware protected-boundary policy

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/Models.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ActionBatchPolicy.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchPolicyTests.swift`

**Interfaces:**
- Produces: `ActionPolicyContext(stateVersion:navigationAllowed:)`.
- Produces: `ValidatedBatch.stateVersion`, `ValidatedBatch.deferredProtectedBoundary`, `ValidatedBatch.containsProtectedBoundary`, `ValidatedBatch.hasPotentialAnswerMutation`.
- `ExamLoop` in Task 3 consumes these fields.

- [ ] **Step 1: Add failing boundary-policy tests**

```swift
func testRejectsProtectedBoundaryAsFirstActionWhenQuestionIsUnanswered() {
    let decision = ExamDecision(
        summary: "skip current question",
        expectsVisualChange: true,
        actions: [.moveClick(x: 1200, y: 820, boundary: true)]
    )
    let context = ActionPolicyContext(stateVersion: 9, navigationAllowed: false)

    XCTAssertThrowsError(
        try ActionBatchPolicy().validate(decision, screenBounds: bounds, context: context)
    ) { error in
        XCTAssertEqual(error as? ActionValidationError, .protectedBoundaryBeforeAnswer)
    }
}

func testDefersBoundaryAfterAnswerActionsUntilAnswerVerification() throws {
    let decision = ExamDecision(
        summary: "answer then next",
        expectsVisualChange: true,
        actions: [
            .moveClick(x: 400, y: 400),
            .moveClick(x: 1200, y: 820, boundary: true),
        ]
    )
    let context = ActionPolicyContext(stateVersion: 11, navigationAllowed: false)

    let batch = try ActionBatchPolicy().validate(decision, screenBounds: bounds, context: context)

    XCTAssertEqual(batch.actions, [.moveClick(x: 400, y: 400)])
    XCTAssertTrue(batch.deferredProtectedBoundary)
    XCTAssertTrue(batch.expectsVisualChange)
    XCTAssertTrue(batch.hasPotentialAnswerMutation)
    XCTAssertEqual(batch.stateVersion, 11)
}

func testAllowsProtectedBoundaryAfterVerifiedAnswer() throws {
    let decision = ExamDecision(
        summary: "go next",
        expectsVisualChange: true,
        actions: [.moveClick(x: 1200, y: 820, boundary: true)]
    )
    let context = ActionPolicyContext(stateVersion: 12, navigationAllowed: true)

    let batch = try ActionBatchPolicy().validate(decision, screenBounds: bounds, context: context)

    XCTAssertTrue(batch.containsProtectedBoundary)
    XCTAssertFalse(batch.deferredProtectedBoundary)
}
```

Update existing policy tests to pass an explicit permissive context where they are testing unrelated coordinate/action bounds:

```swift
private let permissiveContext = ActionPolicyContext(stateVersion: 1, navigationAllowed: true)
```

- [ ] **Step 2: Commit tests and verify RED through PR CI**

Expected failure: missing `ActionPolicyContext`, missing `protectedBoundaryBeforeAnswer`, and old `validate` signature.

- [ ] **Step 3: Extend `ValidatedBatch` and validation errors**

Add to `ValidatedBatch`:

```swift
public let stateVersion: UInt64
public let deferredProtectedBoundary: Bool

public var containsProtectedBoundary: Bool {
    actions.contains { $0.boundary && $0.kind != .finish }
}

public var hasPotentialAnswerMutation: Bool {
    actions.contains { action in
        switch action.kind {
        case .moveClick, .typeText, .key:
            return !action.boundary
        case .scroll, .wait, .finish:
            return false
        }
    }
}
```

Add to `ActionValidationError`:

```swift
case protectedBoundaryBeforeAnswer
```

with error text:

```swift
"A protected boundary cannot execute before the current question has a verified answer."
```

- [ ] **Step 4: Implement state-aware policy**

```swift
public struct ActionPolicyContext: Equatable {
    public let stateVersion: UInt64
    public let navigationAllowed: Bool

    public init(stateVersion: UInt64, navigationAllowed: Bool) {
        self.stateVersion = stateVersion
        self.navigationAllowed = navigationAllowed
    }
}
```

In `validate`, process a non-finish boundary before appending it:

```swift
if action.boundary, action.kind != .finish, !context.navigationAllowed {
    guard !accepted.isEmpty else {
        throw ActionValidationError.protectedBoundaryBeforeAnswer
    }
    deferredProtectedBoundary = true
    break
}
```

Return:

```swift
return ValidatedBatch(
    summary: decision.summary,
    expectsVisualChange: decision.expectsVisualChange || boundaryRequiresVerification || deferredProtectedBoundary,
    actions: accepted,
    stateVersion: context.stateVersion,
    deferredProtectedBoundary: deferredProtectedBoundary
)
```

- [ ] **Step 5: Verify GREEN and commit**

Expected: all policy tests pass.

```text
feat: guard protected boundaries with runtime state
```

---

### Task 3: Integrate state policy into `ExamLoop` and freeze the reported regression

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/VisionAgent.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopTests.swift`

**Interfaces:**
- `ExamObservationState` gains read-only runtime context fields with defaults so existing provider tests stay source-compatible.
- `ExamLoop` owns one `ExamRuntimeState` for the run.

- [ ] **Step 1: Add the exact failing regression test**

Add a test whose provider sequence is:

1. Q1 proposal: answer click + protected Next boundary in one proposal.
2. Q2 proposal: protected Next as the first action while the new question is unanswered.
3. Q2 recovery proposal: answer click.
4. Q2 verified proposal: protected Next.
5. final proposal: finish.

Use frames that produce visible change for the answer and navigation boundaries. The core assertion is:

```swift
XCTAssertEqual(
    driver.calls,
    ["click", "click", "click", "click"]
)
```

where the four physical clicks are exactly:

```text
Q1 answer
Q1 Next
Q2 answer
Q2 Next
```

and there is no physical click for the denied premature Q2 `Next` proposal.

Also capture every `ExamObservationState` passed to the fake provider and assert that Q2 begins with `answerVerified == false`.

- [ ] **Step 2: Commit regression test and verify RED through PR CI**

Expected: current runtime executes the premature Q2 boundary, so the physical-call sequence differs from the expected sequence.

- [ ] **Step 3: Extend provider observation state**

```swift
public struct ExamObservationState: Codable, Equatable {
    public var cycle: Int
    public var nonProgressCount: Int
    public var lastSummary: String?
    public var stateVersion: UInt64
    public var questionGeneration: UInt64
    public var answerVerified: Bool
    public var uiPhase: ExamUIPhase

    public init(
        cycle: Int,
        nonProgressCount: Int,
        lastSummary: String?,
        stateVersion: UInt64 = 0,
        questionGeneration: UInt64 = 1,
        answerVerified: Bool = false,
        uiPhase: ExamUIPhase = .stable
    ) {
        self.cycle = cycle
        self.nonProgressCount = nonProgressCount
        self.lastSummary = lastSummary
        self.stateVersion = stateVersion
        self.questionGeneration = questionGeneration
        self.answerVerified = answerVerified
        self.uiPhase = uiPhase
    }
}
```

- [ ] **Step 4: Make `ExamLoop` bind proposals to current runtime state**

Before creating `ExamObservationState`:

```swift
runtimeState.acceptObservation()
```

Pass:

```swift
stateVersion: runtimeState.stateVersion,
questionGeneration: runtimeState.questionGeneration,
answerVerified: runtimeState.answerState == .verified,
uiPhase: runtimeState.uiPhase
```

Validate using:

```swift
let context = ActionPolicyContext(
    stateVersion: runtimeState.stateVersion,
    navigationAllowed: runtimeState.navigationAllowed
)
let batch = try policy.validate(
    decision,
    screenBounds: before.screenBounds,
    context: context
)
```

Immediately before physical execution, reject stale batches:

```swift
guard batch.stateVersion == runtimeState.stateVersion else {
    continue
}
```

- [ ] **Step 5: Record verified answer state only after observed mutation**

After post-action verification succeeds:

```swift
if batch.hasPotentialAnswerMutation && !batch.containsProtectedBoundary {
    runtimeState.recordAnswerVerified()
}
```

A deferred boundary therefore requires a fresh observation after the answer mutation and cannot execute in the same stale batch.

- [ ] **Step 6: Treat policy denial as re-observation, not physical retry**

Catch specifically:

```swift
catch ActionValidationError.protectedBoundaryBeforeAnswer {
    nonProgressCount = 0
    continue
}
```

Do not execute the denied action and do not shift its coordinate.

- [ ] **Step 7: Verify regression GREEN and commit**

Expected: exact physical click order contains no premature Q2 navigation click; all prior tests remain green.

```text
fix: prevent navigation before verified answers
```

---

### Task 4: Gate boundary transitions on UI stability

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/UIStabilityDetector.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/UIStabilityDetectorTests.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopTests.swift`

**Interfaces:**
- Produces: `UIStabilityDetector.isStable(previous:current:)`.
- `ExamLoop` consumes it only for protected-boundary transitions in this slice.

- [ ] **Step 1: Write detector RED tests**

```swift
func testIdenticalFramesAreStable() throws {
    let frame = try makeImage(gray: 0.4)
    XCTAssertTrue(UIStabilityDetector().isStable(previous: frame, current: frame))
}

func testMateriallyDifferentFramesAreNotStable() throws {
    let dark = try makeImage(gray: 0.1)
    let bright = try makeImage(gray: 0.9)
    XCTAssertFalse(UIStabilityDetector().isStable(previous: dark, current: bright))
}
```

- [ ] **Step 2: Commit tests and verify RED**

Expected: missing `UIStabilityDetector`.

- [ ] **Step 3: Implement the detector**

```swift
import CoreGraphics

public struct UIStabilityDetector {
    private let changeDetector: VisualChangeDetector

    public init(gridSize: Int = 24, threshold: Double = 0.015) {
        self.changeDetector = VisualChangeDetector(gridSize: gridSize, threshold: threshold)
    }

    public func isStable(previous: CGImage, current: CGImage) -> Bool {
        !changeDetector.hasMeaningfulChange(before: previous, after: current)
    }
}
```

- [ ] **Step 4: Add a loop test proving the provider is not called on a transition frame**

Use a boundary action followed by frame sequence:

```text
question A -> loading -> partial question B -> stable question B -> provider turn
```

Record capture/provider events and assert there is no provider call between `loading` and the stable consecutive frame.

- [ ] **Step 5: Implement bounded transition stabilization**

Add constructor dependencies:

```swift
stabilityDetector: UIStabilityDetector = UIStabilityDetector(),
maxStabilitySamples: Int = 4,
stabilitySettler: @escaping () async throws -> Void = {
    try await Task.sleep(nanoseconds: 150_000_000)
}
```

When a protected boundary produces meaningful visual change:

```swift
runtimeState.beginBoundaryTransition()
pendingTransitionFrame = after
continue
```

At the beginning of the next loop iteration, if `pendingTransitionFrame` exists, sample up to `maxStabilitySamples` frames. Only when two consecutive frames satisfy `isStable`:

```swift
runtimeState.completeBoundaryTransition()
pendingTransitionFrame = nil
```

Then use the stable frame as the next provider observation. If the sample budget is exhausted, keep the newest frame as pending, increment bounded non-progress state, and do not call the provider.

- [ ] **Step 6: Verify GREEN and commit**

Expected: provider calls only occur on stable observations; existing boundary tests are updated with sufficient fixture frames.

```text
feat: wait for stable UI after protected boundaries
```

---

### Task 5: Structured diagnostics for policy and transition decisions

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`

**Interfaces:**
- Produces: `AgentEvent`, `AgentEventKind`, `AgentEventSinking`, `NullAgentEventSink`.
- Events in this slice contain only bounded structured metadata, never API payloads or secrets.

- [ ] **Step 1: Write event-model RED tests**

```swift
func testPolicyDenialEventContainsRuntimeCoordinatesWithoutSecrets() throws {
    let event = AgentEvent(
        kind: .policyDenied,
        cycle: 2,
        stateVersion: 7,
        questionGeneration: 2,
        detail: "protected_boundary_before_answer"
    )

    let data = try JSONEncoder().encode(event)
    let text = String(decoding: data, as: UTF8.self)

    XCTAssertTrue(text.contains("policyDenied"))
    XCTAssertTrue(text.contains("protected_boundary_before_answer"))
    XCTAssertFalse(text.lowercased().contains("authorization"))
    XCTAssertFalse(text.lowercased().contains("api_key"))
}
```

- [ ] **Step 2: Commit test and verify RED**

Expected: event types do not exist.

- [ ] **Step 3: Implement event model**

```swift
import Foundation

public enum AgentEventKind: String, Codable, Equatable {
    case observationAccepted
    case proposalReceived
    case policyDenied
    case batchValidated
    case answerVerified
    case boundaryTransitionStarted
    case boundaryTransitionCompleted
    case verificationFailed
    case stabilityWaiting
}

public struct AgentEvent: Codable, Equatable {
    public let kind: AgentEventKind
    public let cycle: Int
    public let stateVersion: UInt64
    public let questionGeneration: UInt64
    public let detail: String
}

public protocol AgentEventSinking: AnyObject {
    func record(_ event: AgentEvent)
}

public final class NullAgentEventSink: AgentEventSinking {
    public init() {}
    public func record(_ event: AgentEvent) {}
}
```

- [ ] **Step 4: Inject sink into `ExamLoop` and emit minimum correctness events**

Emit events for:

```text
observationAccepted
proposalReceived
policyDenied
batchValidated
answerVerified
boundaryTransitionStarted
boundaryTransitionCompleted
verificationFailed
stabilityWaiting
```

All event `detail` strings must be static reason identifiers or existing concise model summaries; never serialize screenshot bytes, HTTP headers, API keys, or raw provider response payloads.

- [ ] **Step 5: Add loop assertion for the reported regression**

The regression test must assert one event with:

```text
kind = policyDenied
detail = protected_boundary_before_answer
questionGeneration = 2
```

and still assert zero physical clicks for that denied proposal.

- [ ] **Step 6: Verify GREEN and commit**

```text
feat: add structured runtime diagnostics
```

---

### Task 6: Provider context, full verification, and implementation PR

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/OpenAIResponsesVisionAgent.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/OpenAIResponsesVisionAgentTests.swift`

**Interfaces:**
- No schema change in this slice.
- Provider receives runtime state only as additional prompt context; runtime policy remains authoritative.

- [ ] **Step 1: Add failing prompt-body assertion**

Extend the existing HTTP request capture test and assert the generated body contains:

```text
state_version=7
question_generation=3
answer_verified=false
ui_phase=stable
```

using:

```swift
ExamObservationState(
    cycle: 4,
    nonProgressCount: 0,
    lastSummary: "previous",
    stateVersion: 7,
    questionGeneration: 3,
    answerVerified: false,
    uiPhase: .stable
)
```

- [ ] **Step 2: Verify RED through CI**

Expected: current prompt omits the four runtime fields.

- [ ] **Step 3: Extend only the runtime-state prompt line**

Use:

```text
Runtime state: cycle=..., consecutive_non_progress=..., previous_summary=..., state_version=..., question_generation=..., answer_verified=..., ui_phase=....
```

Do not add a new model-controlled boolean that can bypass policy.

- [ ] **Step 4: Verify complete PR CI**

The pull-request workflow must report both steps successful:

```text
Swift test
Release build
```

- [ ] **Step 5: Inspect failures and warnings**

If CI fails, fetch the exact failed job logs, classify the failure, and fix only the responsible task. Do not stack unrelated changes.

- [ ] **Step 6: Compare feature branch against design branch**

Expected changed surface is limited to:

```text
ExamPilot/Sources/ExamPilotCore/* runtime/policy/stability/event/provider-context files
ExamPilot/Tests/ExamPilotCoreTests/* corresponding tests
docs/superpowers/plans/2026-09-08-computer-agent-runtime-v2-slice1.md
```

- [ ] **Step 7: Final verification gate**

Before claiming completion, invoke `superpowers:verification-before-completion`. If local macOS access becomes available, additionally run:

```bash
cd ExamPilot
swift test
swift build -c release
cd ..
python3 scripts/verify_all.py
```

If local access is still unavailable, explicitly report that CI passed but repository-wide local verification was not executable from this conversation.

---

## Plan Self-Review

### Spec coverage for this slice

- Runtime-owned lifecycle/state version: Tasks 1 and 3.
- Unanswered-question protected-boundary invariant: Tasks 2 and 3.
- Stale proposal binding: Tasks 2 and 3.
- UI stability before re-reasoning after boundary: Task 4.
- Structured diagnostics/replay-ready event foundation: Task 5.
- Provider receives runtime state but cannot override policy: Task 6.
- Existing native capture/input/focus safety remains unchanged and is covered by the full existing suite in Task 6.

### Explicitly deferred to later implementation plans

- semantic target roles richer than conservative protected-boundary semantics;
- dedicated `ComputerAgentSession` abstraction;
- native OpenAI Computer Use provider and `previous_response_id` continuation;
- Accessibility/browser semantic sensor fusion;
- persistent episodic/procedural memory;
- deterministic recorded-session replay CLI;
- full local benchmark fixture application;
- package extraction/rename to `ComputerAgentCore`.

These are independent subsystems from the immediate correctness regression and will not be mixed into this slice.
