# ExamPilot Visual Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone macOS visual computer-use agent that observes authorized Chrome-based quiz/exam UIs from screenshots, plans safe multi-action batches, executes real mouse/keyboard/scroll input, and verifies progress without DOM/CDP/extensions or clipboard use.

**Architecture:** Add a standalone Swift Package at `ExamPilot/` with an `ExamPilotCore` library and `exampilot` executable. Native ScreenCaptureKit/CoreGraphics services are isolated behind protocols so planning, validation, loop behavior, and provider decoding are unit-testable without posting real input.

**Tech Stack:** Swift 6 package syntax with macOS 14 deployment, Foundation, AppKit, CoreGraphics, ScreenCaptureKit, ImageIO, UniformTypeIdentifiers, XCTest.

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

- [ ] **Step 1: Write failing tests** proving actions after the first boundary are dropped, more than 12 actions are rejected, waits over 5 seconds are rejected, scroll values beyond ±1400 are rejected, and click coordinates outside the screen rectangle are rejected.
- [ ] **Step 2: Run `cd ExamPilot && swift test --filter ActionBatchPolicyTests`** and confirm failure because the package/contracts are absent.
- [ ] **Step 3: Implement the minimal Codable domain model and validation policy.** `ExamAction` uses a tagged `kind` plus optional fields (`x`, `y`, `text`, `key`, `amount`, `milliseconds`, `boundary`) to match strict structured-output JSON without custom enum decoding complexity.
- [ ] **Step 4: Re-run the filtered tests** and confirm pass.
- [ ] **Step 5: Commit** with `feat(exampilot): add action contracts and batch policy`.

### Task 2: Screen capture and visual change verification

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ScreenCaptureService.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/VisualChangeDetector.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/VisualChangeDetectorTests.swift`

**Interfaces:**
- Produces `ScreenCapturing.capture() async throws -> ScreenFrame`.
- Produces `VisualChangeDetector.score(before:after:) -> Double` and `hasMeaningfulChange(before:after:) -> Bool`.

- [ ] **Step 1: Write tests** generating solid and split-tone `CGImage` fixtures in memory; identical images score approximately 0 and materially different fixtures cross the configured threshold.
- [ ] **Step 2: Run the filtered tests** and observe failure because the detector is missing.
- [ ] **Step 3: Implement a deterministic grayscale fingerprint** by sampling a fixed grid from `CGImage` pixel data and normalized mean absolute difference; implement `ScreenCaptureService` using `SCScreenshotManager.captureImage(in:)` over the union of `NSScreen.screens` frames and JPEG encode the frame for model input.
- [ ] **Step 4: Run tests** and confirm pass.
- [ ] **Step 5: Commit** with `feat(exampilot): add screenshot capture and visual verification`.

### Task 3: Human-style native input executor

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/InputDriver.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/ActionBatchExecutor.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ActionBatchExecutorTests.swift`

**Interfaces:**
- Produces `InputDriving` protocol with `moveAndClick`, `typeText`, `pressKey`, `scroll`, and `wait` async methods.
- Produces `NativeInputDriver` for live execution and `ActionBatchExecutor.execute(_:dryRun:shouldStop:)`.

- [ ] **Step 1: Write tests with a recording fake input driver** proving sequential execution order, dry-run produces no input calls, finish terminates the batch, and cancellation is checked between actions.
- [ ] **Step 2: Run filtered tests** and confirm failure before implementation.
- [ ] **Step 3: Implement `NativeInputDriver`.** Mouse movement uses a cubic Bezier curve from current CG cursor location to target and posts global HID events. Unicode text is sent grapheme-by-grapheme via `CGEventKeyboardSetUnicodeString`; newline/tab use key events. Inter-key delay is bounded and injectable. Scroll uses `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`.
- [ ] **Step 4: Re-run tests** and confirm fake-based behavior passes without moving the real cursor.
- [ ] **Step 5: Commit** with `feat(exampilot): add native mouse keyboard and scroll executor`.

