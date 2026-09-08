# Computer Agent Runtime V2 Slice 5 Implementation Plan

Date: 2026-09-08
Scope: Native OpenAI Computer Use provider + provider-session continuation
Base: `feat/computer-agent-runtime-v2-slice4`

## Goals

Implement the approved V2 migration step for native OpenAI Computer Use without weakening the deterministic runtime invariants already proven by Slices 1–4.

Current official OpenAI Computer Use contract used by this plan:

- Responses API with `tools: [{"type":"computer"}]`;
- native `computer_call` responses containing batched `actions[]`;
- follow-up screenshots sent as `computer_call_output`;
- `previous_response_id` reused on every continuation turn;
- computer screenshots use `detail: "original"` for coordinate fidelity;
- supported built-in action types include click, double_click, scroll, type, wait, keypress, drag, move, screenshot.

## Safety / correctness boundary

Native Computer Use actions are provider proposals, not executable runtime truth.

This slice deliberately does **not** bypass `ActionPolicy`, `ExamRuntimeState`, answer-before-navigation invariants, stale-state checks, focus verification, semantic outcome verification, or `RecoveryEngine`.

Because built-in `computer_call.actions[]` do not carry the repository's deterministic `boundary`/semantic-role metadata, the new native provider is introduced as a proposal-level provider abstraction and is **not made the default physical-execution path for the exam profile in this slice**. The existing structured-vision provider remains the active CLI execution provider until target-semantic fusion can classify native action intent fail-closed.

Unsupported or ambiguous native action shapes must fail closed rather than being silently approximated.

## Task 1: Provider contracts

Create provider-level data models:

- `ComputerAgentProvider` protocol;
- immutable `ComputerAgentProviderState` containing session ID, goal, runtime coordinates, bounded working-memory snapshot, previous response ID, and pending computer call ID;
- `ComputerAgentProviderTurn` containing response ID, optional computer call ID, native proposal actions, and terminal text/handoff state;
- `NativeComputerAction` enum / value model covering the official Computer Use action surface without executing it.

Tests:

- exact Codable/Equatable behavior;
- provider state contains continuation metadata but working-memory payload remains bounded;
- no API key or Authorization metadata appears in provider state/turn serialization.

## Task 2: Responses request construction

Add `OpenAIComputerUseProvider` using the existing `HTTPTransport` seam.

Initial request:

- POST `/v1/responses`;
- configured model, default `gpt-5.6-sol`;
- `store: false`;
- `tools: [{"type":"computer"}]`;
- user goal/runtime instructions plus current screenshot as `input_image`;
- screenshot detail is exactly `original`.

Continuation request:

- same model/tool definition;
- `previous_response_id` from session state;
- exactly one `computer_call_output` item using the pending call ID;
- `output.type = computer_screenshot`;
- screenshot `detail: "original"`.

Tests inspect the raw JSON request body and prove both shapes.

## Task 3: Response decoding

Decode Responses output without depending on OpenAI SDK types:

- capture top-level response `id`;
- find a `computer_call` item when present;
- capture its `call_id` and ordered `actions[]`;
- decode official action variants defensively;
- if no `computer_call` is present, extract final `output_text` when available;
- unknown/malformed action types produce a classified provider error, never an executable approximation.

Coordinate values stay in screenshot-pixel coordinates at provider level. Mapping to global macOS points remains an execution-adapter responsibility.

## Task 4: Session continuation ownership

Extend `ProviderConversationState` / `ComputerAgentSession` to own:

- `previousResponseID`;
- `pendingComputerCallID`.

Add an atomic session method that applies one provider turn's continuation metadata.

Tests prove:

- response ID is replaced monotonically per accepted provider turn;
- pending call ID is set for computer calls and cleared on terminal handoff;
- stop/cancellation state is unaffected;
- actual provider IDs are not serialized into structured-vision prompt text.

## Task 5: Structured provider fallback boundary

Add a small adapter/factory boundary so runtime configuration can select:

- current structured-vision execution provider;
- native OpenAI Computer Use proposal provider.

The default `ExamPilot` CLI remains structured-vision for physical execution in this slice. Native mode may be exposed only as explicit experimental/proposal-only configuration if doing so does not create a path around runtime policy.

Tests prove structured fallback behavior is unchanged.

## Task 6: Verification

Required fresh evidence on final head:

```bash
cd ExamPilot
swift test
swift build -c release
```

Review gates:

- existing unanswered-Q2 regression still passes;
- existing misclassified-navigation regressions still pass;
- no native provider path directly invokes `InputDriving` or `ActionBatchExecutor`;
- all continuation IDs remain session-owned;
- native screenshot detail is `original`, never `high`/`low`;
- no secrets/raw Authorization headers are logged or serialized;
- diff remains confined to provider/session/tests/plan surfaces.

Repository-wide `python3 scripts/verify_all.py` remains a final repository gate when an actual checkout is available.
