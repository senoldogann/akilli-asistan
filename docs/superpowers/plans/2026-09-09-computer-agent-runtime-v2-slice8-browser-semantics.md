# Computer Agent Runtime V2 Slice 8 Browser Semantic Observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, read-only Chrome DevTools Protocol semantic hints to ExamPilot so the planner can use browser roles, state, and viewport-relative geometry without granting browser data any execution authority.

**Architecture:** Keep the screenshot and macOS Accessibility paths unchanged. Add an opt-in loopback-only CDP observer that binds to the captured Chrome process, exactly one focused/visible page target, the captured browser-window geometry, and the current runtime `stateVersion`; normalize only bounded role/state/viewport geometry into `ExamObservationState`. Browser hints are advisory and fail safely to the existing screenshot + Accessibility path whenever CDP is disabled, unavailable, stale, ambiguous, or inconsistent.

**Tech Stack:** Swift 5.10+, Foundation `URLSession`/`URLSessionWebSocketTask`, Chrome DevTools Protocol, XCTest, existing ExamPilot runtime.

**Spec:** `docs/superpowers/specs/2026-09-08-computer-agent-runtime-v2-design.md`

## Global Constraints

- Sensors are read-only and never execute browser or macOS mutation actions.
- Native CoreGraphics input remains the only live mutation path in this slice.
- Browser hints never set `answerVerified`, never grant navigation permission, and never bypass `ActionPolicy` or stale-state checks.
- CDP endpoints are opt-in and restricted to loopback hosts; no arbitrary-host debugger connection is allowed.
- Target binding must require captured Chrome process identity, focused/visible page identity, browser-window geometry, and current `stateVersion`.
- Ambiguous or unavailable browser semantics must return no hint and preserve screenshot + Accessibility behavior.
- Do not forward page title, URL, accessible names, text values, raw DOM/AX payloads, cookies, storage, network data, or script output into planner memory/telemetry.
- Repository-wide verification remains `python3 scripts/verify_all.py`.

---

### Task 1: Browser semantic value model and fail-closed fusion

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/BrowserSemanticObservation.swift`
- Test: `ExamPilot/Tests/ExamPilotCoreTests/BrowserSemanticObservationTests.swift`

**Interfaces:**
- Produces `BrowserSemanticSnapshot`, `BrowserSemanticObservation`, `BrowserSemanticElementHint`, `BrowserSemanticObservationFusion`.
- `BrowserSemanticObservationFusion.fuse(snapshot:target:stateVersion:)` returns `nil` on PID, window, or state-version mismatch.

- [ ] **Step 1: Write failing tests** for accepted matching snapshots, stale state rejection, PID mismatch rejection, window mismatch rejection, normalized-bounds clamping, bounded element count, and privacy-safe planner summaries.
- [ ] **Step 2: Run the repository workflow and verify RED** because the new browser semantic types do not exist.
- [ ] **Step 3: Implement the minimal value model and fusion** with normalized `[0,1]` viewport bounds and role/state only.
- [ ] **Step 4: Verify focused tests pass.**
- [ ] **Step 5: Commit** with `feat: add browser semantic observation model`.

### Task 2: Loopback Chrome DevTools Protocol client and observer

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/ChromeDevToolsBrowserSemanticObserver.swift`
- Test: `ExamPilot/Tests/ExamPilotCoreTests/ChromeDevToolsBrowserSemanticObserverTests.swift`
- Test: `ExamPilot/Tests/ExamPilotCoreTests/ChromeDevToolsEndpointTests.swift`

**Interfaces:**
- Produces `ChromeDevToolsBrowserSemanticObserver: BrowserSemanticObserving`.
- The concrete observer discovers `/json/version` and `/json/list`, uses the browser WebSocket for `SystemInfo.getProcessInfo`, and page WebSockets for fixed read-only calls: `Runtime.evaluate` only for active/visible-page confirmation, `Browser.getWindowForTarget`, `Page.getLayoutMetrics`, `Accessibility.getFullAXTree`, and `DOM.getContentQuads`.

