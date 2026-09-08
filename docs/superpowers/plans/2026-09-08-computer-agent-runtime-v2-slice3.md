# Computer Agent Runtime V2 Slice 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add classified recovery and repeated-intent loop prevention so failures re-observe/replan or wait for stability instead of blindly repeating effectively identical physical actions.

**Architecture:** Keep Slice 1 state/policy/stability invariants and Slice 2 receipts/outcome verification intact. A new stateful `RecoveryEngine` receives normalized failure reasons and privacy-preserving intent fingerprints. It never executes physical input. It returns one of a small set of bounded strategies: re-observe/replan, wait for stability, or exhausted/stop. `ExamLoop` owns integration and terminates safely when a repeated-intent budget is exhausted.

**Tech Stack:** Swift 5.10+, Swift Package Manager, XCTest, CoreGraphics/Foundation, existing `ExamRuntimeState`, `ActionBatchPolicy`, `ActionExecutionReceipt`, `OutcomeVerifier`, and GitHub Actions macOS runner.

**Spec:** `docs/superpowers/specs/2026-09-08-computer-agent-runtime-v2-design.md`

## Global Constraints

- Runtime correctness remains independent from provider/model claims.
- Recovery MUST NOT directly invoke `InputDriving` or `ActionBatchExecutor`.
- Blind physical retry is forbidden. A new physical attempt requires a new provider turn from fresh observation or another future semantic targeting source.
- Repeated-intent detection must not include `stateVersion`, because accepted re-observations monotonically advance state version and would otherwise defeat loop detection.
- Intent fingerprints must not retain raw typed text, code, provider summaries, screenshots, credentials, Authorization headers, or request payloads.
- Click coordinates use coarse deterministic buckets so near-identical click jitter counts as the same intent.
- Navigation remains illegal while the current question is not verified.
- Existing misclassified-navigation, stability, semantic verification, receipt, focus, cancellation, and stale-state invariants remain mandatory.
- No provider schema change, Accessibility/DOM/CDP, persistent memory, session abstraction, replay CLI, package rename, or new external dependency in this slice.
- Required package gates: `cd ExamPilot && swift test && swift build -c release`.
- Repository-wide `python3 scripts/verify_all.py` remains required when a real local macOS checkout is available.

---

## File Structure

### New production files

- `ExamPilot/Sources/ExamPilotCore/RecoveryEngine.swift`
  - Failure taxonomy, privacy-preserving intent fingerprint, bounded strategy selection, repeated-intent budget.

### Modified production files

- `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`
  - Add `recoveryPlanned` and `recoveryExhausted` event kinds.
- `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
  - Normalize runtime failures into `AgentFailureReason`, feed them to `RecoveryEngine`, terminate safely on exhaustion, clear counters on proven success.

### New/modified tests

- Create `ExamPilot/Tests/ExamPilotCoreTests/RecoveryEngineTests.swift`
- Create `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopRecoveryTests.swift`
- Modify `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`
- Modify existing loop tests only where they need explicit bounded-recovery expectations.

---

### Task 1: Privacy-Preserving Intent Fingerprints

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/RecoveryEngine.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/RecoveryEngineTests.swift`

**Interfaces:**
- Consumes: `ExamDecision`, `ExamAction`, `ExamActionKind`, current `questionGeneration`.
- Produces:
  - `ActionIntentToken`
  - `AgentIntentFingerprint`
  - `AgentIntentFingerprint.init(decision:questionGeneration:coordinateBucketSize:)`

- [ ] **Step 1: Write RED tests**

