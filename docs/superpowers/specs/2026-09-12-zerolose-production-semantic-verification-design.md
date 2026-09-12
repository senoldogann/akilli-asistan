# ZeroLose Production Semantic Verification Design

**Date:** 2026-09-12

## 1. Purpose

ZeroLose Agent mode now has an authoritative `AgentOrchestrator`, persistent task graph, Tool Fabric/Policy Kernel routing, restart/reconciliation, session controls, and Emergency Stop. The remaining production gap is verification: the current container deliberately injects `FailClosedAgentTaskVerifier` and `FailClosedAgentGoalVerifier`, so the runtime can execute approved work but cannot safely promote that work to verified task or goal success.

This design replaces those placeholders with a verification pipeline that proves effects independently from provider claims and tool receipts. It reuses the existing ExamPilot semantic outcome verification primitives instead of duplicating visual-diff logic.

## 2. Safety Invariants

The implementation must preserve these invariants:

1. A provider final-text claim is never sufficient for task or goal success.
2. A `ToolExecutionReceipt` proves only that the provider/gateway completed an invocation; it does not prove the intended real-world effect.
3. Every mutation task must have an explicit expected semantic outcome before physical execution.
4. Mutation verification must compare a trusted pre-action observation with a fresh post-action observation from the same authoritative target identity.
5. An unavailable, stale, ambiguous, unsupported, or inconclusive verification path fails closed.
6. Goal completion requires independently verified evidence from every task that is required for that goal.
7. Unknown verification-contract kinds are rejected, never interpreted as success.
8. Verification cannot bypass Tool Fabric, Policy Kernel, the computer mutation adapter, or the existing Emergency Stop path.
9. Verification evidence must remain bounded, provenance-carrying, and free of credential material.
10. Existing ExamPilot safety and outcome-verification behavior must remain unchanged.

## 3. Existing Gap

`TaskRuntime` currently reduces an execution result to `[VerificationEvidence]` before calling `TaskVerifying`. This is sufficient for test fakes that directly return `.evidence(...)`, but production `AgentToolInvocationExecutor` returns `.toolReceipt(...)`, whose `verificationEvidence` is intentionally empty.

That means a production verifier cannot distinguish:

- which verification contract applied;
- which tool receipt was produced;
- which observation existed before the mutation;
- which observation exists after it;
- what semantic outcome the planner expected;
- whether the visible state actually changed in the expected way.

The contract therefore needs a bounded execution artifact rather than a lossy evidence-only array.

## 4. Verification Intent

### 4.1 Planned verification expectation

`PlannedToolInvocation` will carry a typed verification expectation in addition to the tool ID and argument JSON.

The expectation is planner-owned intent, not proof. It tells the verifier what observable outcome would make the task successful.

Supported initial expectations:

- `readResult` — the task is satisfied by a successful, structurally valid read-only tool result.
- `computerNone` — a computer action is intentionally observationally neutral, such as a bounded wait.
- `computerAnswerMutation` — visible state near the interaction target must change without a structural navigation.
- `computerViewportChange` — the viewport must materially change.
- `computerNavigation` — stable navigation identity must materially change.

The planner must emit an expectation compatible with the selected descriptor's `VerificationContract`. Missing or incompatible expectations are invalid planning output and fail before execution.

The initial design deliberately avoids generic free-form verification strings. The execution/runtime boundary uses a closed enum so unsupported semantics cannot silently become successful.

### 4.2 Runtime-owned computer freshness binding

`stateVersion` and `observationID` are runtime authority data, not model intent. The planner may choose the computer action arguments and expected semantic outcome, but it must not invent freshness tokens.

Before a computer mutation enters Tool Fabric, the runtime obtains one authoritative pre-action observation and binds its `stateVersion` and `observationID` into the invocation arguments. The same bound values are the ones later validated by `MacOSComputerMutationAdapter`. If the planner supplies either field, the runtime rejects the proposal rather than trusting or silently overwriting model-generated authority data.

