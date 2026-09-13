# Agent Handoff Notes — ZeroLose V2 Provider Control Plane Cutover

> **To the active agent working on this repo (Codex / Claude / OpenCode / Antigravity):**
> These notes were originally written by an external reviewer on 2026-09-13 after a full audit of
> `feat/zerolose-agent-runtime-composition` at commit `a4fcd69` — Tasks 1-6 of
> `docs/superpowers/plans/2026-09-13-zerolose-v2-ui-control-plane-cutover.md`.
> They are continuously updated with **verified** status. An item is only marked resolved when
> implementation **and** local verification actually completed; anything else stays open.
> All results below are from `/Users/dogan/Desktop/akilli-asistan` on 2026-09-13.

---

## Verification snapshot (2026-09-13, this session)

- `xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test`
  → **TEST SUCCEEDED**, 458 tests, 0 failures.
- `xcodebuild ... -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` (the exact command
  CI runs) → **TEST SUCCEEDED**, 458 tests, 0 failures.
- `python3 scripts/verify_all.py` → **exit 0**: layout guard, legacy-demolition scan,
  provider-fabric token scan, **provider-authority scan (new)**, **interview-demolition scan
  (new)**, ExamPilot 196 tests, ExamPilot release build, ExamPilot CLI smoke, ZeroLose Debug
  build, **and the full ZeroLose test suite (new)**.
- Release build with ad-hoc signing
  (`-configuration Release -derivedDataPath /tmp/zl_release_dd2 build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`):
  **BUILD SUCCEEDED**, universal `x86_64 arm64`, `Identifier=com.senoldogan.ZeroLose`,
  `codesign --verify --deep --strict` → *valid on disk / satisfies its Designated Requirement*.

Working tree state: all changes below are **uncommitted** in the shared checkout
(`feat/zerolose-agent-runtime-composition`, HEAD `99a4470`). Nothing was pushed, installed,
or merged.

---

## Fixed and verified in this session

