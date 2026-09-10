# ZeroLose Final Acceptance and Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the redesigned ZeroLose product end-to-end, merge only exact-head green code, install the final macOS application, and leave repository/worktrees clean.

**Architecture:** No product features are added here. Acceptance tests exercise only public/focused V2 product boundaries with deterministic fakes. Personal subscriptions/API credentials are tested only by an explicit local smoke script; CI never depends on them.

**Tech Stack:** XCTest/XCUITest, xcodebuild, Python, GitHub Actions, codesign, LaunchServices.

**Spec:** `docs/superpowers/specs/2026-09-11-zerolose-general-autonomous-agent-redesign.md`

## Global Constraints

- CI requires no personal provider subscription or API secret.
- Live provider checks are explicit opt-in local smoke tests.
- Never print/persist credential values or provider session tokens.
- Exact-head CI must pass before merge; post-merge `main` CI must pass on the resulting merge SHA.
- Preserve unrelated worktrees and `.freebuff/`.
- Any defect found here returns to the owning implementation plan and gets a RED regression test; do not patch behavior directly inside acceptance work.

---

### Task 1: Provider and context acceptance matrix

**Files:**
- Create: `ZeroLose/ZeroLoseTests/Acceptance/ProviderAcceptanceTests.swift`
- Create: `ZeroLose/ZeroLoseTests/Acceptance/ContextAcceptanceTests.swift`

- [ ] **Step 1: Add provider product-contract tests**

Using `RecordingModelProvider`/`FixtureCLIProcessRunner`, cover in one suite:

```swift
func testSelectedProviderFailureNeverInvokesAnotherProvider() async throws
func testCodexCommandIsReadOnlyAndUsesIsolatedWorkspace() async throws
func testClaudeCommandDisablesToolsHooksChromeAndSessionPersistence() async throws
func testOpenCodeUsesDenyAllPermissionConfigAndNoDirectRemoteAPI() async throws
func testAntigravityRequiresAgyAndNeverSkipsPermissions() async throws
func testOpenAIQuotaAndRateLimitRemainProviderSpecific() async throws
func testProviderStatusesContainNoCredentialMaterial() async throws
```

Each test must assert both result and negative authority boundary (e.g. other provider request count zero; dangerous flag absent).

- [ ] **Step 2: Add context product-contract tests**

```swift
func testEveryAskRequestQueriesAllConfiguredContextSources() async throws
func testIrrelevantMemoryIsExcluded() async throws
func testRelevantMemoryIsIncludedWithinBudget() async throws
func testMandatoryActiveTaskContextSurvivesLowLexicalOverlap() async throws
func testContextPreservesProvenanceAndTaint() async throws
func testCredentialMaterialNeverEntersContextBundle() async throws
func testNoInterviewContextSourceExistsInAuthoritativeRequestPath() throws
```

- [ ] **Step 3: Run acceptance suites**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ProviderAcceptanceTests -only-testing:ZeroLoseTests/ContextAcceptanceTests
```
Expected: PASS.

- [ ] **Step 4: Commit `test: add provider and context acceptance coverage`**

### Task 2: Autonomous runtime acceptance matrix

**Files:**
- Create: `ZeroLose/ZeroLoseTests/Acceptance/AgentAcceptanceTests.swift`

- [ ] **Step 1: Add Ask/Agent authority tests**

```swift
func testAskModeCannotScheduleComputerMutation() async throws
func testAgentModeCreatesRealGoalAndTaskRuntime() async throws
func testComputerMutationPassesToolFabricPolicyAndFreshObservation() async throws
func testPolicyDeniedMutationProducesZeroInputCalls() async throws
func testApprovalRequiredMutationWaitsForApproval() async throws
```

- [ ] **Step 2: Add recovery/completion tests**

```swift
func testEmergencyStopCancelsActiveInputAndPreventsFurtherScheduling() async throws
func testRestartRestoresPausedAndPerformsNoPhysicalReplay() async throws
func testUnknownHighRiskMutationRequiresManualResolution() async throws
func testGoalCannotCompleteWithoutVerifierEvidence() async throws
```

Use recording input/tool providers; no test may post real HID input.

- [ ] **Step 3: Run acceptance suite plus existing computer regressions**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AgentAcceptanceTests -only-testing:ZeroLoseTests/ToolFabricComputerMutationGatewayTests -only-testing:ZeroLoseTests/AutonomousRuntimeResumeTests
cd ExamPilot && swift test
```
Expected: PASS.