The planner-visible schema for computer tools therefore excludes runtime-owned freshness fields even though the registered execution descriptor still requires them after runtime binding. This keeps stale-state protection meaningful and makes the pre-action observation used for execution the same observation used as the verifier's "before" evidence.

## 5. Execution Artifact

### 5.1 Task execution output

`TaskRuntime` will pass a `TaskVerificationInput` to `TaskVerifying`. It contains the task plus a bounded execution artifact.

The artifact has explicit cases rather than an untyped dictionary:

- model final text;
- pre-existing verifier evidence;
- read-only tool receipt and descriptor verification contract;
- computer mutation receipt plus pre/post observation evidence and expected semantic outcome.

The existing `TaskExecutionResult` may remain the executor-facing result type where useful, but production computer execution must retain enough state for verifier construction instead of collapsing immediately to a bare receipt.

### 5.2 Computer observation evidence

Computer semantic verification needs more than `observationID` and `stateVersion`. The observation source must expose bounded verification material captured before and after the action:

- process ID;
- window ID;
- observation ID;
- state version;
- provenance;
- taint/confidence metadata;
- screenshot image for local verification only.

Raw screenshot bytes are transient verification inputs. They are not written into `VerificationEvidence`, runtime events, checkpoints, or logs.

ExamPilot `ScreenCaptureService` is Chrome-specific and is not reused for capture. ZeroLose will own a small general ScreenCaptureKit adapter that captures the exact `windowID` established by the authoritative macOS observation provider. Only ExamPilot `OutcomeVerifier` and its semantic change algorithms are reused.

Pre- and post-action evidence must refer to the same process/window identity. Any identity mismatch is rejected and requires re-observation/replanning instead of success.

## 6. Reusing ExamPilot OutcomeVerifier

ZeroLose will adapt its typed computer expectation to ExamPilot's existing `ExpectedOutcomeKind` and call the existing `OutcomeVerifier`.

Mapping:

- `computerNone` -> `.none`
- `computerAnswerMutation` -> `.answerMutation` or `.answerMutationAt(...)` when a trusted normalized interaction point is available
- `computerViewportChange` -> `.viewportChange`
- `computerNavigation` -> `.navigation`

ZeroLose will not copy thresholds, pixel-diff algorithms, localized mutation logic, or navigation identity logic. Those remain owned by ExamPilot's `OutcomeVerifier`.

Outcome mapping is fail-closed:

- `.success` -> bounded `VerificationEvidence` may be created;
- `.pending` -> task verification rejected for the current attempt so recovery/re-observation can occur;
- `.failure` -> task verification rejected.

A pending result never becomes implicit success merely because the tool receipt exists.

## 7. Production Task Verifier

`ProductionAgentTaskVerifier` will implement `TaskVerifying`.

### 7.1 Read-result verification

A read-only task can be verified only when:

- the descriptor contract is exactly `read-result`;
- a tool receipt exists for the planned tool;
- the receipt has bounded result provenance;
- the result payload exists, decodes as JSON, and is a top-level JSON object;
- no credential material is introduced into evidence.

The verifier records bounded evidence identifying the tool, verification kind, and provenance. It does not copy arbitrary result text into the evidence summary.

### 7.2 Computer mutation verification

A computer mutation can be verified only when:

- the descriptor contract is exactly `fresh-computer-observation`;
- pre-action observation/capture exists;
- physical execution produced a receipt;
- a fresh post-action observation/capture exists;
- state version increases monotonically;
- post observation ID differs from the pre observation ID;
- process/window identity still matches;
- the expected semantic outcome is compatible with the action;
- `OutcomeVerifier` returns success.

Evidence contains only bounded semantic fields such as outcome kind, provenance, state versions, and stable identifiers. Screenshots are not persisted.

### 7.3 Unsupported execution classes

Model final text, missing artifacts, unknown descriptor contracts, malformed receipts, and incompatible expectations return `.rejected`.

