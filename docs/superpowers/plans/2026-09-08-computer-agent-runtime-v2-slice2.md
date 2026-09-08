# Computer Agent Runtime V2 Slice 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate physical action completion from semantic success by adding deterministic action execution receipts and an action-specific outcome verifier, then make `ExamLoop` advance answer/navigation lifecycle only from verifier evidence.

**Architecture:** Keep the Slice 1 runtime, native input stack, state-version policy, and stability gate intact. `ActionBatchExecutor` reports only physical completion receipts. `OutcomeVerifier` consumes the validated expected outcome plus pre/post visual evidence and returns `success`, `pending`, or a classified `failure`; only `ExamLoop` maps that result into lifecycle transitions. This slice intentionally uses conservative visual evidence only. Accessibility/browser semantic fusion is deferred to the later observation-fusion slice and can extend the verifier without changing the executor contract.

**Tech Stack:** Swift 5.10+, Swift Package Manager, XCTest, CoreGraphics, Foundation, existing `VisualChangeDetector`, existing GitHub Actions macOS runner.

**Spec:** `docs/superpowers/specs/2026-09-08-computer-agent-runtime-v2-design.md`

## Global Constraints

- Runtime correctness is not delegated to the model; provider output is advisory.
- Native CoreGraphics mouse, keyboard, and scroll remain the physical mutation path.
- Every executable proposal remains bound to the accepted monotonic `stateVersion`.
- Navigation remains illegal while the current question is known and not verified as answered.
- Large/structural UI changes that contradict the declared action type fail closed into transition handling.
- Blind physical retry is forbidden; recovery/anti-loop policy is a later slice.
- No new external package dependency.
- No provider schema expansion in this slice.
- No Accessibility, DOM/CDP, persistent memory, replay CLI, or package rename in this slice.
- Secrets, Authorization headers, screenshot bytes, and raw provider payloads must never enter structured events.
- Existing gates remain required: `cd ExamPilot && swift test && swift build -c release`.
- Repository-wide `python3 scripts/verify_all.py` remains required when a real local macOS checkout is available.

---

## File Structure

### New production files

- `ExamPilot/Sources/ExamPilotCore/ActionExecutionReceipt.swift`
  - Physical completion record only. No semantic-success decision.
- `ExamPilot/Sources/ExamPilotCore/OutcomeVerification.swift`
  - Expected outcome model, classified verifier result, and deterministic visual verifier.

### Modified production files

- `ExamPilot/Sources/ExamPilotCore/Models.swift`
  - Add `ExpectedOutcomeKind` to `ValidatedBatch`.
- `ExamPilot/Sources/ExamPilotCore/ActionBatchPolicy.swift`
  - Derive conservative expected outcome from the validated batch.
- `ExamPilot/Sources/ExamPilotCore/ActionBatchExecutor.swift`
  - Emit one receipt for each physically completed action.
- `ExamPilot/Sources/ExamPilotCore/ExamRuntimeState.swift`
  - Add failed-transition completion that restores stable state without advancing question generation.
- `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`
  - Add execution/outcome event kinds only; event payload shape stays bounded.
- `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
  - Replace generic post-action success mutation with `OutcomeVerifier` results.

### New/modified tests

- Create `ExamPilot/Tests/ExamPilotCoreTests/ActionExecutionReceiptTests.swift`
- Create `ExamPilot/Tests/ExamPilotCoreTests/OutcomeVerifierTests.swift`
- Create `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopOutcomeVerificationTests.swift`
- Modify `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchExecutorTests.swift`
- Modify `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchPolicyTests.swift`
- Modify `ExamPilot/Tests/ExamPilotCoreTests/ExamRuntimeStateTests.swift`
- Modify `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`
- Update existing loop fixtures only when their old expectation encoded generic pixel-change semantics.

---

### Task 1: Physical Action Execution Receipts

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ActionExecutionReceipt.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ActionExecutionReceiptTests.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ActionBatchExecutor.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchExecutorTests.swift`