```swift
import XCTest
@testable import ExamPilotCore

final class RecoveryEngineTests: XCTestCase {
    func testNearbyClickCoordinatesProduceSameIntentFingerprint() {
        let a = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "ignored",
                expectsVisualChange: true,
                actions: [.moveClick(x: 100, y: 200, boundary: true)]
            ),
            questionGeneration: 2,
            coordinateBucketSize: 8
        )
        let b = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "also ignored",
                expectsVisualChange: true,
                actions: [.moveClick(x: 103, y: 207, boundary: true)]
            ),
            questionGeneration: 2,
            coordinateBucketSize: 8
        )

        XCTAssertEqual(a, b)
    }

    func testDifferentQuestionGenerationProducesDifferentFingerprint() {
        let decision = ExamDecision(summary: "next", expectsVisualChange: true, actions: [.moveClick(x: 100, y: 200, boundary: true)])
        XCTAssertNotEqual(
            AgentIntentFingerprint(decision: decision, questionGeneration: 2),
            AgentIntentFingerprint(decision: decision, questionGeneration: 3)
        )
    }

    func testFingerprintDoesNotRetainTypedTextOrSummary() {
        let fingerprint = AgentIntentFingerprint(
            decision: ExamDecision(
                summary: "secret summary",
                expectsVisualChange: true,
                actions: [.typeText("private-answer")]
            ),
            questionGeneration: 1
        )
        let text = String(describing: fingerprint)
        XCTAssertFalse(text.contains("secret summary"))
        XCTAssertFalse(text.contains("private-answer"))
    }
}
```

- [ ] **Step 2: Verify RED in CI**

Expected compile failure: `AgentIntentFingerprint` does not exist.

- [ ] **Step 3: Implement fingerprint types**

```swift
public struct ActionIntentToken: Hashable, Codable {
    public let kind: ExamActionKind
    public let xBucket: Int?
    public let yBucket: Int?
    public let boundary: Bool
}

public struct AgentIntentFingerprint: Hashable, Codable {
    public let questionGeneration: UInt64
    public let actions: [ActionIntentToken]

    public init(
        decision: ExamDecision,
        questionGeneration: UInt64,
        coordinateBucketSize: Int = 8
    ) {
        let bucketSize = max(1, coordinateBucketSize)
        self.questionGeneration = questionGeneration
        self.actions = decision.actions.map { action in
            ActionIntentToken(
                kind: action.kind,
                xBucket: action.x.map { Int(floor($0 / Double(bucketSize))) },
                yBucket: action.y.map { Int(floor($0 / Double(bucketSize))) },
                boundary: action.boundary
            )
        }
    }
}
```

The fingerprint intentionally excludes summary, text, key value, screenshot content, state version, and provider payloads.

- [ ] **Step 4: Verify GREEN and commit**

Commit: `feat: add privacy-preserving intent fingerprints`

---

### Task 2: Failure Taxonomy and Bounded Recovery Engine

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/RecoveryEngine.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/RecoveryEngineTests.swift`

**Interfaces:**
- Produces:
  - `AgentFailureReason`
  - `RecoveryStrategy`
  - `RecoveryDecision`
  - `RecoveryEngine.handle(failure:intent:)`
  - `RecoveryEngine.recordSuccess(intent:)`

- [ ] **Step 1: Write RED tests for bounded repeated intents**

```swift
func testSameIntentExhaustsOnThirdFailure() {
    let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
    let intent = makeNextIntent()

    XCTAssertEqual(engine.handle(failure: .invalidModelPlan, intent: intent), .recover(strategy: .reobserveAndReplan, attempt: 1))
    XCTAssertEqual(engine.handle(failure: .invalidModelPlan, intent: intent), .recover(strategy: .reobserveAndReplan, attempt: 2))
    XCTAssertEqual(engine.handle(failure: .invalidModelPlan, intent: intent), .exhausted(reason: .repeatedIntentLoop))
}

func testChangedIntentHasIndependentBudget() {
    let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
    let first = makeIntent(x: 100)
    let changed = makeIntent(x: 180)
    _ = engine.handle(failure: .noVisibleEffect, intent: first)
    _ = engine.handle(failure: .noVisibleEffect, intent: first)

    XCTAssertEqual(
        engine.handle(failure: .noVisibleEffect, intent: changed),
        .recover(strategy: .reobserveAndReplan, attempt: 1)
    )
}

func testTransitionFailureWaitsInsteadOfReplanning() {
    let engine = RecoveryEngine()
    XCTAssertEqual(
        engine.handle(failure: .transitionStillRunning, intent: makeNextIntent()),
        .recover(strategy: .waitForStability, attempt: 1)
    )
}