- [ ] **Step 4: Commit `test: add autonomous runtime acceptance coverage`**

### Task 3: UI, settings, and migration acceptance

**Files:**
- Create: `ZeroLose/ZeroLoseTests/Acceptance/UISettingsAcceptanceTests.swift`
- Modify: `scripts/verify_all.py`

- [ ] **Step 1: Add main-workspace/settings contract tests**

Assert primary production UI exposes provider/model, Ask/Agent, composer/attachment, Context inspector, Runtime inspector, conditional stop/emergency stop. Assert settings contain only the approved sections. Assert provider capability controls hide/disable unsupported actions.

- [ ] **Step 2: Add settings persistence and secret tests**

Round-trip `GeneralSettings` in isolated defaults; OpenAI key save returns only configured/not-configured state; scan defaults/event/memory test stores to prove the literal secret is absent.

- [ ] **Step 3: Add migration acceptance**

Run `GeneralAgentMigrationCoordinator` against a current-production fixture twice plus interrupted marker fixture. Assert general conversations/memory survive, interview fixture bytes are unchanged, old OpenCode auth import is never called, and unsafe legacy authority does not migrate upward.

- [ ] **Step 4: Add release-blocking forbidden production surface to `verify_all.py`**

The script recursively scans `ZeroLose/ZeroLose` and fails on:

```text
InterviewVault
MockInterview
Teleprompter
InterviewKnowledgeMatcher
warmUpInterviewContext
openCodeZen
openCodeGo
fallbackProvider
importOpenCodeKeysIfNeeded
.local/share/opencode/auth.json
opencode.ai/zen
/zen/go/
actionRegex
handleActions
[ACTION:
```

It additionally fails if `InputDriving`, `NativeInputDriver`, or `import ExamPilotCore` occurs outside `V2/Computer/MacOSComputerMutationAdapter.swift`.