**Interfaces:**
- Consumes: `ExamAction`, `ExamActionKind`, `ValidatedBatch.stateVersion`, `InputDriving`.
- Produces:
  - `PhysicalActionStatus`
  - `ActionExecutionReceipt`
  - `ActionExecutionResult.receipts`
  - `ActionBatchExecutor.init(driver:now:)`

- [ ] **Step 1: Write receipt-model RED tests**

```swift
import XCTest
@testable import ExamPilotCore

final class ActionExecutionReceiptTests: XCTestCase {
    func testReceiptCarriesPhysicalCompletionOnly() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 101)
        let receipt = ActionExecutionReceipt(
            actionIndex: 2,
            kind: .moveClick,
            stateVersion: 7,
            startedAt: start,
            completedAt: end,
            status: .completed
        )

        XCTAssertEqual(receipt.actionIndex, 2)
        XCTAssertEqual(receipt.kind, .moveClick)
        XCTAssertEqual(receipt.stateVersion, 7)
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertEqual(receipt.startedAt, start)
        XCTAssertEqual(receipt.completedAt, end)
    }
}
```

- [ ] **Step 2: Verify RED in CI**

Expected compile failure: `ActionExecutionReceipt` / `PhysicalActionStatus` do not exist.

- [ ] **Step 3: Add the receipt model**

```swift
import Foundation

public enum PhysicalActionStatus: String, Codable, Equatable {
    case completed
}

public struct ActionExecutionReceipt: Codable, Equatable {
    public let actionIndex: Int
    public let kind: ExamActionKind
    public let stateVersion: UInt64
    public let startedAt: Date
    public let completedAt: Date
    public let status: PhysicalActionStatus

    public init(
        actionIndex: Int,
        kind: ExamActionKind,
        stateVersion: UInt64,
        startedAt: Date,
        completedAt: Date,
        status: PhysicalActionStatus
    ) {
        precondition(actionIndex >= 0)
        self.actionIndex = actionIndex
        self.kind = kind
        self.stateVersion = stateVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
    }
}
```

- [ ] **Step 4: Verify model GREEN and commit**

```text
feat: add physical action execution receipts
```

- [ ] **Step 5: Write executor RED tests for deterministic receipts**

Add tests using a deterministic clock sequence:

```swift
func testCompletedPhysicalActionsProduceOrderedReceipts() async throws {
    let clock = SequenceDateClock(values: [
        Date(timeIntervalSince1970: 10),
        Date(timeIntervalSince1970: 11),
        Date(timeIntervalSince1970: 12),
        Date(timeIntervalSince1970: 13),
    ])
    let driver = RecordingDriver()
    let executor = ActionBatchExecutor(driver: driver, now: clock.now)
    let batch = ValidatedBatch(
        summary: "click then type",
        expectsVisualChange: true,
        actions: [.moveClick(x: 10, y: 10), .typeText("A")],
        stateVersion: 9
    )

    let result = try await executor.execute(batch, dryRun: false)

    XCTAssertEqual(result.receipts.count, 2)
    XCTAssertEqual(result.receipts.map(\.actionIndex), [0, 1])
    XCTAssertEqual(result.receipts.map(\.stateVersion), [9, 9])
    XCTAssertEqual(result.receipts.map(\.status), [.completed, .completed])
}

func testDryRunProducesNoPhysicalReceipts() async throws {
    let executor = ActionBatchExecutor(driver: RecordingDriver())
    let result = try await executor.execute(makeBatch(), dryRun: true)
    XCTAssertTrue(result.receipts.isEmpty)
}
```

Provide the test clock in the test file:

```swift
private final class SequenceDateClock {
    private var values: [Date]
    init(values: [Date]) { self.values = values }
    func now() -> Date { values.removeFirst() }
}
```

- [ ] **Step 6: Verify executor RED**

Expected failure: executor initializer has no `now` parameter and result has no `receipts`.

- [ ] **Step 7: Extend executor without semantic logic**

Update the result and executor:

```swift
public struct ActionExecutionResult: Equatable {
    public let executedCount: Int
    public let finished: Bool
    public let cancelled: Bool
    public let interruptedForUIChange: Bool
    public let receipts: [ActionExecutionReceipt]
}

public final class ActionBatchExecutor {
    private let driver: InputDriving
    private let now: () -> Date

    public init(driver: InputDriving, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.now = now
    }
}
```

