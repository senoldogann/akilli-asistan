# Akıllı Asistan

A macOS-first autonomous computer-use runtime focused on reliable observation, guarded physical interaction, semantic verification, recovery, and stateful agent execution.

The repository currently contains two macOS codebases:

- **ExamPilot**: the active computer-use runtime and CLI, built as a Swift Package.
- **ZeroLose**: the existing macOS application surface retained in the repository while the reusable runtime evolves.

## Why this project exists

LLM-driven desktop automation fails when model intent is treated as truth. Akıllı Asistan uses a stricter runtime model: the model proposes, deterministic code decides what is legal, native input performs the action, and post-action evidence determines whether the action actually succeeded.

That separation prevents common failure modes such as stale-coordinate replay, repeated blind clicks, acting on loading frames, carrying state from one question/page into the next, and treating any pixel change as proof of success.

## Core capabilities

- ScreenCaptureKit observation of the active Chrome window.
- Read-only macOS Accessibility fusion for bounded role, geometry, focused, selected, and enabled hints.
- Optional read-only Chrome DevTools Protocol fusion for bounded browser role/state and viewport-relative geometry hints.
- Accessibility and browser hints are bound to the current Chrome process, browser-window geometry, and runtime state version before reaching the planner.
- CoreGraphics mouse, keyboard, scroll, and bounded wait execution.
- Chrome process/window focus continuity checks before live input.
- Runtime-owned lifecycle state with monotonic state versions.
- Hard policy gates for protected navigation and stale proposals.
- UI stability detection before reasoning on a new state.
- Semantic outcome verification for answer mutation, viewport change, and navigation.
- Classified recovery with bounded retries and anti-loop intent fingerprints.
- Session-owned, privacy-bounded working memory and structured telemetry.
- OpenAI Responses structured-vision provider.
- Native OpenAI Computer Use provider contract with `previous_response_id` continuation and `computer_call_output` screenshots.
- Emergency stop, dry-run, and bounded verbose diagnostics modes.

## Architecture

```mermaid
flowchart TD
    G[User goal] --> S[ComputerAgentSession]
    S --> O[Screen observation]
    O --> A[Read-only Accessibility fusion]
    A --> B[Optional read-only browser semantic fusion]
    B --> P[Agent provider]
    P --> I[Proposed intent/actions]
    I --> R[Runtime state + ActionPolicy]
    R -->|denied| O
    R -->|validated| E[Native ActionExecutor]
    E --> V[OutcomeVerifier]
    V -->|success| S
    V -->|pending| O
    V -->|failure| C[RecoveryEngine]
    C --> O
```

### Authority boundaries

| Component | Responsibility |
| --- | --- |
| Screen/Accessibility/browser observation | Supplies read-only evidence; cannot grant runtime authority |
| Agent provider | Proposes the next action or intent |
| Runtime state | Describes accepted application/task state |
| ActionPolicy | Determines whether a proposed action is executable |
| ActionExecutor | Performs native physical input |
| OutcomeVerifier | Establishes whether the expected effect occurred |
| RecoveryEngine | Changes strategy after classified failures |
| ComputerAgentSession | Owns runtime state, provider continuation, working memory, and stop state |

The provider and observation sensors never directly grant permission to navigate, mark an answer as verified, or bypass stale-state checks.

## Requirements

- macOS 14+
- Swift 5.10+
- Google Chrome for the current ExamPilot workflow
- Screen Recording permission
- Accessibility permission enables read-only macOS semantic hints and is required for live physical input
- `OPENAI_API_KEY`
- Optional: a user-authorized loopback Chrome DevTools endpoint for browser semantic hints

## Quick start

```bash
cd ExamPilot
swift test
swift build -c release
```

Run one observation/planning cycle without physical input:

```bash
export OPENAI_API_KEY='<your-key>'
swift run exampilot --dry-run
```

Run live:

```bash
swift run exampilot
```

Optional overrides:

```bash
swift run exampilot --model gpt-5.6-sol
swift run exampilot --max-cycles 80
swift run exampilot --verbose
```

### Optional browser semantic hints

Browser semantic fusion is disabled unless `EXAMPILOT_CDP_ENDPOINT` is explicitly configured. The endpoint must be an uncredentialed loopback HTTP URL such as `http://127.0.0.1:9222`; arbitrary hosts, HTTPS endpoints, credentials, paths, queries, and fragments are rejected.

