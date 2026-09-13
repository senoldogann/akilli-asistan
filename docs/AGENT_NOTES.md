# Agent Handoff Notes — ZeroLose V2 Provider Control Plane Cutover

> **To the active agent working on this repo (Codex / Claude / OpenCode / Antigravity):**
> These notes were written by an external reviewer on 2026-09-13 after a full audit of
> `feat/zerolose-agent-runtime-composition` at commit `a4fcd69` — Tasks 1-6 of
> `docs/superpowers/plans/2026-09-13-zerolose-v2-ui-control-plane-cutover.md`.
> The audit included reading the plan/design docs, running `python3 scripts/verify_all.py`
> (passed), running the focused `ZeroLoseTests` suite for the changed area via
> `xcodebuild test` (passed, 0 failures), full-file source reads, and independent
> cross-verification of every finding below. This document replaces the prior
> (2026-08-25) notes, which described the pre-V2 architecture and are now obsolete.
> Read this before starting Task 7.

---

## ✅ Verified current state (2026-09-13)

- Tasks 1–6 of the cutover plan are committed and match their described contracts.
  Task 7 (interview removal), Task 8 (legacy provider authority removal), Task 9
  (release/install/smoke), Task 10 (PR/merge) are not started yet — expected.
- `python3 scripts/verify_all.py`: **SUCCESS** (layout guard, legacy-demolition scan,
  provider-fabric forbidden-token scan, ExamPilot 196 tests, ExamPilot release build,
  ExamPilot CLI smoke, ZeroLose Xcode Debug build).
- Focused `ZeroLoseTests` run — `ModelProviderFabricTests`, `ProviderControlPlaneTests`,
  `ProviderViewModelTests`, `RequestCoordinatorTests`, `ModelPlanningAdapterTests`,
  `AgentApplicationCommandTests`, `MainWorkspaceBoundaryTests`, `SettingsSurfaceTests`,
  `ProviderCompositionTests`, `AskModeBoundaryTests`, `ViewModelProjectionTests` —
  **`** TEST SUCCEEDED **`, 0 failures.**