For each non-`finish` action, capture `startedAt` immediately before the driver call and append a `.completed` receipt only after the driver call returns successfully:

```swift
let startedAt = now()
try await executePhysical(action)
let completedAt = now()
receipts.append(
    ActionExecutionReceipt(
        actionIndex: index,
        kind: action.kind,
        stateVersion: batch.stateVersion,
        startedAt: startedAt,
        completedAt: completedAt,
        status: .completed
    )
)
```

Cancellation before physical completion must not fabricate a completed receipt for that action. Preserve receipts already completed before cancellation/interruption.

- [ ] **Step 8: Verify GREEN and commit**

```text
feat: record completed physical actions
```

---

### Task 2: Expected Outcomes and Deterministic Outcome Verifier

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/OutcomeVerification.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/OutcomeVerifierTests.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/Models.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ActionBatchPolicy.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchPolicyTests.swift`

**Interfaces:**
- Consumes: `VisualChangeDetector.score`, validated action kinds/boundaries.
- Produces:
  - `ExpectedOutcomeKind`
  - `OutcomeEvidence`
  - `OutcomePendingReason`
  - `OutcomeFailureReason`
  - `OutcomeVerificationResult`
  - `OutcomeVerifying`
  - `OutcomeVerifier`
  - `ValidatedBatch.expectedOutcome`

- [ ] **Step 1: Write verifier RED tests**

Use deterministic 16x16 grayscale images and assert four different semantics:

```swift
func testAnswerMutationRequiresVisibleButNonStructuralChange() throws {
    let before = try makeFrame(gray: 0.40)
    let changed = try makeFrame(gray: 0.44)
    let result = OutcomeVerifier().verify(
        expected: .answerMutation,
        before: before.image,
        after: changed.image,
        uiStable: true
    )
    XCTAssertEqual(result, .success(.answerMutation(score: 0.04)))
}

func testAnswerMutationWithLargeStructuralShiftIsPendingTransition() throws {
    let before = try makeFrame(gray: 0.10)
    let after = try makeFrame(gray: 0.90)
    XCTAssertEqual(
        OutcomeVerifier().verify(expected: .answerMutation, before: before.image, after: after.image, uiStable: true),
        .pending(.unexpectedStructuralChange)
    )
}

func testNavigationCannotSucceedUntilStable() throws {
    let before = try makeFrame(gray: 0.10)
    let after = try makeFrame(gray: 0.90)
    XCTAssertEqual(
        OutcomeVerifier().verify(expected: .navigation, before: before.image, after: after.image, uiStable: false),
        .pending(.uiTransitioning)
    )
}

func testStableNavigationFailsWhenIdentityDidNotMateriallyChange() throws {
    let frame = try makeFrame(gray: 0.40)
    XCTAssertEqual(
        OutcomeVerifier().verify(expected: .navigation, before: frame.image, after: frame.image, uiStable: true),
        .failure(.navigationIdentityUnchanged)
    )
}
```

Because CoreGraphics rounding can produce tiny score differences, compare evidence scores with `XCTAssertEqual(..., accuracy:)` where needed rather than relying on exact floating-point literals.

- [ ] **Step 2: Verify RED**

Expected compile failure: outcome-verification types do not exist.

- [ ] **Step 3: Implement the verifier**

```swift
import CoreGraphics

public enum ExpectedOutcomeKind: String, Codable, Equatable {
    case none
    case answerMutation
    case viewportChange
    case navigation
}

public enum OutcomeEvidence: Equatable {
    case none
    case answerMutation(score: Double)
    case viewportChange(score: Double)
    case navigation(score: Double)
}

public enum OutcomePendingReason: String, Equatable {
    case uiTransitioning
    case unexpectedStructuralChange
}

public enum OutcomeFailureReason: String, Equatable {
    case noVisibleEffect
    case navigationIdentityUnchanged
}

public enum OutcomeVerificationResult: Equatable {
    case success(OutcomeEvidence)
    case pending(OutcomePendingReason)
    case failure(OutcomeFailureReason)
}