### Task 4: Structured visual reasoning provider

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/VisionAgent.swift`
- Create: `ExamPilot/Sources/ExamPilotCore/OpenAIResponsesVisionAgent.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/OpenAIResponsesVisionAgentTests.swift`

**Interfaces:**
- Produces `VisionAgent.decide(frame:state:) async throws -> ExamDecision`.
- `OpenAIResponsesVisionAgent` accepts an injected `URLSessionProtocol`/transport for tests and runtime `apiKey`, `model`.

- [ ] **Step 1: Write fixture-decoding tests** for a Responses API payload containing an `output_text` JSON string matching `ExamDecision`, plus malformed/missing-output error cases.
- [ ] **Step 2: Run filtered tests** and confirm failure before implementation.
- [ ] **Step 3: Implement the request** to `POST https://api.openai.com/v1/responses` with screenshot JPEG as a base64 `data:image/jpeg;base64,...` `input_image`, a concise exam-control prompt, and `text.format.type=json_schema` strict structured output. Default model is `gpt-5.6-sol`; runtime may override it.
- [ ] **Step 4: Re-run tests** and confirm decoding/request construction passes with the fake transport.
- [ ] **Step 5: Commit** with `feat(exampilot): add structured vision planner`.

### Task 5: Observe-plan-batch-verify runtime loop

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ExamLoop.swift`
- Create: `ExamPilot/Tests/ExamPilotCoreTests/ExamLoopTests.swift`

**Interfaces:**
- Produces `ExamLoop.run() async -> ExamRunResult`.
- Consumes `ScreenCapturing`, `VisionAgent`, `ActionBatchPolicy`, `ActionBatchExecutor`, and `VisualChangeDetector`.

- [ ] **Step 1: Write async tests with fakes** proving: a progress batch continues; three no-change batches abort; `finish` returns success; invalid model batches trigger fresh observation without input; dry-run plans but does not mutate; stop signal exits before the next action.
- [ ] **Step 2: Run filtered tests** and confirm failure before implementation.
- [ ] **Step 3: Implement the bounded loop** with concise state passed back to the model, maximum 200 observation cycles per run, three consecutive non-progress limit, and explicit terminal reasons.
- [ ] **Step 4: Re-run tests** and confirm pass.
- [ ] **Step 5: Commit** with `feat(exampilot): add visual agent execution loop`.

### Task 6: CLI, permission checks, documentation, and CI

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCLI/main.swift`
- Create: `ExamPilot/README.md`
- Create: `.github/workflows/exampilot.yml`

**Interfaces:**
- Executable `exampilot [--dry-run] [--model MODEL]`.

- [ ] **Step 1: Implement CLI argument parsing** with `OPENAI_API_KEY`, `EXAMPILOT_MODEL`, Ctrl-C cancellation, Accessibility preflight for live mode, and clear screen-capture/API errors. Never log the API key.
- [ ] **Step 2: Document setup and authorized-use scope** plus macOS Accessibility/Screen Recording permission requirements.
- [ ] **Step 3: Add a macOS GitHub Actions workflow** running `swift test` and `swift build -c release` in `ExamPilot/` on relevant changes.
- [ ] **Step 4: Run the full package test suite and release build.** Expected: all XCTest cases pass; release executable links successfully.
- [ ] **Step 5: Run repository-level verification where available** with `python3 scripts/verify_all.py`; record any environment-specific limitation without weakening ExamPilot test requirements.
- [ ] **Step 6: Commit** with `feat(exampilot): ship visual computer-use CLI`.

## Self-Review

- Spec coverage: every runtime requirement maps to Tasks 1-6; ZeroLose remains untouched.
- Placeholder scan: no deferred implementation markers are used.
- Type consistency: `ScreenFrame`, `ExamDecision`, `ValidatedBatch`, `ScreenCapturing`, `VisionAgent`, `InputDriving`, `ActionBatchExecutor`, and `ExamLoop` have single stable names across tasks.
- Scope: the initial slice deliberately excludes browser-specific adapters, persistence, captcha handling, and stealth/evasion features.
