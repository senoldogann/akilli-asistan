# ExamPilot Visual Agent Design

## Purpose

ExamPilot is a native macOS visual computer-use agent for authorized quiz and exam environments opened in Google Chrome. It deliberately avoids browser extensions, DOM/CDP access, JavaScript injection, and clipboard operations. It operates from screenshots and native input events so that it can work with interfaces that block copy/paste or expose no automation-friendly DOM.

## Scope

The first production slice must:

- capture the visible authorized Chrome window with ScreenCaptureKit;
- prefer the focused/active Chrome window and use the largest visible Chrome window only as a fallback;
- carry the captured Chrome process identity into the execution loop;
- before live physical input, re-activate the captured Chrome process and verify that the focused Chrome window still geometrically matches the screenshot;
- fail closed if focus moved to another Chrome window while the model was reasoning;
- reason about the current visible quiz/exam state from the screenshot;
- support single-choice, multi-choice, text, code-entry, scrolling, and navigation states;
- plan multiple safe actions from one observation;
- stop a batch at the first UI-changing boundary such as Next, Continue, Run/Test, Submit, or page transition;
- move the real system cursor along a smooth path and click through CoreGraphics events;
- type text through keyboard events only, without clipboard access;
- use bounded randomized key timing so typing is not an unrealistic zero-delay injection;
- scroll with native wheel events;
- allow expected UI changes a short bounded settling interval, then recapture and verify progress;
- stop safely on repeated non-progress, permission failure, malformed model output, focus mismatch, or an explicit stop request, including a stop request that arrives during long mouse/type/wait operations;
- keep ZeroLose behavior unchanged.

This feature is intended only for environments the user owns or is authorized to automate/test.

## Architectural Decision

Implement ExamPilot as a standalone Swift Package inside the existing `akilli-asistan` repository rather than adding code to the ZeroLose Xcode target. This keeps the existing interview assistant stable and makes the computer-use core independently buildable and testable. The package is macOS-only and exposes a command-line executable named `exampilot` plus an `ExamPilotCore` library target.

The package uses native Apple frameworks directly: AppKit/CoreGraphics for cursor and keyboard events, Accessibility APIs for focused-window resolution and pre-input focus verification, ScreenCaptureKit for screenshots, ImageIO/UniformTypeIdentifiers for JPEG encoding, and Foundation/URLSession for model calls. No browser-specific automation dependency is required.

## Runtime Data Flow

1. `ExamLoop` requests a screenshot from `ScreenCaptureService`.
2. `ScreenCaptureService` resolves the focused Chrome window when Accessibility is available, otherwise it falls back to the largest visible Chrome window, and stores the owning Chrome process ID in `ScreenFrame`.
3. `VisionAgent` receives the screenshot plus a compact state summary and returns a strict `ExamDecision`.
4. `ActionBatchPolicy` validates and truncates the proposed action list at a navigation/UI-changing boundary.
5. In live mode, `ChromeInputFocusService` re-activates the captured Chrome process and verifies that Chrome's current `AXFocusedWindow` still overlaps the captured window geometry strongly enough to be the same window. A mismatch aborts before physical input.
6. `ActionBatchExecutor` executes the actions sequentially using the native mouse, keyboard, scroll, and wait controllers. `NativeInputDriver` also checks the emergency-stop signal inside long-running native input operations.
7. Expected-change batches receive a bounded UI-settle interval.
8. `ScreenCaptureService` captures the post-action screen.
9. `VisualChangeDetector` compares before/after perceptual fingerprints.
10. `ExamLoop` records progress and continues, retries with a fresh observation, or aborts after bounded non-progress.

Dry-run exits after validated planning and never invokes the focus-preparation hook or physical input.

## Action Model

`ExamAction` is represented by a strict Codable tagged object. Supported actions:

- `move_click`: move the real cursor to `(x,y)` and click;
- `type_text`: type a provided string using keyboard events;
- `key`: press a named navigation/editing key such as return, tab, escape, arrows, delete, or space;
- `scroll`: native vertical scroll by an integer pixel amount;
- `wait`: bounded delay in milliseconds;
- `finish`: terminal marker; no physical input.

The model may return several actions in one decision. `ActionBatchPolicy` treats actions marked `boundary=true` and `finish` as hard batch boundaries. No actions after the first boundary are executed. Any non-finish boundary is treated by runtime policy as requiring visual verification even if the model incorrectly claims that no visual change is expected. This preserves speed within one visible UI state without trusting coordinates after a page transition.

## Coordinate Contract

All model-proposed coordinates are absolute macOS global screen points, not raw screenshot pixels. `ScreenFrame` carries the captured image pixel dimensions, the corresponding Chrome-window global point rectangle, and the captured Chrome process ID. The model prompt receives the image/global dimensions and explicitly maps screenshot positions into global points. The executor rejects coordinates outside the captured Chrome rectangle.

## Mouse Input

`NativeInputDriver` reads the current CoreGraphics cursor location, generates a bounded cubic Bezier path to the target, and posts `mouseMoved`, `leftMouseDown`, and `leftMouseUp` events globally with `CGEvent.post(tap: .cghidEventTap)`. The path duration and number of samples are bounded. The emergency-stop flag is checked before each movement sample and again before mouse-down. Once mouse-down is posted, mouse-up is always paired before cancellation is surfaced so macOS is not left with a stuck button. There is no deliberate random misclick behavior.