func testSuccessClearsRepeatedIntentBudget() {
    let engine = RecoveryEngine(maxRepeatedIntentAttempts: 3)
    let intent = makeNextIntent()
    _ = engine.handle(failure: .noVisibleEffect, intent: intent)
    _ = engine.handle(failure: .noVisibleEffect, intent: intent)
    engine.recordSuccess(intent: intent)
    XCTAssertEqual(
        engine.handle(failure: .noVisibleEffect, intent: intent),
        .recover(strategy: .reobserveAndReplan, attempt: 1)
    )
}
```

- [ ] **Step 2: Verify RED**

Expected: recovery types/engine missing.

- [ ] **Step 3: Implement failure taxonomy and engine**

```swift
public enum AgentFailureReason: String, Codable, Equatable {
    case targetMiss
    case noVisibleEffect
    case staleObservation
    case transitionStillRunning
    case focusDrift
    case stateMismatch
    case invalidModelPlan
    case repeatedIntentLoop
    case targetNotVisible
    case unknown
}

public enum RecoveryStrategy: String, Codable, Equatable {
    case reobserveAndReplan
    case waitForStability
}

public enum RecoveryDecision: Equatable {
    case recover(strategy: RecoveryStrategy, attempt: Int)
    case exhausted(reason: AgentFailureReason)
}

public final class RecoveryEngine {
    private let maxRepeatedIntentAttempts: Int
    private var attempts: [AgentIntentFingerprint: Int] = [:]

    public init(maxRepeatedIntentAttempts: Int = 3) {
        self.maxRepeatedIntentAttempts = max(1, maxRepeatedIntentAttempts)
    }

    public func handle(
        failure: AgentFailureReason,
        intent: AgentIntentFingerprint
    ) -> RecoveryDecision {
        let next = min(Int.max, (attempts[intent] ?? 0) + 1)
        attempts[intent] = next
        if next >= maxRepeatedIntentAttempts {
            return .exhausted(reason: .repeatedIntentLoop)
        }
        return .recover(strategy: strategy(for: failure), attempt: next)
    }

    public func recordSuccess(intent: AgentIntentFingerprint) {
        attempts.removeValue(forKey: intent)
    }

    private func strategy(for failure: AgentFailureReason) -> RecoveryStrategy {
        switch failure {
        case .transitionStillRunning:
            return .waitForStability
        case .targetMiss, .noVisibleEffect, .staleObservation, .focusDrift,
             .stateMismatch, .invalidModelPlan, .repeatedIntentLoop,
             .targetNotVisible, .unknown:
            return .reobserveAndReplan
        }
    }
}
```

- [ ] **Step 4: Verify GREEN and commit**

Commit: `feat: add bounded recovery engine`

---

### Task 3: Recovery Telemetry Contract

**Files:**
- Modify: `ExamPilot/Sources/ExamPilotCore/AgentEvent.swift`
- Modify: `ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift`

**Interfaces:**
- Adds `AgentEventKind.recoveryPlanned` and `.recoveryExhausted`.

- [ ] **Step 1: Write RED event test**

```swift
func testRecoveryEventsUseBoundedIdentifiersOnly() throws {
    let planned = AgentEvent(
        kind: .recoveryPlanned,
        cycle: 3,
        stateVersion: 9,
        questionGeneration: 2,
        detail: "reobserve_and_replan"
    )
    let exhausted = AgentEvent(
        kind: .recoveryExhausted,
        cycle: 4,
        stateVersion: 10,
        questionGeneration: 2,
        detail: "repeated_intent_loop"
    )
    let encoded = try JSONEncoder().encode([planned, exhausted])
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertTrue(text.contains("recoveryPlanned"))
    XCTAssertTrue(text.contains("recoveryExhausted"))
    XCTAssertFalse(text.lowercased().contains("authorization"))
}
```

- [ ] **Step 2: Verify RED**

Expected enum cases missing.

- [ ] **Step 3: Add event kinds**

```swift
case recoveryPlanned
case recoveryExhausted
```

- [ ] **Step 4: Verify GREEN and commit**

Commit: `feat: add structured recovery events`

---

### Task 4: Integrate Recovery Into ExamLoop

**Files:**
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopRecoveryTests.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`

