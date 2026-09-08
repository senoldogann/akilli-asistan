# ExamPilot Visual Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone macOS visual computer-use agent that observes authorized Chrome-based quiz/exam UIs from screenshots, plans safe multi-action batches, executes real mouse/keyboard/scroll input, and verifies progress without DOM/CDP/extensions or clipboard use.

**Architecture:** Add a standalone Swift Package at `ExamPilot/` with an `ExamPilotCore` library and `exampilot` executable. Native ScreenCaptureKit/CoreGraphics services are isolated behind protocols so planning, validation, loop behavior, and provider decoding are unit-testable without posting real input.

**Tech Stack:** Swift tools 5.10 package, macOS 14 deployment target, Foundation, AppKit, ApplicationServices, CoreGraphics, ScreenCaptureKit, ImageIO, UniformTypeIdentifiers, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-08-exampilot-visual-agent-design.md`

## Global Constraints

- macOS only; minimum deployment target macOS 14.
- No DOM, CDP, browser extension, JavaScript injection, clipboard access, shell execution, or arbitrary model-provided tools.
- Physical input uses global CoreGraphics HID events and the real cursor.
- A decision can contain multiple actions but execution stops at the first UI-changing boundary.
- Maximum 12 actions per batch, 5,000 ms wait, and 1,400 px absolute scroll per action.
- Three consecutive non-progress batches terminate the loop.
- `--dry-run` must never post physical input events.
- Existing ZeroLose sources and behavior are not modified by the initial implementation.

---

### Task 1: Package skeleton and domain contracts

**Files:**
- Create: `ExamPilot/Package.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/Models.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/ActionBatchPolicy.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchPolicyTests.swift`

**Interfaces:**
- Produces `ScreenFrame`, `ExamAction`, `ExamDecision`, `ValidatedBatch`, `ActionBatchPolicy`.
- Later tasks consume `ActionBatchPolicy.validate(_:screenBounds:) throws -> ValidatedBatch`.

- [x] **Step 1: Write failing tests** proving actions after the first boundary are dropped, more than 12 actions are rejected, waits over 5 seconds are rejected, scroll values beyond ±1400 are rejected, and click coordinates outside the screen rectangle are rejected.
- [x] **Step 2: Run the tests red** before implementation.
- [x] **Step 3: Implement the minimal Codable domain model and validation policy.** `ExamAction` uses a tagged `kind` plus optional fields (`x`, `y`, `text`, `key`, `amount`, `milliseconds`, `boundary`) to match strict structured-output JSON without custom enum decoding complexity.
- [x] **Step 4: Re-run the filtered tests** and confirm pass.
- [x] **Step 5: Commit** the domain contract and policy changes.

### Task 2: Screen capture, focused-window targeting, and visual change verification

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ChromeWindowSelection.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/ScreenCaptureService.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/VisualChangeDetector.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ChromeWindowSelectionTests.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/VisualChangeDetectorTests.swift`

**Interfaces:**
- Produces `ScreenCapturing.capture() async throws -> ScreenFrame`.
- Produces focused Chrome-window selection with largest-visible fallback.
- Produces `VisualChangeDetector.score(before:after:) -> Double` and `hasMeaningfulChange(before:after:) -> Bool`.

- [x] **Step 1: Write tests** for focused-window selection/fallback and generated image change fixtures.
- [x] **Step 2: Run tests red** before the missing focused-window behavior exists.
- [x] **Step 3: Implement a deterministic grayscale fingerprint** plus `ScreenCaptureService` using `SCShareableContent`, `SCContentFilter(desktopIndependentWindow:)`, and `SCScreenshotManager.captureImage(contentFilter:configuration:)`. Resolve Chrome's AX focused-window frame when Accessibility is available and fall back to the largest visible Chrome window otherwise.
- [x] **Step 4: Run tests** and confirm pass.
- [x] **Step 5: Commit** capture/selection/verification changes.