## Keyboard Input

`NativeInputDriver` never touches `NSPasteboard`. For ordinary Unicode text it posts key-down/key-up events using `CGEventKeyboardSetUnicodeString`, one grapheme cluster at a time, with a bounded delay profile. Newlines and tabs are emitted as physical key presses. Named special keys map to macOS virtual key codes. The emergency-stop flag is checked before every grapheme/key event. Once key-down is posted, key-up is always paired before cancellation is surfaced. Delay generation is bounded and unit-tested without posting real events.

## Screen Capture

`ScreenCaptureService` enumerates on-screen windows with ScreenCaptureKit, filters normal Google Chrome windows, and captures the chosen window using `SCScreenshotManager.captureImage(contentFilter:configuration:)`. When Accessibility is available it matches Chrome's `AXFocusedWindow` global frame to the ScreenCaptureKit window list. If focused-window information is unavailable, such as dry-run without Accessibility, it safely falls back to the largest visible Chrome window. The resulting `CGImage` is JPEG encoded for model input and the owning Chrome process ID is retained for live input preparation.

## Pre-Input Focus Verification

`ChromeInputFocusService` is invoked only after planning/validation and only in live mode. It activates the captured Chrome process, resolves its current `AXFocusedWindow`, raises it, waits for a short bounded activation interval, then compares the focused AX window frame with the captured `ScreenFrame.screenBounds` using intersection-over-union. The default match threshold is 0.65.

If the Chrome process exited, Accessibility became unavailable, the focused window cannot be resolved, or the focused window no longer matches the captured geometry, the batch terminates without posting mouse or keyboard events. This specifically prevents stale screenshot coordinates from being applied to another Chrome window in the same browser process.

## Vision / Reasoning Provider

`OpenAIResponsesVisionAgent` uses the OpenAI Responses API and accepts model configuration through environment variables:

- `OPENAI_API_KEY` (required)
- `EXAMPILOT_MODEL` (default `gpt-5.6-sol`)

It sends the screenshot as a base64 data URL using an `input_image` item and requests strict JSON Schema structured output. The returned schema maps exactly to `ExamDecision`. The executable provides `--dry-run`, which performs observation/planning but never executes physical input or changes application focus.

## Safety and Control

The runtime enforces:

- Accessibility permission preflight for physical input and exact-window focus verification;
- Screen Recording permission preflight/request for capture;
- captured Chrome PID continuity before live input;
- captured-window versus focused-window geometry verification before live input;
- maximum actions per batch: 12;
- maximum wait action: 5 seconds;
- maximum absolute scroll amount per action: 1400 pixels;
- coordinate bounds checks against the captured Chrome window;
- no shell execution, clipboard access, browser injection, filesystem mutation, or arbitrary tool execution from model output;
- hard stop at the first UI-changing boundary;
- visual verification forced after non-finish boundary actions;
- maximum consecutive non-progress batches: 3;
- `SIGINT`/Ctrl-C is checked between action objects and inside mouse movement, per-character typing, key/scroll dispatch, and short slices of waits;
- down/up input pairs are completed before cancellation is surfaced so a stop cannot leave a key or mouse button logically held;
- `--dry-run` disables all mutations, including application focus changes.

## Verification

`VisualChangeDetector` downsamples captured images into a grayscale fingerprint and computes a normalized mean absolute difference. A batch that is expected to change the UI but produces a score below a conservative threshold counts as non-progress. Before the verification capture, the loop waits for a short bounded settling interval so slow browser UI transitions are not mistaken for failure. Three consecutive non-progress batches abort the run.

## CLI

Examples:

```bash
cd ExamPilot
swift run exampilot --dry-run
swift run exampilot
swift run exampilot --model gpt-5.6-sol
```

The CLI reports run mode, model, window-targeting strategy, stop control, dry-run plan summary, and terminal reason. It must never print the API key.

## Testing

Unit tests cover:

- action-batch truncation at boundaries;
- boundary-forced visual verification;
- action validation limits and coordinate bounds;
- focused Chrome-window selection and fallback behavior;
- live input preparation occurring after capture and before physical input;
- dry-run skipping focus preparation entirely;
- captured/focused Chrome window geometry matching and same-process wrong-window rejection;
- executor translation of driver cancellation into a stopped batch;
- native driver stop checks before typing physical input;
- visual fingerprint/change scoring using generated `CGImage` fixtures;
- keyboard delay profile bounds without posting real events;
- OpenAI response decoding and request construction from fixture data;
- loop behavior for progress, UI settle ordering, non-progress retries, dry-run, stop, invalid batches, and finish.

Build verification:

```bash
cd ExamPilot
swift test
swift build -c release
```

The existing repository verifier is also executed as a separate regression check when a compatible macOS checkout is available:

```bash
python3 scripts/verify_all.py
```

A pre-existing or environment-specific failure in an unchanged product target is reported separately rather than weakening ExamPilot's own test/build gate.

## Non-Goals for This Slice

- DOM/CDP/browser-extension control;
- clipboard-based typing;
- hidden/background PID-targeted interaction;
- CAPTCHA bypass;
- anti-proctoring or stealth/evasion features;
- cross-platform support;
- persistent answer history or exam-specific adapters.