**Interfaces:**
- `ExamLoop.init(... recoveryEngine: RecoveryEngine = RecoveryEngine())`
- Computes `AgentIntentFingerprint` immediately after provider decision using current `questionGeneration`.
- Normalizes failure branches into `AgentFailureReason`.

- [ ] **Step 1: RED test repeated protected-boundary proposal**

```swift
func testRepeatedPrematureNavigationStopsWithoutPhysicalInput() async throws {
    let frame = try makeFrame(gray: 0.4)
    let capture = QueueCapture(frames: Array(repeating: frame, count: 8))
    let agent = QueueAgent(decisions: (0..<3).map { _ in
        ExamDecision(summary: "next", expectsVisualChange: true, actions: [.moveClick(x: 90, y: 90, boundary: true)])
    })
    let driver = RecordingDriver()
    let events = RecordingEventSink()
    let loop = ExamLoop(
        capture: capture,
        visionAgent: agent,
        executor: ActionBatchExecutor(driver: driver),
        eventSink: events,
        dryRun: false,
        maxCycles: 10
    )

    XCTAssertEqual(await loop.run(), .nonProgress(cycles: 3))
    XCTAssertTrue(driver.clicks.isEmpty)
    XCTAssertTrue(events.events.contains { $0.kind == .recoveryExhausted && $0.detail == "repeated_intent_loop" })
}
```

- [ ] **Step 2: RED test repeated no-effect physical intent**

Use unchanged frames and the same non-boundary answer click three times. Assert:

```text
three provider turns maximum
three physical clicks maximum
fourth physical click never occurs
result == nonProgress(cycles: 3)
recoveryExhausted/repeated_intent_loop emitted
```

- [ ] **Step 3: RED test changed target is not same loop**

Use two no-effect failures at x=10 followed by x=80. Assert the third provider turn is allowed its own recovery budget and no premature exhaustion occurs.

- [ ] **Step 4: Verify RED**

Expected: current loop has only global `maxNonProgress`; protected-boundary denial resets non-progress and can repeat indefinitely until max cycles.

- [ ] **Step 5: Inject engine and fingerprint provider turns**

Add:

```swift
private let recoveryEngine: RecoveryEngine
```

and initializer parameter with default `RecoveryEngine()`.

After `visionAgent.decide(...)`:

```swift
let intent = AgentIntentFingerprint(
    decision: decision,
    questionGeneration: runtimeState.questionGeneration
)
```

- [ ] **Step 6: Centralize recovery application**

Add a private helper in `ExamLoop`:

```swift
private func recoveryDecision(
    failure: AgentFailureReason,
    intent: AgentIntentFingerprint,
    cycle: Int,
    state: ExamRuntimeState
) -> RecoveryDecision {
    let decision = recoveryEngine.handle(failure: failure, intent: intent)
    switch decision {
    case .recover(let strategy, _):
        recordEvent(
            .recoveryPlanned,
            cycle: cycle,
            state: state,
            detail: strategy == .waitForStability ? "wait_for_stability" : "reobserve_and_replan"
        )
    case .exhausted:
        recordEvent(
            .recoveryExhausted,
            cycle: cycle,
            state: state,
            detail: "repeated_intent_loop"
        )
    }
    return decision
}
```

Do not pass summaries, text, coordinates, or screenshots into event detail.

- [ ] **Step 7: Map runtime failures**

At minimum:

```text
protectedBoundaryBeforeAnswer -> invalidModelPlan
other ActionValidationError -> invalidModelPlan
stale state-version guards -> staleObservation
Outcome failure noVisibleEffect -> noVisibleEffect
navigationIdentityUnchanged -> stateMismatch
stability sample budget exhaustion -> transitionStillRunning
```

On `.exhausted`, return `.nonProgress(cycles: cycles)` with no new physical action.