public protocol OutcomeVerifying {
    func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult
}

public struct OutcomeVerifier: OutcomeVerifying {
    private let progressDetector: VisualChangeDetector
    private let structuralDetector: VisualChangeDetector

    public init(
        progressDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.035),
        structuralDetector: VisualChangeDetector = VisualChangeDetector(threshold: 0.08)
    ) {
        self.progressDetector = progressDetector
        self.structuralDetector = structuralDetector
    }

    public func verify(
        expected: ExpectedOutcomeKind,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> OutcomeVerificationResult {
        let score = progressDetector.score(before: before, after: after)

        switch expected {
        case .none:
            return .success(.none)
        case .answerMutation:
            guard progressDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.noVisibleEffect)
            }
            guard !structuralDetector.hasMeaningfulChange(before: before, after: after) else {
                return .pending(.unexpectedStructuralChange)
            }
            return .success(.answerMutation(score: score))
        case .viewportChange:
            guard progressDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.noVisibleEffect)
            }
            return .success(.viewportChange(score: score))
        case .navigation:
            guard uiStable else { return .pending(.uiTransitioning) }
            guard structuralDetector.hasMeaningfulChange(before: before, after: after) else {
                return .failure(.navigationIdentityUnchanged)
            }
            return .success(.navigation(score: score))
        }
    }
}
```

The navigation result is deliberately named visual identity evidence, not semantic question identity. AX/browser evidence will strengthen this contract later without changing the enum/result ownership boundary.

- [ ] **Step 4: Verify verifier GREEN and commit**

```text
feat: add action-specific outcome verifier
```

- [ ] **Step 5: Write ActionPolicy expected-outcome RED tests**

```swift
func testProtectedBoundaryProducesNavigationExpectation() throws {
    let batch = try policy.validate(
        ExamDecision(summary: "next", expectsVisualChange: true, actions: [.moveClick(x: 50, y: 50, boundary: true)]),
        screenBounds: bounds,
        context: ActionPolicyContext(stateVersion: 4, navigationAllowed: true)
    )
    XCTAssertEqual(batch.expectedOutcome, .navigation)
}

func testDeferredBoundaryProducesAnswerMutationExpectation() throws {
    let batch = try policy.validate(
        ExamDecision(
            summary: "answer then next",
            expectsVisualChange: true,
            actions: [.moveClick(x: 20, y: 20), .moveClick(x: 80, y: 80, boundary: true)]
        ),
        screenBounds: bounds,
        context: ActionPolicyContext(stateVersion: 4, navigationAllowed: false)
    )
    XCTAssertTrue(batch.deferredProtectedBoundary)
    XCTAssertEqual(batch.expectedOutcome, .answerMutation)
}
```

Also cover scroll-only => `.viewportChange`, wait-only => `.none`, finish-only => `.none`.

- [ ] **Step 6: Verify RED**

Expected: `ValidatedBatch` has no `expectedOutcome`.

- [ ] **Step 7: Derive expectation in policy**

Add `expectedOutcome` to `ValidatedBatch` and derive it after boundary truncation/defer logic:

```swift
private func expectedOutcome(
    actions: [ExamAction],
    containsProtectedBoundary: Bool
) -> ExpectedOutcomeKind {
    if containsProtectedBoundary { return .navigation }
    if actions.contains(where: { $0.kind == .scroll }) { return .viewportChange }
    if actions.contains(where: {
        $0.kind == .moveClick || $0.kind == .typeText || $0.kind == .key
    }) {
        return .answerMutation
    }
    return .none
}
```

Do not use this expectation to relax any existing hard policy check. It only tells the verifier what evidence to seek.

- [ ] **Step 8: Verify GREEN and commit**

```text
feat: bind validated batches to expected outcomes
```

---

### Task 3: Transition Failure Semantics

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamRuntimeState.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/ExamRuntimeStateTests.swift`

**Interfaces:**
- Consumes: existing `.transitioning` phase and verified answer state.
- Produces: `ExamRuntimeState.failBoundaryTransition()`.

- [ ] **Step 1: Write RED state-machine test**

