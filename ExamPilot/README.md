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
- supports Ctrl-C as an emergency stop before the next physical action.

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

Press **Ctrl-C** to request an emergency stop. The executor checks the stop flag before each new physical action in a batch.

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
- actions after the first boundary are discarded;
- a boundary action forces post-action visual verification even if model output incorrectly claims no visual change is expected;
- three consecutive expected-change batches with no meaningful visual change terminate the run;
- 200 observation cycles by default, configurable with `--max-cycles`;
- no shell tool, arbitrary filesystem action, clipboard access, browser injection, or DOM tool is exposed to the model.

## Project layout

```text
ExamPilot/
├── Package.swift
├── README.md
├── Sources/
│   ├── ExamPilotCore/
│   │   ├── Models.swift
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

## Scope

ExamPilot is built for pages the user owns or is explicitly authorized to automate and test. It does not include anti-proctoring, stealth/evasion, CAPTCHA bypass, or mechanisms intended to defeat monitoring controls.