## 8. Production Goal Verifier

`ProductionAgentGoalVerifier` evaluates the authoritative `TaskGraphSnapshot` only; it does not ask the model whether the goal is finished.

A goal can complete only when:

- the graph belongs to the same goal ID;
- the graph contains at least one task;
- every task in the graph is in `.succeeded` (the current `TaskGraph` has no optional-task concept, so every admitted task is required);
- every succeeded task contains at least one verification evidence record;
- no task is still created, blocked, ready, planning, running, verifying, failed, recovering, replanned, paused, waiting external/approval, exhausted, or cancelled.

When these conditions hold, the verifier creates a bounded goal-level evidence record whose provenance states that completion derives from verified task evidence. Taint is never laundered: if any contributing task evidence is tainted, the goal-level evidence is also tainted. It must not concatenate arbitrary task summaries or provider output.

If any condition is not met, it returns `completed: false` with no evidence.

## 9. Planner and Descriptor Compatibility

`ModelPlanningAdapter` already owns provider-neutral structured planning. Its schema will be extended so each planned invocation includes a typed verification expectation.

Validation occurs before tasks are admitted to the graph:

- `read-result` descriptors accept only `readResult`;
- `fresh-computer-observation` descriptors accept only computer expectations appropriate to the mapped action;
- unknown verification contracts reject the proposal;
- an omitted expectation rejects any invocation that requires verification.

The runtime must not infer a success expectation from the tool name after execution. Any deterministic tool-to-expectation compatibility table exists only as validation of planner output, not as hidden planner behavior.

## 10. Computer Execution Data Flow

For a mutation task, the flow is:

1. Planner emits a planned tool invocation with action arguments and typed expected outcome, but without runtime-owned freshness fields.
2. Orchestrator admits and schedules the task.
3. `AgentToolInvocationExecutor` resolves the descriptor and obtains one authoritative pre-action observation/capture.
4. Runtime binding injects that observation's `stateVersion` and `observationID` into the computer invocation arguments.
5. Tool Fabric/Policy Kernel/ComputerMutationGating execute the approved mutation through `MacOSComputerMutationAdapter`, which validates the same bound freshness values against current authoritative state.
6. A fresh post-action observation is captured after bounded settling/stability handling.
7. Executor returns the receipt plus pre/post verification artifact.
8. `ProductionAgentTaskVerifier` validates identity/freshness/contract and calls ExamPilot `OutcomeVerifier`.
9. Only a semantic success produces `VerificationEvidence` and allows task `.succeeded`.
10. `ProductionAgentGoalVerifier` completes the goal only after all required tasks are independently verified.

Emergency Stop remains authoritative during execution and must also prevent post-stop work from being promoted to success.

## 11. Error and Recovery Semantics

Verification problems are task failures, not process crashes, unless the underlying persistence/runtime contract itself is corrupt.

Examples that produce verification rejection and therefore existing orchestrator recovery/replan behavior:

- no visible effect;
- UI still transitioning;
- navigation identity unchanged;
- post-action observation unavailable;
- window/process identity changed;
- stale or non-monotonic observation state;
- unknown verification contract;
- missing expected outcome;
- malformed or missing receipt/result.

The existing `RuntimeBudget` bounds retries and prevents unbounded recovery.

## 12. Persistence and Privacy

Persisted `VerificationEvidence` must be bounded metadata only. It may contain:

- evidence ID;
- normalized verification kind;
- tool/task identifiers;
- bounded state-version information;
- provenance identifier;
- taint status;
- timestamp.

It must not contain:

- screenshots or screenshot hashes intended to reconstruct private content;
- raw model output;
- raw tool result text;
- typed user text;
- cookies, tokens, authorization headers, credential handles, or credential file paths.

## 13. File Boundaries

The implementation should keep responsibilities separated:

- `Autonomy/VerificationExpectation.swift` — closed typed planner/runtime verification intent.
- `Autonomy/TaskVerifier.swift` — verification input/artifact contracts and `TaskVerifying` protocol.
- `Autonomy/ProductionAgentTaskVerifier.swift` — production task proof rules and ExamPilot outcome adapter.
- `Autonomy/ProductionAgentGoalVerifier.swift` — graph-derived goal completion proof.
- `Autonomy/TaskNode.swift` — planned invocation carries the typed expectation.
- `Autonomy/ModelPlanningAdapter.swift` — structured schema/decoding/validation for expectation.
- `Application/ZeroLoseRuntimeContainer.swift` — composition only; remove fail-closed verifier placeholders after production verifier wiring exists.
- `Computer/MacOSComputerObservationProvider.swift` — expose bounded authoritative observation identity/state for verification.
- `Computer/MacOSComputerVerificationCapture.swift` — capture the exact observed macOS window with ScreenCaptureKit and return transient `CGImage` verification material.
- `Computer/ComputerInvocationFreshnessBinder.swift` — inject runtime-owned observation freshness fields into planner-produced computer arguments before Tool Fabric execution.
- Tests mirror each production responsibility instead of concentrating all behavior in container tests.

`ZeroLoseRuntimeContainer.swift` must not become the implementation home for verifier logic.

## 14. Test Strategy

Behavior changes follow RED -> minimal GREEN -> focused regression -> affected suite.

Required cases:

1. Receipt-only mutation cannot verify.
2. Mutation with missing pre/post capture cannot verify.
3. Same-state or stale post observation cannot verify.
4. Different process/window identity cannot verify.
5. `OutcomeVerifier.noVisibleEffect` cannot verify.
6. Pending UI transition cannot verify.
7. Navigation identity unchanged cannot verify.
8. Verified answer mutation produces bounded untainted evidence.
9. Verified viewport change produces bounded untainted evidence.
10. Verified navigation produces bounded untainted evidence.
11. Read-result contract verifies a valid read receipt without copying raw result text.
12. Unknown verification contract fails closed.
13. Missing/incompatible planner expectation is rejected before execution.
14. Planner-supplied `stateVersion` or `observationID` is rejected rather than trusted.
15. Runtime binds freshness fields from the exact pre-action observation used for verification.
16. Provider final text alone cannot verify.
17. Goal does not complete when any task lacks verification evidence.
18. Goal completion preserves taint when any contributing task evidence is tainted.
19. Goal completes when every admitted task has valid verification evidence.
20. Existing Emergency Stop and cancellation tests remain green.
21. Architecture boundary tests continue to prevent direct physical-input authority outside the adapter path.
22. Repository-wide `python3 scripts/verify_all.py` passes on the committed revision.

## 15. Non-Goals

This slice does not:

- add OCR, browser DOM semantic verification, or model-judged verification;
- redesign Tool Fabric or Policy Kernel;
- change credential storage;
- add new physical computer actions;
- relax existing approval/authority rules;
- persist screenshots;
- make unverified external side effects idempotent by assumption;
- merge or push the feature branch.

Future semantic sources may extend verification through new typed evidence adapters, but they must preserve the same fail-closed contract.

## 16. Acceptance Criteria

The design is implemented only when:

- production Agent mode no longer uses `FailClosedAgentTaskVerifier` or `FailClosedAgentGoalVerifier`;
- a bare tool receipt cannot produce task success;
- computer mutations require independent pre/post semantic verification through the existing ExamPilot `OutcomeVerifier`;
- read-only results use an explicit supported verification contract;
- planner expectations are typed and validated before execution;
- computer freshness tokens are runtime-owned and bound from the verifier's authoritative pre-action observation;
- goal completion derives only from verified task evidence;
- unknown or unavailable verification paths remain fail-closed;
- screenshots remain transient and are not persisted in runtime evidence/events/checkpoints;
- focused regression tests and repository-wide verification pass;
- all changes remain local until the user separately authorizes push/merge.