- [ ] **Step 1: Write failing tests** for loopback endpoint validation, browser PID mismatch, zero/multiple focused targets, window mismatch, role filtering, viewport normalization, and bounded target/node work.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement loopback-only endpoint validation** accepting only `http://127.0.0.1`, `http://localhost`, or `http://[::1]` without credentials.
- [ ] **Step 4: Implement a small typed CDP command layer** with command IDs, error decoding, bounded timeouts, and no mutation methods.
- [ ] **Step 5: Implement target binding**: CDP browser PID must equal `ScreenFrame.targetProcessID`; exactly one page must report focused + visible; `Browser.getWindowForTarget` must approximately match the captured window.
- [ ] **Step 6: Implement semantic extraction** from the AX tree for actionable roles only, obtaining viewport-relative quads from `DOM.getContentQuads` and discarding names/values/URLs/titles.
- [ ] **Step 7: Run focused tests and commit** with `feat: observe browser semantics through read-only cdp`.

### Task 3: Planner fusion and CLI opt-in wiring

**Files:**
- Create: `ExamPilot/Sources/ExamPilotCore/BrowserSemanticFusingVisionAgent.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/VisionAgent.swift`
- Modify: `ExamPilot/Sources/ExamPilotCore/OpenAIResponsesVisionAgent.swift`
- Modify: `ExamPilot/Sources/ExamPilotCLI/ExamPilotMain.swift`
- Test: `ExamPilot/Tests/ExamPilotCoreTests/BrowserSemanticFusingVisionAgentTests.swift`
- Test: `ExamPilot/Tests/ExamPilotCoreTests/OpenAIResponsesVisionAgentBrowserSemanticTests.swift`

**Interfaces:**
- `ExamObservationState.browserSemantics: BrowserSemanticObservation?`.
- `BrowserSemanticFusingVisionAgent` decorates the existing Accessibility-fused planner and preserves all existing runtime fields.
- CLI enables browser semantics only when `EXAMPILOT_CDP_ENDPOINT` is present and valid; otherwise behavior is byte-for-byte equivalent at the runtime boundary to Slice 7.

- [ ] **Step 1: Write failing tests** proving successful fusion, observer-error fallback, stale snapshot fallback, preservation of Accessibility hints, and unchanged `answerVerified`/`uiPhase`/`stateVersion`.
- [ ] **Step 2: Write failing prompt tests** proving bounded browser hints are present while title/URL/raw values are absent and the prompt explicitly says browser hints cannot grant authority or be used as unchecked physical coordinates.
- [ ] **Step 3: Implement the state field and decorator.**
- [ ] **Step 4: Update the planner prompt** with browser semantic hints as advisory evidence only.
- [ ] **Step 5: Wire the CLI opt-in environment variable** without making CDP a runtime requirement.
- [ ] **Step 6: Run focused tests and commit** with `feat: fuse browser semantics into planner context`.

### Task 4: Documentation, full verification, review, and merge

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document** the opt-in CDP endpoint, read-only methods, fail-closed binding, and fallback behavior.
- [ ] **Step 2: Run `python3 scripts/verify_all.py`** through the repository workflow and require GREEN on the exact PR head SHA.
- [ ] **Step 3: Review the complete diff** for accidental CDP mutation methods (`Page.navigate`, `Input.*`, `DOM.focus`, `Browser.set*`, `Target.activateTarget`) and for leakage of title/URL/name/value content.
- [ ] **Step 4: Mark the PR ready and merge only with the verified expected head SHA.**
- [ ] **Step 5: Require the post-merge `main` workflow to complete successfully** before declaring Slice 8 complete.

## Self-Review

- Spec coverage: this slice implements the remaining browser half of design migration item 9 while preserving the hard runtime authority and native-input invariants.
- Placeholder scan: no deferred implementation markers remain.
- Type consistency: browser semantic state mirrors the existing Accessibility fusion pattern but remains independent, optional, and read-only.