On a proven outcome success (`answerMutation`, `viewportChange`, verified navigation), call:

```swift
recoveryEngine.recordSuccess(intent: intent)
```

For verified navigation, keep the intent in the pending transition context so success can clear the correct fingerprint after stability verification.

- [ ] **Step 8: Verify GREEN and commit**

Commit: `feat: prevent repeated intent loops`

---

### Task 5: Full Slice Verification

**Files:**
- No new production API expected.

- [ ] **Step 1: Run full ExamPilot gate in PR CI**

```bash
cd ExamPilot
swift test
swift build -c release
```

Require exact completed success, not queued/in-progress status.

- [ ] **Step 2: Confirm mandatory old regressions**

At minimum confirm pass for:

```text
testUnansweredQuestionCannotBeSkippedAfterNavigatingFromAnsweredQuestion
testUnansweredSecondQuestionCannotPhysicallyNavigate
testMisclassifiedNavigationFromVerifiedQuestionStartsFreshUnansweredGeneration
testSingleMisclassifiedNavigationCannotCarryVerifiedStateIntoNextQuestion
testStableNavigationIdentityUnchangedDoesNotAdvanceGeneration
testInterruptedBatchPreservesOnlyCompletedActionReceipts
```

- [ ] **Step 3: Warning classification**

Any new Swift/compiler/test warning is blocker. Existing `actions/checkout@v4` Node 20 deprecation is infrastructure-only unless this slice changes workflow files.

- [ ] **Step 4: Diff/scope review**

Expected production surface:

```text
ExamPilot/Sources/ExamPilotCore/RecoveryEngine.swift
ExamPilot/Sources/ExamPilotCore/AgentEvent.swift
ExamPilot/Sources/ExamPilotCore/ExamLoop.swift
ExamPilot/Tests/ExamPilotCoreTests/RecoveryEngineTests.swift
ExamPilot/Tests/ExamPilotCoreTests/ExamLoopRecoveryTests.swift
ExamPilot/Tests/ExamPilotCoreTests/AgentEventTests.swift
docs/superpowers/plans/2026-09-08-computer-agent-runtime-v2-slice3.md
```

No OpenAI provider, capture, focus, native input, package manifest, or workflow file should change.

- [ ] **Step 5: Repository-wide verification when available**

```bash
python3 scripts/verify_all.py
```

If local macOS tools remain unavailable, state that explicitly and leave the implementation PR draft.

- [ ] **Step 6: Invoke `superpowers:verification-before-completion`**

Use fresh final-head evidence.

---

## Plan Self-Review

### Spec coverage

- Failure taxonomy: Task 2.
- Bounded changed-hypothesis recovery: Task 2 and Task 4.
- Repeated intent loop detection: Task 1, Task 2, Task 4.
- No blind physical retries: Global constraints and Task 4 integration.
- Transition-still-running waits rather than physical mutation: Task 2/4.
- Structured recovery observability without secrets: Task 3/4.
- Existing correctness invariants retained: Task 5.

### Explicitly deferred

- `ComputerAgentSession` and working memory.
- Native OpenAI Computer Use provider and `previous_response_id` continuation.
- Accessibility/browser observation fusion.
- Persistent episodic/procedural memory.
- Deterministic replay/NDJSON renderer and local browser fixture benchmark.
- Package extraction/rename toward `ComputerAgentCore`.

### Placeholder scan

No TODO/TBD or undefined later interface is intentionally left in this plan.

### Type consistency

- `AgentIntentFingerprint` is created in Task 1, consumed by `RecoveryEngine` in Task 2 and `ExamLoop` in Task 4.
- `AgentFailureReason`, `RecoveryStrategy`, and `RecoveryDecision` are defined in Task 2 before loop integration.
- Recovery telemetry event kinds are introduced in Task 3 before loop emission in Task 4.

## Execution Handoff

Execution is inline in this conversation because the user explicitly instructed development to continue through the remaining slices. Apply each task using RED -> observed failure -> minimal GREEN -> fresh CI verification.