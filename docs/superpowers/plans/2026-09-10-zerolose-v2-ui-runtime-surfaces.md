# ZeroLose V2 Runtime UI Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the missing visible V2 UI surface by keeping the existing Liquid Glass chat shell while adding a real runtime status strip and dashboard backed by V2 projections, EventStore activity, typed commands, and the existing authority boundary.

**Architecture:** The current visual shell remains the primary chat experience, as required by the V2 design. A compact always-visible runtime strip exposes V2 state and opens a focused `RuntimeDashboardView`. Runtime/tool activity is recorded to the append-only EventStore and projected into UI models; SwiftUI never reaches ToolFabric, PolicyKernel, raw credentials, or native input directly. Unsupported autonomous/approval actions remain visibly disabled/fail-closed instead of pretending to work.

**Tech Stack:** SwiftUI, Observation `@Observable`, Swift Concurrency, SQLiteEventStore, XCTest, existing Liquid Glass helpers.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Preserve the useful existing SwiftUI/macOS shell; this is not a full visual redesign.
- Views and V2 view models never execute tools, access ToolFabric/PolicyKernel, raw credentials, or physical input directly.
- Timeline is an EventStore projection; UI must not fabricate successful execution state.
- A tool receipt may be shown as executed/completed, but task/goal success requires verification evidence.
- Authority remains typed runtime state; no new `commandApprovalMode` AppStorage authority path.
- Existing `full` legacy approval does not become V2 Full Access.
- Unsupported autonomous goal operations and approvals remain fail-closed and visibly unavailable until their production orchestrator/store exists.
- Keep `.freebuff/` untouched.
- TDD is required for behavior changes. Final gate: `python3 scripts/verify_all.py`.

---

### Task 1: Add EventStore-backed runtime activity projection

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Events/RuntimeEventRecorder.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/RuntimeProjectionCoordinator.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/TimelineProjection.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/V2NativeToolRuntime.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RuntimeProjectionCoordinatorTests.swift`

**Interfaces:**
- `RuntimeEventRecorder.recordTool(invocationID:toolID:state:summary:tainted:)` appends sequential events to one runtime stream.
- `RuntimeProjectionCoordinator.refresh()` pulls events after its last sequence and feeds `TimelineProjection`.
- `V2NativeToolRuntime` receives an optional recorder and records model-visible native tool start/completion/failure without bypassing ToolFabric.

- [ ] **Step 1: Write failing projection/sequence tests**

Create tests proving that two recorder writes receive increasing EventStore sequences, `refresh()` consumes only unseen events, and tool completion is rendered as `.executed` rather than task `.succeeded`.

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeProjectionCoordinatorTests test CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failure because recorder/coordinator and `.executed` state do not exist.

- [ ] **Step 3: Implement minimal recorder/coordinator**

Use a fixed production stream id `runtime:main`. Initialize the recorder sequence from existing stream events before the first append so restart cannot collide with the SQLite `(stream_id, sequence)` primary key. Payloads contain presentation-safe metadata only; no arguments JSON, credential handle, headers, or secrets.

- [ ] **Step 4: Instrument V2 native tools**

Record start/completion/failure around the existing `ToolFabric.execute` call. Do not change policy, registry revision, credential, or provider dispatch semantics.

- [ ] **Step 5: Verify GREEN and commit**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeProjectionCoordinatorTests test CODE_SIGNING_ALLOWED=NO
git diff --check
git add ZeroLose/ZeroLose/V2/Events/RuntimeEventRecorder.swift ZeroLose/ZeroLose/V2/UI/RuntimeProjectionCoordinator.swift ZeroLose/ZeroLose/V2/UI/TimelineProjection.swift ZeroLose/ZeroLose/V2/Application/V2NativeToolRuntime.swift ZeroLose/ZeroLoseTests/V2/RuntimeProjectionCoordinatorTests.swift
git commit -m "feat: project V2 runtime activity from event store"
```

### Task 2: Compose the runtime ledger and expose safe dashboard state

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/TaskRuntimeViewModel.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/ApprovalViewModel.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RuntimeDashboardStateTests.swift`

**Interfaces:**
- Container owns one `SQLiteEventStore`, one `RuntimeEventRecorder`, one `TimelineProjection`, and one `RuntimeProjectionCoordinator`.
- Container exposes projection/view-model references only; SwiftUI never receives the EventStore or recorder.
- `TaskRuntimeViewModel` exposes presentation-safe `hasActiveGoal`, status text, and control availability.
- `ApprovalPresentation` carries the spec-required display fields when such events exist: operation summary, tool/provider, risk/effect, destination, credential scope, taint, mutation status, and approval reason. With no production approval source, pending remains empty rather than fabricated.

- [ ] **Step 1: Write failing state tests**

Test idle state, active-goal control availability, and detailed approval presentation without direct execution dependencies.

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeDashboardStateTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement container wiring and focused presentation state**

Store the ledger at `~/Library/Application Support/ZeroLose/V2/runtime.sqlite3`, creating the directory if required. If store initialization fails, keep the shell usable and expose a projection error string; never fall back to a second execution runtime.

- [ ] **Step 4: Verify GREEN and commit**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeDashboardStateTests test CODE_SIGNING_ALLOWED=NO
git diff --check
git add ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift ZeroLose/ZeroLose/V2/UI/TaskRuntimeViewModel.swift ZeroLose/ZeroLose/V2/UI/ApprovalViewModel.swift ZeroLose/ZeroLoseTests/V2/RuntimeDashboardStateTests.swift
git commit -m "feat: compose V2 runtime dashboard state"
```