### Task 3: Human-style native input executor

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/InputDriver.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/ActionBatchExecutor.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchExecutorTests.swift`

**Interfaces:**
- Produces `InputDriving` protocol with `moveAndClick`, `typeText`, `pressKey`, `scroll`, and `wait` async methods.
- Produces `NativeInputDriver` for live execution and `ActionBatchExecutor.execute(_:dryRun:shouldStop:)`.

- [x] **Step 1: Write tests with a recording fake input driver** proving sequential execution order, dry-run produces no input calls, finish terminates the batch, and cancellation is checked between actions.
- [x] **Step 2: Run filtered tests red** before implementation.
- [x] **Step 3: Implement `NativeInputDriver`.** Mouse movement uses a cubic Bezier curve from current CG cursor location to target and posts global HID events. Unicode text is sent grapheme-by-grapheme via `CGEventKeyboardSetUnicodeString`; newline/tab use key events. Inter-key delay is bounded. Scroll uses native pixel wheel events.
- [x] **Step 4: Re-run tests** and confirm fake-based behavior passes without moving the real cursor.
- [x] **Step 5: Commit** native input changes.

### Task 4: Structured visual reasoning provider

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/VisionAgent.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/OpenAIResponsesVisionAgent.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/OpenAIResponsesVisionAgentTests.swift`

**Interfaces:**
- Produces `VisionAgent.decide(frame:state:) async throws -> ExamDecision`.
- `OpenAIResponsesVisionAgent` accepts an injected HTTP transport for tests and runtime `apiKey`, `model`.

- [x] **Step 1: Write fixture-decoding/request tests** for Responses API structured output and malformed/missing-output error cases.
- [x] **Step 2: Run tests red** before implementation.
- [x] **Step 3: Implement the request** to `POST https://api.openai.com/v1/responses` with screenshot JPEG as a base64 `data:image/jpeg;base64,...` `input_image`, an exam-control prompt, and `text.format.type=json_schema` strict structured output. Default model is `gpt-5.6-sol`; runtime may override it.
- [x] **Step 4: Re-run tests** and confirm decoding/request construction passes with fake transport.
- [x] **Step 5: Commit** the structured vision planner.

### Task 5: Observe-plan-batch-settle-verify runtime loop

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopTests.swift`

**Interfaces:**
- Produces `ExamLoop.run() async -> ExamRunResult`.
- Consumes `ScreenCapturing`, `VisionAgent`, `ActionBatchPolicy`, `ActionBatchExecutor`, and `VisualChangeDetector`.

- [x] **Step 1: Write async tests with fakes** proving progress, three no-change abort, finish, invalid batch re-observation, dry-run, stop signal, and settle-before-verification ordering.
- [x] **Step 2: Run tests red** before missing behavior.
- [x] **Step 3: Implement the bounded loop** with maximum 200 cycles, three consecutive non-progress limit, bounded post-action settle, and explicit terminal reasons.
- [x] **Step 4: Add policy hardening** so a non-finish UI boundary forces visual verification even if the model's `expectsVisualChange` flag is false; verify red-green with a regression test.
- [x] **Step 5: Re-run tests** and confirm pass.

### Task 6: CLI, permission checks, documentation, and CI

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCLI/ExamPilotMain.swift`
- Create: `ExamPilot/README.md`
- Create: `.github/workflows/exampilot.yml`

**Interfaces:**
- Executable `exampilot [--dry-run] [--model MODEL] [--max-cycles N]`.

- [x] **Step 1: Implement CLI argument parsing** with `OPENAI_API_KEY`, `EXAMPILOT_MODEL`, Ctrl-C cancellation, Accessibility preflight for live mode, and Screen Recording permission handling. Never log the API key.
- [x] **Step 2: Document setup and authorized-use scope** plus macOS Accessibility/Screen Recording requirements.
- [x] **Step 3: Add a macOS GitHub Actions workflow** running `swift test` and `swift build -c release` in `ExamPilot/` on relevant changes.
- [x] **Step 4: Run the full package test suite and release build.** Require all XCTest cases to pass and the release executable to link.
- [x] **Step 5: Run repository-level verification** with `python3 scripts/verify_all.py`. Provider/config/structure/dependency checks passed in CI; the unchanged ZeroLose Xcode build failed on the hosted runner and is tracked as a separate baseline/environment result rather than weakening ExamPilot's test/build gate.
- [x] **Step 6: Keep ZeroLose sources untouched** and verify the branch diff is additive to ExamPilot/docs/CI only.

## Self-Review

- Spec coverage: the runtime requirements map to Tasks 1-6; focused-window and boundary-verification hardening discovered during review were added with regression tests.
- Placeholder scan: no deferred implementation markers remain.
- Type consistency: `ScreenFrame`, `ExamDecision`, `ValidatedBatch`, `ScreenCapturing`, `VisionAgent`, `InputDriving`, `ActionBatchExecutor`, and `ExamLoop` have stable names.
- Scope: the implementation deliberately excludes browser-specific adapters, persistence, CAPTCHA handling, and stealth/evasion features.
- Isolation: ZeroLose source files are unchanged relative to `main`.