### ✅ NEW (was RED) — `UIBoundaryTests.testRuntimeContainerIsCompositionRootNotAUIExecutionBackdoor`
This existing invariant test was **failing on the branch**, and nobody saw it because the
repository gate only ran `xcodebuild build` (medium #4 below).
Root cause: commit `9b52209` moved the live macOS observation source
(`LiveMacOSComputerObservationSourceProvider` with `CGWindowList*` / `AXUIElement*`) into
`V2/Application/ZeroLoseRuntimeContainer.swift`, which that test forbids.

Fix: extracted the provider verbatim to
`V2/Computer/LiveMacOSComputerObservationSourceProvider.swift` (observation semantics and policy
wiring untouched) and removed the then-unused `ApplicationServices` / `CoreGraphics` imports from
the container. Verified by `UIBoundaryTests`, `AgentComputerCompositionTests`,
`ArchitectureBoundaryTests`, `AgentComputerMutationBoundaryTests`, and the full suite.

### ✅ Critical #1 — Emergency Stop / Chat Stop visibility gated by `workspaceMode`
Already fixed before this session by commit `7f6c863`
(`testEmergencyStopIsGatedIndependentlyOfWorkspaceMode`,
`testChatStopRemainsReachableRegardlessOfWorkspaceMode`). Re-verified in `Views/ContentView.swift`:
Emergency Stop is gated on `workspaceMode == .agent || taskRuntimeViewModel.canEmergencyStop`; the
composer Stop button gates on `viewModel.isBusy` only.

### ✅ High #2a — `ProviderControlPlane` check-then-await-then-mutate reentrancy
Already fixed by commit `81132a7` (serialized mutations + concurrent-call regression test).

### ✅ High #2b / #2c — `AgentCommandRuntime.submitUserGoal` / `processAsk` reentrancy
Already fixed by commit `99a4470` (`isStartingRun` / `isBusy` claimed synchronously before the
first `await`, with concurrent-call regression tests).

### ✅ High #3 — boundary suites were only source-text scans
`MainWorkspaceBoundaryTests.testMainWorkspaceAndSettingsShareOneProviderViewModelInstance` now
constructs the real `ContentView` and `SettingsView` with one `ProviderViewModel` and asserts
object identity (`===` and `ObjectIdentifier`), so a duplicated or recomputed provider state is
caught structurally. The literal/text scans remain as a cheap secondary guard.

### ✅ Medium #4 — `scripts/verify_all.py` never ran ZeroLose tests
`verify_zerolose()` now runs an arch-aware concrete-destination `xcodebuild test` after the
unsigned `generic/platform=macOS` build. This is the gate that would have caught the regression
above; it is also asserted by `ProviderLegacyDemolitionTests`.

### ✅ Medium #5 — "no CI for ZeroLose" was stale
`.github/workflows/exampilot.yml` (job name `Repository`, runner `macos-26`) has run
`Test ZeroLose` + `python3 scripts/verify_all.py` since commit `0e0b7ad` (present on `main`).
The CI-equivalent command was re-run locally and passes. No new workflow was needed.

### ✅ Medium #6 — credential-handle revoke path was dead code in production
`ToolFabric.execute` issued credential handles per invocation but never invalidated them, so
handles stayed valid after their invocation and accumulated in the broker.
Fix: new `CredentialBroking.discardHandles(_:)` (handle-scoped; does **not** revoke the scope),
implemented in `InMemoryCredentialBroker` + `KeychainCredentialBrokerAdapter`, called by
`ToolFabric.execute` on both success and failure paths. `InMemoryCredentialBroker` also exposes
`outstandingHandleCount` for the bounded-memory invariant.
Tests (`ToolFabricTests`, `CredentialBrokerTests`): handle invalidated after success, invalidated
after failure, scope stays available across repeated invocations, inventory returns to 0.

### ✅ Task 7 (safe subset, verified) — interview product surface removed
- Deleted: `Views/InterviewVaultView.swift`, `Views/MockInterviewView.swift`,
  `Views/TeleprompterView.swift`, `Views/CheatSheetView.swift`, `Views/KeyboardDisguiseView.swift`,
  `Services/MockInterviewService.swift`, `ViewModels/CheatSheetViewModel.swift`
  (each proven to have zero production consumers outside the deletion set first).
- Removed the Teleprompter window class/state/frame preferences/show/close/toggle/hooks from
  `Services/WindowManager.swift`; `GhostWindow`, hotkey, opacity, sizing and Settings window
  behaviour are untouched. Stored teleprompter defaults were **not** deleted (they are inert).
- Removed `warmUpInterviewContext()` from `ShellFeatureControlling`, `ShellViewModel`, and
  `V2ShellRuntimeController` (including its interview persona prompt and vault priming), and
  dropped the now-unused `responseCacheService` dependency from the shell controller.
- Rewrote `ZeroLose/README.md` and the `Info.plist` privacy strings so the product is described
  as a general Chat/Agent assistant (no interview/meeting framing).
- New permanent guard: `ZeroLoseTests/V2/InterviewDemolitionTests.swift` (deleted files absent,
  zero production references to the removed tokens, ShellFeatureControlling still exposes all
  general capabilities, Info.plist/README copy clean) plus the `verify_zerolose_interview_demolition()`
  step in `scripts/verify_all.py`.

**Task 7 is still OPEN.** The remaining closure is `IntelligenceService` (2 651 lines) and the
services it pulls in (`OllamaService`, `ResponseCacheService`, `TextAnalysis`, `LLMPromptBuilder`,
`VaultService`, `VaultSearchEngine`, `ActiveRoleProfileService`, `InterviewKnowledgeMatcher`,
`Models/InterviewItem.swift`). Those are still reachable through two live general behaviours:
- `V2ShellRuntimeController.processImage` (screen capture, attachment images, auto-screenshot)
  → `IntelligenceService.process(query:imageData:…)`
- `V2ShellRuntimeController.processText` (answer refinement) → same service

Deleting them requires a **vision-capable V2 request**: `ModelMessage` currently carries only
`content: String` (no image payload), while `ModelCapabilities.vision` already exists. That is a
provider-contract migration (OpenAI API + CLI adapters) and its own task — do **not** delete the
general screenshot/refine functionality to satisfy a symbol scan.

### ✅ Task 8 (partial, verified) — legacy provider authority
- Removed the automatic credential import: `Secrets.importOpenCodeKeysIfNeeded()` is gone
  (function + `opencode_keys_autoimport_v1` flag) and is no longer called from
  `ZeroLoseApp.applicationDidFinishLaunching`. Stored keys are untouched; `~/.local/share/opencode/auth.json`
  is never read. Verified: zero production references to `importOpenCodeKeysIfNeeded`, `auth.json`,
  `.local/share/opencode`.
- New permanent guards: `ZeroLoseTests/V2/ProviderLegacyDemolitionTests.swift` — no legacy
  authority token in the primary paths (`Views`, `V2/UI`, `V2/Application`, `V2/Providers`), the
  legacy closure is pinned to exactly `Resources/Constants.swift`, `Services/DependencyContainer.swift`,
  `Services/GroqService.swift`, `Services/IntelligenceService.swift`, `Services/OllamaService.swift`,
  `llm_provider` is readable only by `Constants.swift` + `V2/Migration/SettingsMigrationCoordinator.swift`,
  and the repository gate asserts both new guard functions.
- `scripts/verify_all.py` gained `verify_zerolose_provider_authority()` (primary-path scan + app-launch
  credential-import check).

**Task 8 is still OPEN:** the remaining legacy authority is exactly the closure above
(`AIModelNames.currentProvider()` reading `llm_provider`, `OllamaService` routing, `custom*Model`
defaults), all reachable only through the `IntelligenceService` path. It unblocks together with the
Task 7 remainder. `AIModelNames.whisper` in `GroqService` is the documented compatibility-only
allowance for voice transcription until it is migrated separately.

### ✅ Low #7 — dead state
`isHistoryPresented` removed from `Views/ContentView.swift`.

### ✅ Low #8 / #10 — Keychain error diagnostics
`ProviderViewModel` now appends a non-secret diagnostic (`(Keychain status N)`, `(key rejected)`,
`(no key stored)`) to credential errors instead of discarding the real error.
`ProviderViewModelTests.testKeychainFailuresSurviveAsSafeDiagnosticsThroughTheRealAdapter` exercises
the **real** `KeychainCredentialBrokerAdapter` on an isolated Keychain service: blank key rejected
without a write, secret never echoed, real store/remove round trip, teardown removes the item.

### ✅ Low #9 — accessibility class: investigated, deliberately **not** changed
Attempted hardening to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and verified it: on this
macOS the items are created in the legacy login keychain, where `kSecAttrAccessible` is neither
applied nor returned by `SecItemCopyMatching` (verified with a real adapter store + attribute read;
the returned attributes contain no `kSecAttrAccessible`). The change was reverted because it would
have been an unverifiable claim. `CredentialBrokerTests.testRealKeychainAdapterDoesNotExposeDataProtectionAccessibilityClass`
now pins the observed reality so the claim cannot be made again without evidence. Real hardening
requires a `kSecUseDataProtectionKeychain` migration for **new** items plus an explicit plan for
reading existing legacy items — its own task, and it must not silently make stored keys look missing.

### ✅ Repo hygiene
- An empty stray `.claude/` directory (created by external tooling, no files) was failing the
  layout guard in `verify_all.py`; removed with `rmdir` (empty-only, so no user work could be lost).

---

## Still open

### 🟠 Task 7 remainder — vision-capable V2 request, then delete the interview closure
See above. Blocked on image payload support in the V2 provider contract; do not delete the general
screenshot/refinement capabilities.

### 🟠 Task 8 remainder — retire `LLMProvider` / `AIModelNames` / `OllamaService`
Unblocks with the Task 7 remainder; the pinned closure in `ProviderLegacyDemolitionTests` shrinks
as each file is migrated.

### 🟡 Task 9 — acceptance, install and launch smoke
Done: clean-state preflight, focused regression matrix (full suite green), full repository gate,
Release build + ad-hoc signature verification (identities/hashes above).
Remaining: replace `/Applications/ZeroLose.app` with the verified Release bundle, compare bundle
identity, launch + relaunch smoke, and re-confirm a clean feature HEAD. **These require explicit
user approval** (install replaces an installed app; the plan also requires building from the exact
committed HEAD, which needs a commit first).

### 🟡 Task 10 — PR, exact-head verification, merge, branch/worktree cleanup
Not started. Requires explicit user approval to push, open a PR, and merge.

### 🟢 Low #12 — repo hygiene follow-up
`.freebuff/` (client state from the Freebuff agent host, not user work) is untracked. Confirm the
desired treatment (ignore or leave untracked) at the same time as the Task 10 cleanup.

---

## Suggested next order

1. Get approval for: commit the verified working tree, then Task 9 install/launch smoke.
2. Task 10 (push → PR → exact-head verify → merge → prove cleanup safety → delete merged branches).
3. Task 7 + Task 8 remainder together, in one migration: image payload in `ModelRequest`/`ModelMessage`
   → OpenAI API + CLI adapter support → move `processImage`/`processText` onto `RequestCoordinator`
   → delete `IntelligenceService`, `OllamaService`, `ResponseCacheService`, `TextAnalysis`,
   `LLMPromptBuilder`, the vault/role/matcher services and `Models/InterviewItem.swift`
   → shrink the pinned legacy closure → re-run `python3 scripts/verify_all.py`.
