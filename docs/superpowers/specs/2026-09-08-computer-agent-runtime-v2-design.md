# Computer Agent Runtime V2 Design

Date: 2026-09-08
Status: Approved design, awaiting implementation-plan approval
Branch: `design/computer-agent-runtime-v2`

## 1. Purpose

Evolve the existing `ExamPilot` visual macOS computer-use agent into a reliable, stateful, reusable Computer Agent runtime while preserving the native ScreenCaptureKit and CoreGraphics execution strengths already present in the repository.

The immediate regression target is the observed live-run failure where ExamPilot answered the first question, navigated to subsequent questions, and repeatedly attempted `Next Question` without answering the newly displayed question. The design must eliminate this entire class of failure at the runtime-policy layer rather than by prompt wording or blind click retries.

The resulting runtime must remain useful beyond exams: browser workflows, form completion, UI testing, desktop application control, and later multi-step user-directed automation should reuse the same observe-understand-act-verify core.

## 2. Current State and Confirmed Gaps

The existing ExamPilot package already provides valuable primitives and they should not be regressed:

- focused Chrome-window capture through ScreenCaptureKit with fallback selection;
- process identity continuity and pre-input focus verification;
- native CoreGraphics mouse, keyboard, and scroll input;
- bounded physical input and emergency stop handling;
- strict structured model output;
- action-batch validation and stale-batch interruption after structural UI change;
- visual post-action progress detection;
- dry-run isolation.

However, the current runtime has four architectural gaps relevant to the observed failure:

1. `ExamObservationState` carries only cycle count, non-progress count, and the previous summary. It does not represent question identity, answer lifecycle, navigation eligibility, UI transition state, or action/state versioning.
2. Visual progress detection treats sufficient pixel-level difference as progress. It does not prove that a new question is fully rendered, that an answer was committed, or that navigation reached the intended semantic state.
3. The provider currently makes independent planning requests for each screenshot and preserves only a compact textual summary, not a durable agent reasoning/session state.
4. Tests verify stale-action interruption after navigation, but do not enforce the invariant that an unanswered current question cannot be skipped by a navigation action.

A separate local-run log also showed `retrying final click #...` messages. Those strings are not present in the current GitHub `main` ExamPilot executor/input code inspected during design. This is treated as an environment/version discrepancy to diagnose during implementation, not as an assumed root cause.

## 3. Design Principles

### 3.1 Runtime correctness is not delegated to the model

The model proposes intent and actions. It does not directly define executable truth.

- `WorldState` describes observed reality.
- `StateMachine` defines legal transitions.
- `ActionPolicy` decides whether a proposed action is executable.
- `ActionExecutor` is the only component that touches the computer.
- `OutcomeVerifier` determines whether an action actually succeeded.

A model statement such as "the question is answered" never mutates runtime truth by itself.

### 3.2 Fail closed on uncertain physical mutation

If the observation is stale, the target is ambiguous, focus changed, UI is unstable, state transition is illegal, or verification is inconclusive, the runtime must not perform the physical mutation. It re-observes, waits, retargets, or escalates recovery instead.

### 3.3 Human-native execution remains first-class

Vision, Accessibility, and browser semantics are sensors and targeting aids. Native macOS mouse, keyboard, and scroll remain the default mutation path for the human-native profile. The architecture may later support accelerated semantic actions as an explicit mode, but semantic sensors must not silently bypass runtime policy.

### 3.4 Learning cannot rewrite hard invariants

Memory may influence strategy ranking, recovery choices, and planner context. It may not weaken or mutate safety/correctness policy such as stale-state rejection or unanswered-question navigation denial.

## 4. Target Architecture

```text
User Goal
   |
   v
ComputerAgentSession
   |
   +-- WorkingMemory
   +-- PersistentMemory
   +-- ProviderConversationState
   |
   v
ObservationEngine
   +-- Vision / ScreenCaptureKit
   +-- Accessibility sensor
   +-- Browser semantic hints (optional)
   |
   v
WorldState
   |
   v
StateMachine
   |
   v
ComputerAgentProvider
   |
   v
ProposedActions
   |
   v
ActionPolicy
   |
   v
ActionExecutor
   |
   v
OutcomeVerifier
   |
   +-- success -> memory -> next observation
   +-- failure -> RecoveryEngine -> next observation / terminal stop
```

