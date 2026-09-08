# ExamPilot Visual Agent Design

## Purpose

ExamPilot is a native macOS visual computer-use agent for authorized quiz and exam environments opened in Google Chrome. It deliberately avoids browser extensions, DOM/CDP access, JavaScript injection, and clipboard operations. It operates from screenshots and native input events so that it can work with interfaces that block copy/paste or expose no automation-friendly DOM.

## Scope

The first production slice must:

- capture the visible screen with ScreenCaptureKit;
- reason about the current visible quiz/exam state from the screenshot;
- support single-choice, multi-choice, text, code-entry, scrolling, and navigation states;
- plan multiple safe actions from one observation;
- stop a batch at the first UI-changing boundary such as Next, Continue, Run/Test, Submit, or page transition;
- move the real system cursor along a smooth path and click through CoreGraphics events;
- type text through keyboard events only, without clipboard access;
- use bounded randomized key timing so typing is not an unrealistic zero-delay injection;
- scroll with native wheel events;
- recapture the screen after each action batch and verify that the UI changed as expected;
- stop safely on repeated non-progress, permission failure, malformed model output, or an explicit stop request;
- keep ZeroLose behavior unchanged.

This feature is intended only for environments the user owns or is authorized to automate/test.

## Architectural Decision

Implement ExamPilot as a standalone Swift Package inside the existing `akilli-asistan` repository rather than adding code to the ZeroLose Xcode target. This keeps the existing interview assistant stable and makes the computer-use core independently buildable and testable. The package is macOS-only and exposes a command-line executable named `exampilot` plus an `ExamPilotCore` library target.

The package uses native Apple frameworks directly: AppKit/CoreGraphics for cursor and keyboard events, ScreenCaptureKit for screenshots, ImageIO/UniformTypeIdentifiers for JPEG encoding, and Foundation/URLSession for model calls. No browser-specific automation dependency is required.

## Runtime Data Flow

1. `ExamLoop` requests a screenshot from `ScreenCaptureService`.
2. `VisionAgent` receives the screenshot plus a compact state summary and returns a strict `ExamDecision`.
3. `ActionBatchPolicy` validates and truncates the proposed action list at a navigation/UI-changing boundary.
4. `ActionBatchExecutor` executes the actions sequentially using the native mouse, keyboard, scroll, and wait controllers.
5. `ScreenCaptureService` captures the post-action screen.
6. `VisualChangeDetector` compares before/after perceptual fingerprints.
7. `ExamLoop` records progress and continues, retries with a fresh observation, or aborts after bounded non-progress.

## Action Model

`ExamAction` is a Codable enum represented by a tagged JSON object. Supported actions:

- `move_click`: move the real cursor to `(x,y)` and click;
- `type_text`: type a provided string using keyboard events;
- `key`: press a named navigation/editing key such as return, tab, escape, arrows, delete, or space;
- `scroll`: native vertical scroll by an integer pixel amount;
- `wait`: bounded delay in milliseconds;
- `finish`: terminal marker; no physical input.

The model may return several actions in one decision. `ActionBatchPolicy` treats `move_click` actions marked `boundary=true`, `key` actions marked `boundary=true`, and `finish` as hard batch boundaries. No actions after the first boundary are executed. This preserves speed within one visible UI state without guessing coordinates after a page transition.

## Coordinate Contract

All model-proposed coordinates are absolute macOS global screen points, not image pixels. `ScreenFrame` carries both the captured image pixel dimensions and the corresponding global point rectangle. The model prompt receives these dimensions and must emit points inside the visible rectangle. The executor rejects out-of-bounds coordinates.

## Mouse Input

`HumanMouseController` reads the current cursor position from `NSEvent.mouseLocation`, converts to the CoreGraphics top-left coordinate space when needed, generates a cubic Bezier path, and posts `mouseMoved`, `leftMouseDown`, and `leftMouseUp` events globally with `CGEvent.post(tap: .cghidEventTap)`. The path duration and number of samples are bounded. There is no deliberate random misclick behavior.

## Keyboard Input

`HumanKeyboardController` never touches `NSPasteboard`. For ordinary Unicode text it posts key-down/key-up events using `CGEventKeyboardSetUnicodeString`, one grapheme cluster at a time, with a bounded delay profile. Newlines and tabs are emitted as physical key presses. Named special keys map to macOS virtual key codes. Delays are configurable and deterministic in tests through an injected random/delay source.

## Screen Capture

`ScreenCaptureService` uses `SCScreenshotManager.captureImage(in:)` to capture the union of active displays in display-space points. The resulting `CGImage` is encoded as JPEG for model input. Capture failures are surfaced as terminal runtime errors with permission guidance.

## Vision / Reasoning Provider

`OpenAIResponsesVisionAgent` uses the OpenAI Responses API and accepts model configuration through environment variables:

- `OPENAI_API_KEY` (required for live mode)
- `EXAMPILOT_MODEL` (default `gpt-5.6-sol`)

It sends the screenshot as a base64 data URL using an `input_image` item and requests strict JSON Schema structured output. The returned schema maps exactly to `ExamDecision`. The executable also provides `--dry-run`, which performs observation/planning but never executes physical input.

## Safety and Control

The runtime enforces:

- accessibility permission preflight for physical input;
- screen capture permission errors surfaced before the loop proceeds;
- maximum actions per batch: 12;
- maximum wait action: 5 seconds;
- maximum absolute scroll amount per action: 1400 pixels;
- coordinate bounds checks;
- no shell execution, clipboard access, browser injection, filesystem mutation, or arbitrary tool execution from model output;
- maximum consecutive non-progress batches: 3;
- `SIGINT`/Ctrl-C stops before the next physical action;
- `--dry-run` disables all mutations.

## Verification

`VisualChangeDetector` downsamples captured images into a grayscale fingerprint and computes a normalized mean absolute difference. A batch that is expected to change the UI but produces a score below a conservative threshold counts as non-progress. The loop then re-observes rather than replaying the same batch blindly. Three consecutive non-progress batches abort the run.

## CLI

Examples:

```bash
cd ExamPilot
swift run exampilot --dry-run
swift run exampilot
swift run exampilot --model gpt-5.6-sol
```

The CLI prints each observation summary, planned batch, execution result, verification score, and terminal reason. It must never print the API key.

## Testing

Unit tests cover:

- action-batch truncation at boundaries;
- action validation limits and coordinate bounds;
- visual fingerprint/change scoring using generated `CGImage` fixtures;
- keyboard delay profile bounds without posting real events;
- OpenAI response decoding from fixture JSON;
- loop behavior for progress, non-progress retries, dry-run, and finish.

Build verification:

```bash
cd ExamPilot
swift test
swift build -c release
```

The existing repository verifier remains a separate regression check when a compatible macOS checkout is available:

```bash
python3 scripts/verify_all.py
```

## Non-Goals for This Slice

- DOM/CDP/browser-extension control;
- clipboard-based typing;
- hidden/background PID-targeted interaction;
- captcha bypass;
- anti-proctoring or stealth/evasion features;
- cross-platform support;
- persistent answer history or exam-specific adapters.
