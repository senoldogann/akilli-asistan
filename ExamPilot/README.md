# ExamPilot

ExamPilot is a native macOS visual computer-use agent for **authorized** quiz and exam environments opened in Google Chrome.

It intentionally does **not** use Chrome extensions, DOM/CDP automation, JavaScript injection, or clipboard paste. It observes the visible Chrome window, reasons from the screenshot, and interacts through the real macOS cursor, keyboard events, and scroll wheel events.

## What it does

- captures the focused/active Google Chrome window with ScreenCaptureKit when Accessibility can resolve it, with the largest visible Chrome window as a fallback;
- carries the captured Chrome process identity into the action loop and, before live input, re-activates Chrome and verifies that the focused window geometry still matches the screenshot;
- aborts physical input if focus moved to a different Chrome window while the model was reasoning;
- understands single-choice, multi-choice, text, code-entry, scrolling, and navigation states through a vision-capable model;
- plans several safe actions from one screenshot instead of forcing one model round-trip per click;
- stops an action batch at the first UI-changing boundary such as Next, Continue, Run/Test, Submit, or equivalent controls in any language;
- moves the real cursor over a smooth path and clicks with CoreGraphics HID events;
- types text/code character by character using keyboard events only;
- never reads or writes `NSPasteboard`;
- scrolls using native pixel wheel events;
- gives expected UI changes a short settling interval, captures the UI again, and stops after repeated non-progress;
- supports `--dry-run` to inspect the first planned batch without physical input or changing application focus;
- supports Ctrl-C as an emergency stop during long input as well as between planned actions.

## Requirements

- macOS 14 or newer
- Swift 5.10+ toolchain
- Google Chrome with the authorized quiz/test visible in a normal window
- Screen Recording permission
- Accessibility permission for live mode
- an OpenAI API key for a vision-capable model

## Build and test

```bash
cd ExamPilot
swift test
swift build -c release
```

## Run

Set the API key in the environment. ExamPilot does not print it or persist it.

```bash
export OPENAI_API_KEY='...'
cd ExamPilot
swift run exampilot --dry-run
```

Dry-run captures the visible Chrome window and produces one validated action batch without moving the mouse, typing, or re-activating Chrome.

For live execution:

```bash
cd ExamPilot
swift run exampilot
```

Use a different model if needed:

```bash
swift run exampilot --model gpt-5.6-sol
```

Or set it once:

```bash
export EXAMPILOT_MODEL='gpt-5.6-sol'
```

Limit a session:

```bash
swift run exampilot --max-cycles 80
```

Press **Ctrl-C** to request an emergency stop. The native driver checks the stop flag during mouse movement, before each typed character, before key/scroll events, in short slices during waits, and between high-level actions. If a mouse-down or key-down has already been posted, its matching up event is still sent so macOS is not left with a stuck button or key.

## macOS permissions

### Screen Recording

On first run macOS may request Screen Recording permission. If the permission was denied, enable the terminal/application running `exampilot` under:

`System Settings > Privacy & Security > Screen Recording`

### Accessibility

Live input requires Accessibility permission for the executable/terminal that launches ExamPilot:

`System Settings > Privacy & Security > Accessibility`

`--dry-run` does not require Accessibility because it never posts physical input or changes application focus. Without Accessibility, dry-run window selection falls back to the largest visible Chrome window because AX focused-window information is unavailable.

## Execution model

ExamPilot uses this loop:

```text
capture focused visible Chrome window + process identity
        ↓
vision model returns structured ExamDecision
        ↓
validate coordinates + action limits
        ↓
truncate at first UI-changing boundary
        ↓
re-focus captured Chrome process + verify same window geometry
        ↓
execute safe batch with real input
        ↓
short bounded UI settle
        ↓
capture again
        ↓
visual change verification
        ↓
continue / retry fresh observation / stop
```

A visible multi-select question can therefore produce a batch such as:

```text
click A
click C
click D
click Next   ← boundary; batch ends here
```

The next question is never acted on using coordinates guessed from the previous screenshot. If Chrome focus changes to another window before input starts, the batch is cancelled rather than replayed against stale coordinates.

## Safety limits

The core runtime rejects or bounds model output before it reaches physical input:

- maximum 12 proposed actions per observation;
- waits are limited to 5 seconds per action;
- scroll is limited to ±1400 pixels per action;
- click coordinates must be inside the captured Chrome window;
- live input requires the captured Chrome process to still exist and the focused window to geometrically match the captured window;
- emergency stop is checked inside long mouse/type/wait operations rather than only between action objects;
- actions after the first boundary are discarded;
- a boundary action forces post-action visual verification even if model output incorrectly claims no visual change is expected;
- a boundary click with no detected visual change is never replayed blindly from stale coordinates; the loop captures a fresh frame and asks the vision agent to reassess the current question and target;
- three consecutive expected-change batches with no meaningful visual change after fresh re-observations terminate the run;
- 200 observation cycles by default, configurable with `--max-cycles`;
- no shell tool, arbitrary filesystem action, clipboard access, browser injection, or DOM tool is exposed to the model.

## Persistence and replay

The runtime now has an opt-in local persistence foundation for diagnostics, replay, and future resume flows. The caller chooses the SQLite database location; persistence is intentionally split into three contracts even when one SQLite file backs all of them:

- `AgentEventStore` is append-only. SQLite triggers reject direct `UPDATE` and `DELETE` operations on persisted event rows.
- `AgentConversationStore` owns provider continuation metadata separately from runtime truth.
- `AgentMemoryStore` owns bounded structured working-memory snapshots.

Persisted event details are reduced to bounded diagnostic identifiers before storage. Screenshots, raw typed text, API credentials, Authorization headers, and complete provider payloads are not part of the persistence model.

Replay is read-only. `AgentResumeCheckpoint` deliberately marks persisted state as historical context with `requiresFreshObservation` and `requiresReconciliation`; it does not restore a verified answer, navigation eligibility, stale state version, transitioning UI state, or pending provider call as live execution authority. This slice is not wired into the default CLI, so persistence availability cannot silently change the existing physical-input path.

## Project layout

```text
ExamPilot/
├── Package.swift
├── README.md
├── Sources/
│   ├── ExamPilotCore/
│   │   ├── Models.swift
│   │   ├── AgentPersistence.swift
│   │   ├── SQLiteAgentPersistence.swift
│   │   ├── AgentReplay.swift
│   │   ├── AgentPersistenceCoordinator.swift
│   │   ├── ActionBatchPolicy.swift
│   │   ├── ChromeWindowSelection.swift
│   │   ├── ChromeInputFocusService.swift
│   │   ├── ScreenCaptureService.swift
│   │   ├── VisualChangeDetector.swift
│   │   ├── InputDriver.swift
│   │   ├── ActionBatchExecutor.swift
│   │   ├── VisionAgent.swift
│   │   ├── OpenAIResponsesVisionAgent.swift
│   │   └── ExamLoop.swift
│   └── ExamPilotCLI/
│       └── ExamPilotMain.swift
└── Tests/ExamPilotCoreTests/
```

## Design documents

- Design specification: `docs/superpowers/specs/2026-09-08-exampilot-visual-agent-design.md`
- Implementation plan: `docs/superpowers/plans/2026-09-08-exampilot-visual-agent.md`

## Scope

ExamPilot is built for pages the user owns or is explicitly authorized to automate and test. It does not include anti-proctoring, stealth/evasion, CAPTCHA bypass, or mechanisms intended to defeat monitoring controls.