```swift
func testFailedNavigationReturnsToStableSameGenerationWithoutLosingVerifiedAnswer() {
    var state = ExamRuntimeState(questionGeneration: 5, answerState: .verified)
    state.beginBoundaryTransition()
    let versionBeforeFailure = state.stateVersion

    state.failBoundaryTransition()

    XCTAssertEqual(state.questionGeneration, 5)
    XCTAssertEqual(state.answerState, .verified)
    XCTAssertEqual(state.uiPhase, .stable)
    XCTAssertGreaterThan(state.stateVersion, versionBeforeFailure)
    XCTAssertTrue(state.navigationAllowed)
}
```

- [ ] **Step 2: Verify RED**

Expected: `failBoundaryTransition()` missing.

- [ ] **Step 3: Implement failure completion**

```swift
public mutating func failBoundaryTransition() {
    guard uiPhase == .transitioning else { return }
    uiPhase = .stable
    stateVersion &+= 1
}
```

Do not increment `questionGeneration` and do not clear `answerState`; a failed navigation means the current verified question remains current.

- [ ] **Step 4: Verify GREEN and commit**

```text
feat: model failed navigation transition
```

---

### Task 4: Integrate Outcome Verification Into ExamLoop

**Files:**
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopOutcomeVerificationTests.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`
- Update existing loop tests only as required by the new explicit semantics.

**Interfaces:**
- Consumes:
  - `ValidatedBatch.expectedOutcome`
  - `ActionExecutionResult.receipts`
  - `OutcomeVerifying.verify(...)`
  - `ExamRuntimeState.failBoundaryTransition()`
- Produces:
  - `ExamLoop.init(... outcomeVerifier:)`
  - new event kinds: `.actionExecuted`, `.outcomeVerified`, `.outcomePending`
  - pending transition verification context owned by `ExamLoop`.

- [ ] **Step 1: Write RED loop test: no visible effect cannot verify answer**

```swift
func testNoVisibleEffectNeverMarksAnswerVerified() async throws {
    let same = try makeFrame(gray: 0.4)
    let capture = QueueCapture(frames: [same, same, same])
    let agent = RecordingAgent(decisions: [
        ExamDecision(summary: "answer", expectsVisualChange: true, actions: [.moveClick(x: 10, y: 10)]),
        ExamDecision(summary: "next", expectsVisualChange: true, actions: [.moveClick(x: 90, y: 90, boundary: true)]),
        ExamDecision(summary: "finish", expectsVisualChange: false, actions: [.finish()]),
    ])
    let driver = RecordingDriver()
    let loop = ExamLoop(
        capture: capture,
        visionAgent: agent,
        executor: ActionBatchExecutor(driver: driver),
        dryRun: false,
        postActionSettler: {}
    )

    _ = await loop.run()

    XCTAssertFalse(agent.states[1].answerVerified)
    XCTAssertEqual(driver.clicks, [CGPoint(x: 10, y: 10)])
}
```

- [ ] **Step 2: Write RED loop test: stable navigation identity unchanged does not advance generation**

Inject a verifier configured so the protected boundary produces a changed/loading frame but the final stable frame is equivalent to the original identity. Assert:

```swift
XCTAssertEqual(agent.states[1].questionGeneration, 1)
XCTAssertTrue(agent.states[1].answerVerified)
```

and assert the runtime emits `verificationFailed / navigation_identity_unchanged` rather than incrementing to generation 2.

- [ ] **Step 3: Write RED loop test: successful stable navigation advances exactly once**

Use `Q1 -> loading -> Q2 -> Q2` frames. Assert:

```swift
XCTAssertEqual(agent.states[1].questionGeneration, 2)
XCTAssertFalse(agent.states[1].answerVerified)
XCTAssertEqual(agent.states[1].uiPhase, .stable)
```

- [ ] **Step 4: Verify RED**

Expected: current loop still owns generic `detector.hasMeaningfulChange` success semantics and does not consume `OutcomeVerifying`.

- [ ] **Step 5: Add explicit verifier dependency**

```swift
private let outcomeVerifier: OutcomeVerifying