## 5. Core Components

### 5.1 `ComputerAgentSession`

Owns one user-directed task from start to terminal result.

Required session state:

- stable session ID;
- user goal/task profile;
- provider conversation state, including OpenAI response continuity where supported;
- current `WorldState`;
- monotonic `stateVersion`;
- working memory;
- recent action and failure history;
- persistent-memory handle;
- stop/cancellation state.

The session orchestrates components but must not contain sensor-specific parsing or low-level input logic.

### 5.2 `ObservationEngine`

Produces an immutable observation snapshot.

An observation includes:

- screenshot and capture geometry;
- target process/window identity;
- timestamp;
- cursor position when available;
- focused Accessibility element/window information;
- optional normalized Accessibility tree hints;
- optional browser semantic hints;
- UI stability status;
- observation ID and derived `stateVersion`.

Sensors are read-only. They do not execute actions.

### 5.3 `WorldState`

Normalizes observations into state the runtime can reason about deterministically.

For the exam task profile it includes at minimum:

- application/window identity;
- UI lifecycle state: unknown, observing, transitioning, stable, terminal;
- question identity/fingerprint;
- question type when confidently known;
- whether the current question is answered, with evidence;
- visible controls/targets and confidence;
- whether navigation is currently allowed;
- current state version.

Question identity should combine visual and semantic evidence so that navigation success is not inferred from generic pixel change alone.

### 5.4 `StateMachine`

The exam-profile lifecycle is:

```text
unknown
 -> observing
 -> questionReady
 -> solving
 -> answerPlanned
 -> answering
 -> answerVerified
 -> navigationReady
 -> navigating
 -> awaitingNextState
 -> questionReady
```

A transition is accepted only when its prerequisites are proven by runtime evidence.

Hard invariant for the exam profile:

> Navigation to another question is illegal while the current question is known and not verified as answered.

This invariant applies regardless of model confidence or repeated model requests.

### 5.5 `ComputerAgentProvider`

Provider abstraction:

```swift
protocol ComputerAgentProvider {
    func nextStep(
        observation: AgentObservation,
        state: AgentRuntimeState
    ) async throws -> AgentTurn
}
```

Initial implementations:

1. `OpenAIComputerUseProvider`: preferred provider when the configured model/API surface supports native Computer Use and response continuation.
2. `StructuredVisionProvider`: fallback/evolution of the current strict JSON-schema screenshot planner.

The OpenAI implementation should preserve multi-turn provider context through the supported Responses continuation mechanism rather than treating every observation as an unrelated request.

Provider adapters produce proposals, never validated executable actions.

### 5.6 `ActionPolicy`

Acts as the correctness and safety firewall between model intent and physical input.

Checks include:

- proposal `stateVersion` equals the current state version;
- captured window/process identity remains valid;
- current UI is stable enough for the action type;
- coordinates/targets are inside the valid target surface;
- action-specific fields are valid and bounded;
- current lifecycle permits the action;
- navigation prerequisites are satisfied;
- the intent is not an identical blind retry loop;
- stop/cancellation has not been requested.

Policy returns a `ValidatedAction` or a structured denial reason. A denial never reaches physical input.

### 5.7 `ActionExecutor`

Reuses and evolves the current native input stack.

The executor must:

- preserve paired mouse/key down-up safety;
- remain cancellation-aware inside long operations;
- avoid clipboard dependence in the human-native profile;
- return an `ActionExecutionReceipt` containing action ID, timestamps, physical completion status, and expected outcome reference.

It must not decide whether the action was semantically successful.

### 5.8 `OutcomeVerifier`

Verification is semantic and action-specific rather than generic "pixels changed".

Inputs:

- validated action;
- expected outcome;
- world state before action;
- post-action observation(s).

Examples:

- answer selection: the same question remains visible and selected-state evidence changed as expected;
- text/code entry: the target region/state contains convincing edit evidence;
- navigation: UI becomes stable and question identity changes from the previous question;
- transition/loading: result is `pending`, not `success`;
- no effect: result is a classified failure.

Pixel-difference detection remains useful as one signal, not as the semantic success definition.

### 5.9 `UIStabilityDetector`

Boundary actions no longer rely on one fixed sleep followed by reasoning.

The detector samples bounded consecutive observations until:

- the UI is sufficiently stable for reasoning;
- the configured stability timeout is reached;
- cancellation occurs.

Loading spinners, layout shifts, partial navigation, and editor reflow therefore do not automatically become a new reasoning cycle.

### 5.10 `RecoveryEngine`

Failures are classified before retry.

Initial failure classes:

- target miss;
- no visible effect;
- stale observation;
- transition still running;
- focus drift;
- state mismatch;
- invalid model plan;
- repeated intent loop;
- target not visible;
- unknown failure.

Recovery must change the hypothesis or information source. A valid strategy sequence may be:

1. original vision target;
2. fresh observation plus semantic/Accessibility retarget;
3. full replan from current state.

Repeating effectively identical coordinates or intent without new evidence is not an acceptable retry strategy.

After the bounded strategy budget is exhausted, control returns to the higher-level planner or the session terminates safely.

## 6. State Versioning and Stale-Action Prevention

Every accepted observation produces a monotonic `stateVersion`.

Each proposal is bound to that version. Before physical execution:

```text
proposal.stateVersion == session.currentStateVersion
```

must hold.

If any observation, focus change, structural change, or accepted transition advances the state version, old proposals become non-executable.

This converts coordinate freshness from an implicit timing assumption into an explicit runtime contract.

## 7. Memory and Learning

### 7.1 Working memory

Session-local and immediately available:

- current/previous question state;
- recent actions;
- recent failures;
- successful evidence;
- provider state;
- current recovery strategy.

### 7.2 Episodic memory

Persist meaningful interaction episodes:

- observation/world-state context;
- proposed action;
- policy decision;
- executed action, if any;
- expected outcome;
- verification result;
- failure reason;
- recovery strategy;
- resulting state.

### 7.3 Procedural/semantic memory

Store reusable strategy candidates with context and evidence:

- context fingerprint;
- strategy identifier;
- success/failure counts;
- confidence;
- recency.

Retrieval ranks by application/task/UI similarity, semantic similarity, historical success, and recency. Vector similarity alone is insufficient.

### 7.4 Storage

Initial production implementation should be local-first SQLite behind an `AgentMemoryStore` protocol, with tables conceptually equivalent to:

- sessions;
- episodes;
- learned strategies;
- semantic embeddings/indices.

Existing ZeroLose vector-store/retrieval code may be reused as a reference or extracted carefully where appropriate, but ExamPilot/ComputerAgentCore must not gain an accidental hard dependency on the ZeroLose UI target.

Diagnostic screenshots are not persisted by default. Persist structured state and hashes; optional bounded snapshots are enabled only in diagnostics mode.

## 8. Observability and Replay

### 8.1 Structured events

Replace ad-hoc retry strings with structured agent events containing:

- session ID;
- cycle/observation ID;
- state version;
- task/question identity when applicable;
- event type;
- proposed/executed intent;
- policy result;
- verification result;
- recovery reason/strategy.

Human-readable terminal logs are rendered from the same event model. NDJSON output should be available for tooling/replay.

Secrets, Authorization headers, API keys, and raw base64 request payloads must never be logged.

### 8.2 Deterministic replay

A recorded session can be replayed without physical input and without requiring a live model when recorded provider turns are available.

Replay should make it possible to isolate whether a regression came from:

- observation normalization;
- state-machine logic;
- provider proposal;
- policy validation;
- verifier logic;
- recovery policy.

Replay mode always uses a non-mutating executor.

## 9. Testing Strategy

### 9.1 Unit tests

Deterministic coverage for:

- state-machine transitions;
- unanswered-question navigation denial;
- state-version stale proposal rejection;
- UI stability thresholds/timeouts;
- action policy bounds;
- failure classification;
- recovery strategy progression;
- repeated-intent loop detection;
- memory ranking rules;
- structured event redaction.

### 9.2 Regression test for the reported failure

The mandatory regression sequence is:

1. Q1 is answered and verified.
2. Navigation to Q2 succeeds.
3. Q2 is stable, visible, and unanswered.
4. Provider proposes `Next Question` before answering Q2.
5. `ActionPolicy` denies the proposal.
6. Physical navigation action count remains zero.
7. Runtime re-observes/replans Q2.

This is a hard deterministic test independent of model quality.

### 9.3 Scenario/integration tests