### Task 3: Add the visible runtime strip and RuntimeDashboardView

**Files:**
- Create: `ZeroLose/ZeroLose/V2/UI/RuntimeDashboardView.swift`
- Modify: `ZeroLose/ZeroLose/Views/ContentView.swift`
- Modify: `ZeroLose/ZeroLose/Services/WindowManager.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/UIBoundaryTests.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RuntimeDashboardViewTests.swift`

**Interfaces:**
- `ContentView` receives `TaskRuntimeViewModel`, `ApprovalViewModel`, `TimelineProjection`, and `RuntimeProjectionCoordinator` from the V2 runtime container.
- An always-visible compact strip shows `Runtime`, authority mode, current runtime status, and pending approval count.
- Clicking the strip opens `RuntimeDashboardView` inside the existing Liquid Glass shell.
- Dashboard sections: Runtime, Controls, Pending Approvals, Activity Timeline.

- [ ] **Step 1: Write failing source/boundary tests**

Require `RuntimeDashboardView` to exist and `WindowManager` to pass only V2 view models/projections from `ZeroLoseRuntimeContainer`. Guard dashboard sources against `ToolFabric`, `PolicyKernel`, `CredentialHandle`, `Secrets.`, `CGEvent`, `AXUIElement`, and legacy ACTION symbols.

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/UIBoundaryTests -only-testing:ZeroLoseTests/RuntimeDashboardViewTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement the visible strip/dashboard**

Preserve the chat layout and Liquid Glass style. Runtime controls call only `TaskRuntimeViewModel` typed commands. Disable Pause/Resume/Stop when there is no active goal; show `Autonomous runtime not configured` rather than routing those actions into chat. Approval buttons render only for real pending items and call `ApprovalViewModel.approve/deny`.

- [ ] **Step 4: Refresh projections safely**

Start a cancellation-aware dashboard refresh task while the main view is visible. Poll the local EventStore at a modest interval (1 second) and stop on disappearance. Projection errors appear as non-fatal status text.

- [ ] **Step 5: Verify GREEN and commit**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/UIBoundaryTests -only-testing:ZeroLoseTests/RuntimeDashboardViewTests test CODE_SIGNING_ALLOWED=NO
git diff --check
git add ZeroLose/ZeroLose/V2/UI/RuntimeDashboardView.swift ZeroLose/ZeroLose/Views/ContentView.swift ZeroLose/ZeroLose/Services/WindowManager.swift ZeroLose/ZeroLoseTests/V2/UIBoundaryTests.swift ZeroLose/ZeroLoseTests/V2/RuntimeDashboardViewTests.swift
git commit -m "feat: expose V2 runtime dashboard in ZeroLose UI"
```

### Task 4: Full acceptance, install, and manual-test handoff

**Files:**
- Modify only if a deterministic release guard is missing: `scripts/verify_all.py`

- [ ] **Step 1: Run full ZeroLose tests**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: Run repository gate and architecture guards**

```bash
python3 scripts/verify_all.py
git diff --check
git grep -n '\[ACTION:\|actionRegex\|handleActions' -- ZeroLose
```

Expected: tests/builds PASS, whitespace clean, forbidden legacy grep empty.

- [ ] **Step 3: Build a Release app from the feature HEAD**

Build the macOS application, validate its bundle id/signature, and do not overwrite the rollback copy until the new app has passed launch smoke testing.

- [ ] **Step 4: Install and smoke-test locally**

Install to `/Applications/ZeroLose.app`, launch, verify the process remains alive and an onscreen window exists. Confirm the Runtime strip is visible through an accessibility/UI test where available; otherwise leave the app open for the user's manual visual confirmation and preserve rollback.

- [ ] **Step 5: Push/PR only after local acceptance**

Push `feat/zerolose-v2-ui-runtime-surfaces`, open a PR, require exact-head Repository CI GREEN, then merge and run `python3 scripts/verify_all.py` on merged `main` before branch/worktree cleanup.