public init(
    ...,
    outcomeVerifier: OutcomeVerifying = OutcomeVerifier(),
    ...
) {
    ...
    self.outcomeVerifier = outcomeVerifier
}
```

Because the protocol is value-friendly, do not require class identity or mutable verifier state.

- [ ] **Step 6: Replace answer-mutation success logic**

After post-action capture, require at least one physical receipt for a physical batch and call:

```swift
let outcome = outcomeVerifier.verify(
    expected: batch.expectedOutcome,
    before: before.image,
    after: after.image,
    uiStable: true
)
```

Map results as follows:

```text
success(.answerMutation) -> recordAnswerVerified()
success(.viewportChange) -> keep lifecycle, reset non-progress
failure(.noVisibleEffect) -> increment non-progress; never verify answer
pending(.unexpectedStructuralChange) -> begin transition; use `after` as pending frame
```

The runtime must never call `recordAnswerVerified()` from raw pixel-change truth directly after this task.

- [ ] **Step 7: Verify navigation only after the stability gate**

Store a small pending verification context when a protected or unexpected transition starts:

```swift
private struct PendingTransitionVerification {
    let beforeImage: CGImage
    let expectedOutcome: ExpectedOutcomeKind
}
```

This can be a local nested type in `ExamLoop.swift` for Slice 2.

After two stable consecutive frames are obtained, evaluate:

```swift
let result = outcomeVerifier.verify(
    expected: .navigation,
    before: pending.beforeImage,
    after: stableFrame.image,
    uiStable: true
)
```

Mapping:

```text
success(.navigation) -> completeBoundaryTransition()
failure(.navigationIdentityUnchanged) -> failBoundaryTransition(); keep verified current generation
pending -> keep waiting without provider call, bounded by existing non-progress/stability budget
```

Unexpected structural navigation created by a model-misclassified boundary uses the same `.navigation` verification path.

- [ ] **Step 8: Emit bounded execution/outcome events**

Add enum cases:

```swift
case actionExecuted
case outcomeVerified
case outcomePending
```

Emit static detail identifiers only, for example:

```text
action_completed
answer_mutation_verified
viewport_change_verified
navigation_verified
ui_transitioning
unexpected_structural_change
navigation_identity_unchanged
no_visible_effect
```

Do not serialize `Date`, screenshot bytes, action text/code, API payloads, or Authorization headers into `AgentEvent.detail`.

- [ ] **Step 9: Verify GREEN and commit**

```text
feat: verify semantic outcomes before lifecycle mutation
```

---

### Task 5: Regression Preservation and Full Slice Verification

**Files:**
- Modify existing tests only if needed to express explicit verifier expectations.
- Modify: `docs/superpowers/plans/2026-09-08-computer-agent-runtime-v2-slice2.md` only to check completed boxes if the execution workflow records progress in-plan.

**Interfaces:**
- Consumes all Slice 2 interfaces.
- Produces no new production API.

- [ ] **Step 1: Add regression proving both misclassified-navigation forms still fail closed**

Keep both existing tests:

```text
testMisclassifiedNavigationFromVerifiedQuestionStartsFreshUnansweredGeneration
testSingleMisclassifiedNavigationCannotCarryVerifiedStateIntoNextQuestion
```

Their assertions remain mandatory after verifier integration:

```text
new stable state -> questionGeneration increments exactly once
new stable state -> answerVerified=false
premature Next -> zero additional physical navigation clicks
```

- [ ] **Step 2: Add receipt invariant assertions to representative loop tests**

At minimum verify:

```text
dry-run -> zero receipts
cancel before action -> zero receipts
completed answer click -> one completed receipt
interrupted two-action batch -> receipt only for actions physically completed before interruption
```

- [ ] **Step 3: Run full ExamPilot CI gate**

Expected successful commands on the macOS PR runner:

```bash
cd ExamPilot
swift test
swift build -c release
```

Inspect the exact job logs. Do not treat a queued/in-progress job as success.

- [ ] **Step 4: Review warnings**

Classify every warning as one of:

```text
project/compiler warning
project/test warning
GitHub Actions infrastructure warning
```

Any new project/compiler/test warning introduced by Slice 2 is a blocker. The existing `actions/checkout@v4` Node 20 deprecation warning is infrastructure-only unless the workflow itself is changed by this slice.

- [ ] **Step 5: Compare the implementation branch against its Slice 2 base**

The expected changed surface is only:

```text
ExamPilot/Sources/ExamPilotCore/ActionExecutionReceipt.swift
ExamPilot/Sources/ExamPilotCore/OutcomeVerification.swift
ExamPilot/Sources/ExamPilotCore/Models.swift
ExamPilot/Sources/ExamPilotCore/ActionBatchPolicy.swift
ExamPilot/Sources/ExamPilotCore/ActionBatchExecutor.swift
ExamPilot/Sources/ExamPilotCore/ExamRuntimeState.swift
ExamPilot/Sources/ExamPilotCore/AgentEvent.swift
ExamPilot/Sources/ExamPilotCore/ExamLoop.swift
ExamPilot/Tests/ExamPilotCoreTests/* corresponding receipt/verifier/runtime tests
docs/superpowers/plans/2026-09-08-computer-agent-runtime-v2-slice2.md
```

No OpenAI provider request/schema file should change in this slice.

- [ ] **Step 6: Repository-wide verification gate**

When a real local macOS checkout is available:

```bash
python3 scripts/verify_all.py
```

If unavailable, state exactly why and keep the implementation PR draft. Do not substitute ExamPilot package CI for this repository-wide gate.

- [ ] **Step 7: Invoke `superpowers:verification-before-completion`**

Completion claims require fresh evidence from the final implementation head, not an earlier green commit.

- [ ] **Step 8: Request code review**

Invoke `superpowers:requesting-code-review` when a reviewer/subagent surface is available. Block integration on any Critical or Important correctness finding. If that surface is unavailable, perform and document a requirements-based self-review and do not pretend it was an independent review.

---

## Plan Self-Review

### Spec coverage for this slice

- `ActionExecutor` returns physical completion receipts with action index, state version, timestamps, and completion status: Task 1.
- Executor does not decide semantic success: Tasks 1 and 4 explicitly preserve this boundary.
- Action-specific verification replaces generic pixel-change success: Tasks 2 and 4.
- Answer mutation, viewport movement, navigation pending/stable, and no-effect failure have distinct verifier results: Task 2.
- Navigation completes only after stable-state verification: Task 4.
- Failed navigation restores the same verified generation rather than inventing a new question: Task 3 and Task 4.
- Existing model-misclassified navigation fail-closed behavior remains covered: Task 5.
- Structured observability gains execution/outcome signals without secrets/raw payloads: Task 4.
- Existing state-version and physical-input safety are preserved and covered by full suite: Task 5.

### Explicitly deferred

- Recovery strategy sequencing and repeated-intent anti-loop engine.
- `ComputerAgentSession` / working memory.
- native OpenAI Computer Use provider and response continuation.
- Accessibility/browser semantic observation fusion.
- persistent episodic/procedural memory.
- deterministic replay / NDJSON renderer.
- package extraction/rename to `ComputerAgentCore`.

### Placeholder scan

No `TODO`, `TBD`, “implement later”, or undefined cross-task interface is intentional in this plan. Deferred items are explicitly outside Slice 2 rather than placeholders inside it.

### Type consistency

- `ValidatedBatch.expectedOutcome` is introduced in Task 2 and consumed by Task 4.
- `ActionExecutionResult.receipts` is introduced in Task 1 and consumed by Task 4/5.
- `ExamRuntimeState.failBoundaryTransition()` is introduced in Task 3 and consumed by Task 4.
- `OutcomeVerifying` and `OutcomeVerifier` are introduced in Task 2 and injected into `ExamLoop` in Task 4.

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-08-computer-agent-runtime-v2-slice2.md` on `plan/computer-agent-runtime-v2-slice2`.

For this conversation, execution should use **Inline Execution** because the user explicitly requested that the next steps continue in the current session. Before production code, invoke `superpowers:executing-plans`; every task still follows the RED -> observed failure -> minimal GREEN -> CI verification sequence above.