- [ ] **Step 5: Run UI/settings acceptance and repository guard**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/UISettingsAcceptanceTests
python3 scripts/verify_all.py
git diff --check
```
Expected: all PASS.

- [ ] **Step 6: Commit `test: enforce redesigned ZeroLose release boundaries`**

### Task 4: Opt-in local provider smoke harness

**Files:**
- Create: `scripts/smoke_local_providers.py`
- Modify: `ZeroLose/README.md` if present; otherwise create `ZeroLose/README.md`.

- [ ] **Step 1: Implement safe discovery mode**

Python script uses `shutil.which` and `subprocess.run([...], shell=False, timeout=...)`. Default invocation performs only executable/version/help probes that do not send prompts and does not read config/auth files. Output schema:

```json
{"provider":"codex","executable":true,"probe":"ok|unavailable|timeout","live":false}
```

No environment values are printed.

- [ ] **Step 2: Implement explicit `--live` mode**

`--live` sends the exact harmless prompt `Reply with exactly: ZEROLOSE_SMOKE_OK` through only providers selected with repeated `--provider <id>` arguments. It uses the same reasoning-only flags as production adapters. Antigravity is skipped if `agy` is absent. OpenAI live API smoke requires a separate `--include-openai-api` opt-in and obtains the key through the application credential boundary or explicit secure environment documented for local development; it never prints the key.

Output contains only provider ID, success boolean, normalized error category, duration milliseconds, and whether exact sentinel was observed.

- [ ] **Step 3: Test the smoke script itself without live subscriptions**

Add Python unit/self-test mode or injectable executable runner so CI can assert shell=False argv, timeout handling, redacted output, and missing executable state without calling real providers.

```bash
python3 scripts/smoke_local_providers.py --self-test
python3 scripts/smoke_local_providers.py
```
Expected: self-test exit 0; discovery reports actual machine state and may report missing providers without failing the script.

- [ ] **Step 4: Document local live invocation**

Example:
```bash
python3 scripts/smoke_local_providers.py --live --provider codex --provider claude --provider opencode
```

- [ ] **Step 5: Commit `test: add opt-in local provider smoke harness`**

### Task 5: Full immutable-head release verification

**Files:** none unless a genuine defect is found.

- [ ] **Step 1: Record candidate HEAD and require clean status**

```bash
git rev-parse HEAD
git status --short
git diff --check
```
Expected: no source changes/untracked release artifacts; `.freebuff/` not staged.

- [ ] **Step 2: Run full ZeroLose test suite**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 3: Run ExamPilot package suite and release build**

```bash
cd ExamPilot
swift test
swift build -c release
cd ..
```
Expected: PASS/exit 0.

- [ ] **Step 4: Run repository gate**

```bash
python3 scripts/verify_all.py
```
Expected: exit 0.

- [ ] **Step 5: Build arm64 Release app**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -configuration Release -destination 'platform=macOS,arch=arm64' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Re-read HEAD and clean status**

Require exact same SHA as Step 1. If any file changed, verification is stale: inspect, restore only generated artifacts that are known safe, then restart Task 5 from Step 1.

### Task 6: Exact-head PR, CI, and merge

**Files:** none.

- [ ] **Step 1: Push only the clean current feature branch**
- [ ] **Step 2: Open PR and record `headRefOid`**
- [ ] **Step 3: Require Repository workflow success whose `headSha` exactly equals the recorded head**
- [ ] **Step 4: Re-read PR; require head unchanged, mergeable, clean, all required checks successful**
- [ ] **Step 5: Merge using repository-approved strategy (inspect repository merge settings first; no force/rebase guesswork)**
- [ ] **Step 6: Record resulting `origin/main` SHA**
- [ ] **Step 7: Require post-merge Repository workflow success whose `headSha` equals that exact main SHA**

A successful PR check on an older head does not satisfy this task.

### Task 7: Install and launch the verified merged macOS app

**Files:** no source changes expected.

- [ ] **Step 1: Fast-forward a clean main verification worktree to the post-merge SHA**
- [ ] **Step 2: Run `python3 scripts/verify_all.py` once on merged main; require exit 0**
- [ ] **Step 3: Build a locally signed arm64 Release bundle from that merged main SHA**
- [ ] **Step 4: Verify bundle ID `com.senoldogan.ZeroLose`, executable architecture, and `codesign --verify --deep --strict`**
- [ ] **Step 5: Install to `/Applications/ZeroLose.app` with rollback-safe staging/swap; do not delete rollback copy until smoke passes**
- [ ] **Step 6: Launch through LaunchServices and verify process survives at least 10 seconds and a main window exists**
- [ ] **Step 7: Run default provider discovery smoke and optional user-approved live provider smoke; never expose credentials**
- [ ] **Step 8: Remove rollback copy only after launch smoke is green**

### Task 8: Cleanup and final evidence

**Files:** none.

- [ ] **Step 1: Verify the merged redesign worktree is clean**
- [ ] **Step 2: Remove only redesign worktrees; preserve `/Users/dogan/Desktop/akilli-asistan` and every unrelated user worktree/branch**
- [ ] **Step 3: Delete merged local/remote redesign branch refs**
- [ ] **Step 4: Verify `main...origin/main` clean at the post-merge verified SHA**
- [ ] **Step 5: Report final evidence**

Report: spec/plan commits, final feature head, merge SHA, exact-head CI run/result, post-merge CI run/result, ZeroLose full test result, ExamPilot test/release result, repository verify result, Release build result, installed bundle path/signature/smoke, provider discovery/live smoke results, and known non-blocking warnings. Do not call the redesign complete if any required item is missing.