Chrome 136+ does not honor `--remote-debugging-port` against the default Chrome data directory. Use a separate non-default user data directory or Chrome for Testing. One macOS example is:

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir="$HOME/.exampilot-chrome"
```

Then enable the read-only sensor:

```bash
export EXAMPILOT_CDP_ENDPOINT='http://127.0.0.1:9222'
swift run exampilot --dry-run
```

The runtime verifies that CDP reports the same Chrome OS process as the captured window, requires exactly one focused and visible page target, compares browser-window geometry with the captured window, and binds the snapshot to the current runtime state version. If the endpoint is valid but unavailable, stale, ambiguous, or inconsistent, browser hints are discarded and planning continues with the screenshot and available macOS Accessibility hints.

Slice 8 only permits the following CDP methods:

- `SystemInfo.getProcessInfo`
- `Runtime.evaluate` with a fixed internal expression used only to confirm page focus and visibility
- `Browser.getWindowForTarget`
- `Page.getLayoutMetrics`
- `Accessibility.getFullAXTree`
- `DOM.getContentQuads`

Navigation and input methods such as `Page.navigate`, `Input.*`, `DOM.focus`, `Browser.set*`, and `Target.activateTarget` are rejected by the transport allowlist. Browser semantics remain a sensor; live mutation continues through the existing native CoreGraphics input path.

Raw page URLs, titles, accessible names, text values, DOM payloads, AX payloads, cookies, storage, and network data are not forwarded into planner state or working-memory telemetry. Only bounded role/state metadata and normalized viewport geometry reach the planner.

`--verbose` prints bounded cycle-level diagnostics such as state version, question generation, event kind, verification failure ID, and recovery strategy. It deliberately excludes session identifiers, screenshots, provider payloads, raw typed answers, and secrets.

For a reproducible diagnostic run:

```bash
swift run exampilot --verbose --max-cycles 30 2>&1 | tee ~/Desktop/exampilot.log
```

A classified non-progress stop is reported with its stable failure identifier even without verbose mode, for example:

```text
ExamPilot stopped after 13 cycles. reason=repeated_intent_loop. Run with --verbose for cycle-level diagnostics.
```

Press **Ctrl-C** to request an emergency stop.

## Runtime invariants

The active ExamPilot path is intentionally fail-closed:

1. A proposal is bound to the observation state version that produced it.
2. Physical input is rejected if the focused Chrome target no longer matches the captured target.
3. Protected navigation is rejected until the runtime has verified the current answer state.
4. Structural transitions must settle before the next provider turn is accepted.
5. A visual difference alone is not sufficient evidence of semantic success.
6. Repeated failed intents consume a bounded recovery budget; the runtime does not blindly replay the same click.
7. Unknown native Computer Use action types fail closed.
8. Accessibility hints are accepted only for the matching process, focused-window geometry, and current state version; they cannot mark answers verified or grant navigation authority.
9. Accessibility observation is read-only and falls back to screenshot-only planning when unavailable or inconsistent.
10. Browser semantic hints are opt-in and accepted only for the matching Chrome process, focused/visible page, browser-window geometry, and current state version.
11. Browser semantic observation is read-only; mutation-capable CDP methods are not in the transport allowlist.
12. Browser hints are viewport-relative advisory evidence and cannot directly become unchecked global physical coordinates.
13. Secrets, raw screenshots, typed private text, raw Accessibility labels/values, raw browser semantic payloads, and provider payloads are not persisted in working-memory telemetry.

## Provider model

Two provider surfaces coexist deliberately:

### Structured vision execution

`OpenAIResponsesVisionAgent` is the current physical-execution planner. It returns the repository's structured action schema, which allows the runtime to classify protected boundaries before any native input occurs.

The CLI first decorates this planner with `AccessibilityFusingVisionAgent`. That decorator attempts a bounded read-only Accessibility observation for the captured Chrome process, rejects stale or mismatched snapshots, and forwards only structured role/geometry/focused/selected/enabled hints.

When `EXAMPILOT_CDP_ENDPOINT` is configured, `BrowserSemanticFusingVisionAgent` adds a second optional read-only sensor. It forwards only bounded browser role/state metadata and normalized viewport geometry after process, focused-page, window, and state-version checks. If either sensor is unavailable or inconsistent, the planner continues with the remaining trusted observation sources; neither sensor gains runtime authority.

### Native OpenAI Computer Use

`OpenAIComputerUseProvider` implements the Responses Computer Use contract, including:

- built-in `computer` tool requests;
- ordered `computer_call.actions[]` decoding;
- `previous_response_id` continuation;
- `computer_call_output` screenshots;
- screenshot detail set to `original`;
- fail-closed handling of unknown action types.

Native Computer Use is currently a provider/proposal surface rather than an unrestricted direct physical-execution bypass. It will only become a default executor path when semantic target classification can preserve the same runtime invariants.

## Repository layout

```text
.
├── ExamPilot/                 # Active Swift Package computer-use runtime
│   ├── Package.swift
│   ├── Sources/
│   └── Tests/
├── ZeroLose/                  # Existing macOS application
├── docs/
│   └── superpowers/
│       ├── specs/             # Approved architecture specifications
│       └── plans/             # Incremental implementation plans
├── scripts/
│   └── verify_all.py          # Repository verification gate
├── .github/workflows/
│   └── exampilot.yml          # macOS CI gate
├── AGENTS.md                  # Repository engineering contract
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

Legacy provider-adapter directories such as `.agent`, `.codex`, `.claude`, and `.opencode` are intentionally not part of the repository contract.

## Verification

Run the repository gate from the root:

```bash
python3 scripts/verify_all.py
```

The gate checks the cleaned repository layout, runs the ExamPilot test suite, builds ExamPilot in release mode, verifies that the release CLI exposes `--verbose`, and builds ZeroLose with code signing disabled when Xcode is available.

## Development rules

- Add regression coverage for every behavior change that can reach physical input.
- Keep model/provider and sensor output untrusted until deterministic policy validates it.
- Preserve strict typing, bounded retries, cancellation, and resource cleanup.
- Do not hardcode API keys, tokens, credentials, or private data.
- Use current official provider and browser documentation before changing external request/tool contracts.
- Keep architecture decisions and implementation plans under `docs/superpowers/`.

See [AGENTS.md](AGENTS.md) for the repository engineering contract.

## Safety and scope

This project is intended for user-authorized computer interaction and testing. It does not include anti-proctoring, stealth/evasion, CAPTCHA bypass, monitoring defeat, or mechanisms designed to circumvent access controls.

High-impact or irreversible workflows should remain behind explicit approval and application-specific policy gates.

## License

See [LICENSE](LICENSE).