Create controlled local browser fixtures covering:

- single choice;
- multi choice;
- text input;
- textarea;
- code editor;
- scrolling;
- always-visible Next button;
- answer-dependent Next button;
- delayed render/loading spinner;
- layout shift;
- modal interruption;
- focus drift;
- second Chrome window;
- moving targets;
- duplicate button labels;
- multilingual navigation labels;
- final page.

### 9.4 Real-input benchmark

A local benchmark page opened in Chrome exercises the actual ScreenCaptureKit, focus verification, Retina coordinate mapping, and native HID input path.

Real model + real Chrome runs are manual/nightly benchmarks, not per-commit deterministic CI gates.

### 9.5 Existing gates

The existing package checks remain required:

```bash
cd ExamPilot
swift test
swift build -c release
```

Repository-wide verification remains required when the local macOS checkout permits it:

```bash
python3 scripts/verify_all.py
```

## 10. Acceptance Criteria

### 10.1 Runtime-correctness invariants

The following must remain zero in deterministic tests and controlled benchmarks:

- unanswered-question navigation violations;
- stale actions physically executed;
- actions applied to the wrong Chrome window;
- actions executed after a state-changing boundary using an old state version;
- unpaired mouse/key down events;
- blind identical retry loops;
- physical input after stop has been acknowledged at the next safe event boundary.

### 10.2 Capability metrics

Track separately from correctness:

- scenario completion rate;
- answer/task accuracy;
- action efficiency;
- recovery success rate;
- average replans;
- provider round trips;
- time to completion.

Model/provider comparisons use these metrics rather than subjective impressions.

## 11. Error Model

Component failures are normalized into runtime classes:

- `retryable`: transient provider/network/capture failures where the same logical operation may safely retry with backoff;
- `recoverable`: state/focus/transition failures requiring re-observation or strategy change;
- `terminal`: missing permissions, exhausted recovery, unrecoverable configuration failure;
- `cancelled`: explicit stop request.

Blind retries are forbidden for physical mutations. Physical retry requires a changed hypothesis, fresh evidence, or alternate targeting source.

## 12. Migration Strategy

Implementation proceeds incrementally without discarding the current working native primitives.

Recommended order:

1. add structured trace/events and deterministic regression reproduction;
2. introduce `WorldState`, state versioning, and exam lifecycle state machine;
3. add `ActionPolicy` navigation and stale-state invariants;
4. add UI stability detection;
5. introduce action receipts and semantic outcome verification;
6. add classified recovery and anti-loop behavior;
7. introduce `ComputerAgentSession` and working memory;
8. add native OpenAI Computer Use provider with provider-session continuation, preserving structured-vision fallback;
9. add Accessibility/browser observation fusion;
10. add persistent episodic/procedural memory;
11. add local browser benchmark and deterministic replay tooling;
12. extract/rename reusable runtime boundaries toward `ComputerAgentCore` once behavior is stable.

Do not rename or broadly reorganize the package before the behavior and regression suite are stable.

## 13. Security and Scope

The runtime is for user-authorized automation and testing. It does not add anti-proctoring, stealth/evasion, CAPTCHA bypass, monitoring defeat, arbitrary shell execution, or hidden credential extraction.

Computer-use mutations remain bounded by explicit runtime policy, focus/window continuity, and cancellation checks.

## 14. Non-Goals for This Implementation Cycle

- cross-platform Windows/Linux support;
- autonomous self-modification of runtime policy;
- arbitrary plugin/tool execution from model output;
- cloud-hosted memory service;
- generalized sub-agent delegation;
- scheduled/background tasks;
- replacing the ZeroLose product architecture;
- removing the existing structured-vision provider before the native provider is proven.

These can be separate design/spec cycles after the core runtime is reliable.

## 15. Definition of Done for the First Implementation Plan

The first implementation plan is complete only when it can demonstrate the reported regression deterministically:

- after Q1 navigation, Q2 is recognized as a distinct stable unanswered question;
- a premature `Next Question` proposal for Q2 is denied before physical input;
- the runtime replans/answers Q2;
- navigation becomes legal only after answer verification;
- tests prove no stale or blind repeated click crosses the runtime policy boundary;
- current ExamPilot unit tests and release build remain green;
- repository verification is run and reported when locally available.