- Architecture is sound: immutable `ProviderSelectionSnapshot`, actor-isolated
  `ModelProviderFabric` / `ProviderControlPlane`, per-run orchestrator builder in
  `AgentCommandRuntime`. Request/cancellation binding to an explicit provider (bypassing
  the fabric's mutable `selectedProviderID`) is correctly implemented and tested
  (`testExplicitProviderStreamIgnoresMutableSelection`,
  `testRequestUsesBoundProviderAndModelAfterFabricSelectionChanges`). Keep this direction.
- No secret leakage found in `ProviderControlSnapshot` / `ProviderPresentation` /
  UserDefaults / logs (independently verified via full-file reads + `rg` scans).

---

## 🔴 Critical — fix before any Task 9 install/smoke test

### 1. Emergency Stop / Stop button visibility is gated by `workspaceMode`, not by live session state
**File:** `ZeroLose/ZeroLose/Views/ContentView.swift:314`, `:363-378`, `:974`, `:989`

`if workspaceMode == .agent { ... }` wraps Pause/Resume/Cancel/**Emergency Stop**
(lines 315–378). `if workspaceMode == .chat && viewModel.isBusy { ... }` wraps the Chat
Stop button (lines 974–988), falling through to the mic controls otherwise (989).
`workspaceMode` is a presentation-only `@State` with no relationship to whether a
session is actually live.

**Impact:** if the user switches the segmented control away from the mode with the
live session, the corresponding stop control disappears from the UI entirely — even
though `taskRuntimeViewModel.canEmergencyStop` / `viewModel.isBusy` may still be true
and the session (including real mouse/keyboard mutation) keeps running. This directly
violates the repo's own non-negotiable rule (AGENTS.md / CONTRIBUTING.md): *"Emergency
stop/cancellation checks must remain effective"* / *"Do not weaken ... Emergency Stop
... to simplify UI work."* This regression was introduced by the Task 5 `ContentView`
rewrite in this branch.

**Fix:** gate visibility on real session liveness (`taskRuntimeViewModel.hasActiveSession`
/ `viewModel.isBusy`), independent of `workspaceMode`.

---

## 🟠 High — fix before calling Task 6 verification complete

### 2. Check-then-await-then-mutate reentrancy race, repeated in 3 places
Swift actors and `@MainActor` types are reentrant across `await` — a guard checked
before a suspension point can be passed twice if state isn't claimed synchronously
first. None of the three sites below claim state before their first `await`, and none
have a concurrent-call regression test.

**2a. `ZeroLose/ZeroLose/V2/Providers/ProviderControlPlane.swift`** —
`selectProvider` (115–143), `selectModel` (145–182), `refresh` (87–109): each
unconditionally overwrites `cachedSnapshot` at the end, after one or more `await`s
(`presentations()` walks every registered provider's CLI-backed status/model
discovery — not free). `ZeroLose/ZeroLose/V2/UI/ProviderSelectorView.swift:11,39,52`
spawns a bare `Task { await viewModel.selectProvider(...) }` / `selectModel(...)` per
tap with **no debounce/disable**, so this is reachable from ordinary fast clicking.
**Impact:** the selection that *finishes last* wins, not the one *clicked last* — the
app can silently end up using the wrong provider/model for the next request, which
contradicts the design's own "no silent fallback" contract.
**Fix:** add a monotonic generation/ticket check before committing `cachedSnapshot`
(discard a result if a newer call has started since).

**2b. `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift:112-120`**
(`actor AgentCommandRuntime.submitUserGoal`) — the "already active" guard reads
`self.orchestrator` before two `await`s (`selectionProvider()` at 118,
`orchestratorBuilder.make` at 119); `self.orchestrator` is only reassigned at 120.
**Impact:** two near-simultaneous goal submissions can each pass the guard and build
their own orchestrator. The losing run keeps executing (planning/tool/mutation calls)
but `pause`/`resume`/`cancel` only ever target `self.orchestrator`, so the orphaned run
becomes untargetable by those three (only the shared-flag `emergencyStop` still reaches
it — not a total safety bypass, but targeted control is broken).
**Fix:** claim a "starting" placeholder synchronously before the first `await`.

**2c. `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift:702-710`**
(`processAsk`) — `guard !isBusy else { throw ... }` at 705 precedes
`await selectionProvider()` at 708; `isBusy = true` is only set at 710.
**Impact:** two near-simultaneous chat sends can both pass the guard; `activeAskSessionID`
/ `activeAskSelection` (728–729) become last-write-wins, so `stopResponse()` can target
the wrong session or silently no-op for the orphaned one.
**Fix:** set `isBusy = true` synchronously as part of the guard, before any `await`.

**Testing gap common to 2a/2b/2c:** `ProviderControlPlaneTests.swift`,
`AgentApplicationCommandTests.swift`, and `AskModeBoundaryTests.swift` are all
sequential-only (`await` one call, then the next) — add at least one concurrent-call
(`async let` / `TaskGroup`) regression test per site.

### 3. `MainWorkspaceBoundaryTests` / `SettingsSurfaceTests` are source-text scans, not structural checks
Both suites read the file as a string and assert `source.contains("...")`, plus a
hand-rolled brace-counter to slice a property/function body that is naive about braces
inside string literals. They currently prove true things (independently verified — e.g.
`providerViewModel` really is a single stored `let` shared by `ContentView` and
`SettingsView`), but wouldn't catch a future regression via indirection (e.g.
`providerViewModel` becoming a computed property, or a duplicate provider picker added
through another file that doesn't contain the banned literal token).
**Fix:** add at least one structural/identity check (e.g. `ObjectIdentifier` equality
between the instance `ContentView` and `SettingsView` actually receive) alongside the
text scans.

---

## 🟡 Medium — repo-wide gaps, not introduced by this branch

### 4. `scripts/verify_all.py`'s `verify_zerolose()` only builds, never tests
`scripts/verify_all.py:231-257` runs `xcodebuild ... build` with
`-destination generic/platform=macOS` (which doesn't support the `test` action anyway).
The one command `CONTRIBUTING.md` tells contributors to run before opening a PR never
executes `ZeroLoseTests` — including every test added in Tasks 1–6. Add a real
`xcodebuild test` step with a concrete runtime destination.

### 5. No CI for ZeroLose at all
`.github/workflows/` contains only `exampilot.yml`. All ZeroLose-side verification
(including this entire V2 control-plane migration) runs on local discipline only, with
no automated check on push/PR.

### 6. Credential-handle revoke path is dead code in production
`AutonomousRuntime` / `credentialHandleDiscarder` is constructed only in
`AutonomousRuntimeResumeTests.swift:180`; production (`ZeroLoseRuntimeContainer.swift:241-248`)
wires `AgentCommandRuntime` instead, which never calls
`CredentialBroker.revoke(scope:)` (only implementation:
`KeychainCredentialBrokerAdapter.swift:35`). Mitigated today because
`isCredentialPresent`/`isValid` re-read Keychain live (self-healing), but the intended
credential-lifecycle discipline isn't wired into any live path. Pre-existing, surfaced
now because `ZeroLoseRuntimeContainer.swift` changed 172 lines in this branch.

---

## 🟢 Low

7. `ContentView.swift:59` — `isHistoryPresented` state declared, never read/written; dead, safe to delete.
8. `ProviderViewModel.swift:73-76,85-88` — `saveOpenAIAPIKey`/`removeOpenAIAPIKey` catch
   blocks discard the real thrown error (e.g. Keychain `OSStatus`), surfacing only a
   generic string. Safe for secrecy, harder to debug real Keychain failures.
9. `KeychainCredentialBrokerAdapter.swift:89` — uses `kSecAttrAccessibleAfterFirstUnlock`,
   not `...ThisDeviceOnly`; consistent with existing convention, minor hardening
   opportunity only.
10. `testCredentialErrorsNeverEchoSubmittedKey` only exercises a mock settings
    controller, not the real Keychain adapter — doesn't hide a live gap today (the
    ViewModel's catch-all makes the guarantee adapter-agnostic in practice), but
    wouldn't catch a future regression introduced only in the real adapter.
11. `ZeroLose/README.md` and `Info.plist`'s `NSScreenCaptureUsageDescription` /
    `NSMicrophoneUsageDescription` still describe an interview/meeting assistant —
    expected, already in Task 7's file list. Just don't install/demo the current build
    before Task 7 lands, or the user will see stale permission-prompt copy.
12. Repo hygiene, not a code bug (worth confirming, not fixing in code): a remote
    branch named exactly `feat/zerolose-agent-runtime-composition` existed on GitHub and
    was deleted with no associated PR (`git fetch --prune` detected the deletion; `gh`
    found no PR under that name). This worktree was cloned from a separate local path
    `/Users/dogan/akilli-asistan`. The design doc already pins
    `/Users/dogan/Desktop/akilli-asistan` as the sole active development root — confirm
    nothing is concurrently in progress at the other path under the same branch name.

---

## Suggested fix order

1. Critical #1 (Emergency Stop visibility) — safety-relevant, smallest diff.
2. High #2a/2b/2c (reentrancy races) — same shape of fix (claim-before-await) in three
   places; add one concurrent-call test per site.
3. High #3 (boundary-test hardening) — optional but cheap alongside #2.
4. Resume Task 7 of the cutover plan.
5. Medium #4/#5/#6 — track as separate repo-infrastructure follow-ups, not blockers for
   this feature branch.
