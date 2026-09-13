# ZeroLose V2 UI Control Plane Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:executing-plans` to implement this plan task-by-task. Runtime behavior changes follow `superpowers:test-driven-development`.

**Goal:** Make the V2 provider/model control plane the single authority for Chat and Agent, replace the interview-era visible product surface with a compact general Chat/Agent workspace, remove interview/runtime reachability and legacy provider authority, then complete local release verification, PR/merge, and safe branch cleanup.

**Architecture:** `ProviderControlPlane` owns non-secret provider/model selection and presentation snapshots; `ModelProviderFabric` remains the provider execution registry. Chat and Agent capture immutable `ProviderSelectionSnapshot` values before starting work and invoke the explicitly bound provider/model, so a later UI selection change can affect only future work. SwiftUI observes a shared `ProviderViewModel`; it never reads legacy provider defaults or transports directly. Existing Tool Fabric, Policy Kernel, persistence, Agent orchestration, computer freshness, and production semantic verification boundaries remain unchanged.

**Tech Stack:** Swift 5 / Swift 6 concurrency checks, SwiftUI/Observation, macOS AppKit, UserDefaults for non-secret V2 preferences, Keychain for OpenAI API credential, XCTest, Xcode, GitHub CLI for final PR workflow.

**Spec:** `docs/superpowers/specs/2026-09-13-zerolose-v2-ui-control-plane-design.md`

**Base branch at plan creation:** `feat/zerolose-agent-runtime-composition`

## Global Constraints

- Work only in `/Users/dogan/Desktop/akilli-asistan`.
- All implementation, tests, builds, release verification, installation checks, and cleanup safety checks happen locally first.
- Do not use a PR as a development/test loop. Open the PR only after every required local gate is green and the feature branch is clean.
- After local completion: push the focused branch, open a PR, verify the exact PR head, merge through the PR, verify merged `main`, then delete only branches/worktrees proven to contain no unique unmerged work.
- Keep the repository clean at every task boundary; stage only explicit paths and never use `git add .`.
- Preserve floating `GhostWindow`, hotkey/window positioning, current screen-sharing policy, and general attachment/voice/screenshot/tool/runtime capabilities unless a targeted migration replaces their backend.
- Do not weaken Tool Fabric, Policy Kernel, approval/authority, Emergency Stop, cancellation, runtime freshness, semantic verification, checkpoint/replay, or reconciliation to simplify UI work.
- Provider/model output remains untrusted. No direct model-to-mouse/keyboard/browser/shell path may be introduced.
- No API keys/tokens/session secrets in UserDefaults, provider snapshots, logs, events, memory, or diagnostics.
- Do not destructively delete user-owned interview data or obsolete Keychain entries as part of code cleanup.
- Legacy `LLMProvider`, `AIModelNames`, `llm_provider`, and `custom*Model` may temporarily survive for compatibility-only services, but they must not remain authoritative for primary Chat/Agent routing or UI after Task 6.
- Every behavior change follows RED -> minimal GREEN -> focused regression -> affected broader suite.

---

## Task 1: Add immutable provider selection and the provider control plane

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Providers/ProviderControlPlane.swift`
- Modify: `ZeroLose/ZeroLose/V2/Providers/ModelProviderFabric.swift`
- Modify: `ZeroLose/ZeroLose/V2/Providers/ModelProvider.swift` only if a presentation/control-plane error type belongs with the provider domain
- Test: `ZeroLose/ZeroLoseTests/V2/ProviderControlPlaneTests.swift`
- Modify test: `ZeroLose/ZeroLoseTests/V2/ModelProviderFabricTests.swift`
- Reuse: `ZeroLose/ZeroLoseTests/V2/ProviderTestDoubles.swift`

**Interfaces:**

```swift
nonisolated struct ProviderSelectionSnapshot: Sendable, Equatable {
    let providerID: ModelProviderID
    let modelID: String
    let revision: UInt64
}

nonisolated enum ModelDiscoveryState: Sendable, Equatable {
    case idle
    case loaded
    case failed
}

nonisolated struct ProviderPresentation: Identifiable, Sendable, Equatable {
    let id: ModelProviderID
    let displayName: String
    let availability: ProviderAvailability
    let capabilities: ModelCapabilities
    let models: [ModelDescriptor]
    let modelDiscoveryState: ModelDiscoveryState
}

nonisolated struct ProviderControlSnapshot: Sendable, Equatable {
    let providers: [ProviderPresentation]
    let selection: ProviderSelectionSnapshot
}

nonisolated protocol ProviderSelectionPersisting: Sendable {
    func loadProviderID() async -> String?
    func loadModelID() async -> String?
    func save(providerID: String, modelID: String) async
}

actor ProviderControlPlane {
    func snapshot() async -> ProviderControlSnapshot
    func refresh() async -> ProviderControlSnapshot
    func currentSelection() -> ProviderSelectionSnapshot
    func selectProvider(_ providerID: ModelProviderID) async throws -> ProviderControlSnapshot
    func selectModel(_ modelID: String) async throws -> ProviderControlSnapshot
    func canUseChat() async -> Bool
    func canUseAgent() async -> Bool
}
```

`UserDefaultsProviderSelectionStore` persists only `v2.modelProviderID` and `v2.modelDefaultID` and is injectable so tests use an isolated suite or an in-memory store.

`ModelProviderFabric` gains explicit-provider methods so execution does not depend on mutable global selection after work begins:

```swift
func registeredProviderIDs() -> [ModelProviderID]
func capabilities(for providerID: ModelProviderID) throws -> ModelCapabilities
func status(for providerID: ModelProviderID) async -> ProviderStatus
func stream(_ request: ModelRequest, using providerID: ModelProviderID) throws -> AsyncThrowingStream<ModelEvent, Error>
func cancel(sessionID: ModelSessionID, using providerID: ModelProviderID) async
```

Keep the existing selected-provider surface only where compatibility tests require it during migration. New production request paths must use explicit-provider methods.

### Step 1.1 — Write RED fabric binding tests

Add tests that:
- explicit `stream(..., using: codexID)` uses Codex even if the mutable selected provider is Claude;
- explicit cancellation reaches the same provider that started the session after selected provider changes;
- an unknown explicit provider fails closed with `.providerUnavailable`;
- registered provider IDs are deterministic and sorted;
- capabilities are returned only for a registered provider.

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ModelProviderFabricTests
```

Expected: RED because explicit-provider APIs do not exist yet.

### Step 1.2 — Implement the minimal explicit-provider fabric APIs

Do not change provider adapters or transport semantics. Do not add fallback behavior.

Run the same focused suite until GREEN.

### Step 1.3 — Write RED control-plane tests

Cover all of these cases:
- valid persisted provider/model restores unchanged;
- unknown persisted provider deterministically chooses `codex` when registered, otherwise first sorted registered ID;
- selected provider status comes from that provider adapter;
- provider switch persists the new ID and resets incompatible model to `default`;
- discovered model can be selected only for the active provider;
- a model from a different provider is rejected;
- discovery failure does not inject a hard-coded model catalog;
- an adapter-defined `default` is allowed only under the documented default semantics;
- selection revision increments only when provider/model selection materially changes;
- `.jsonOutput` gates Agent availability;
- presentation snapshots contain no credential value.

### Step 1.4 — Implement `ProviderControlPlane`

Initialize by validating persisted V2 state against `registeredProviderIDs()`. Refresh statuses/model discovery through the fabric. Preserve deterministic ordering. Keep discovery failures as explicit state; never synthesize another provider's models.

### Step 1.5 — Focused verification and commit

Run:

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ModelProviderFabricTests \
  -only-testing:ZeroLoseTests/ProviderControlPlaneTests

git diff --check
```

Commit only Task 1 paths:

```text
feat: add authoritative provider control plane
```

---

## Task 2: Bind Chat requests and cancellation to immutable provider/model selection

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/AskRequest.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/RequestCoordinator.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/ShellViewModel.swift`
- Modify tests: `ZeroLose/ZeroLoseTests/V2/RequestCoordinatorTests.swift`
- Modify tests: `ZeroLose/ZeroLoseTests/V2/ViewModelProjectionTests.swift`
- Add focused tests to an existing V2 shell/runtime test file or create: `ZeroLose/ZeroLoseTests/V2/ProviderSelectionRequestTests.swift`

**Contract change:**

```swift
nonisolated struct AskRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversationID: String
    let text: String
    let selection: ProviderSelectionSnapshot
    let activeGoalID: GoalID?
}
```

`RequestCoordinator.cancel` must take enough immutable routing information to cancel through the original provider:

```swift
func cancel(sessionID: ModelSessionID, providerID: ModelProviderID) async
```

`V2ShellRuntimeController` receives an async selection provider backed by `ProviderControlPlane` rather than `modelIDProvider: () -> String`. Track the active Ask session together with its bound provider ID.

### Step 2.1 — Write RED RequestCoordinator tests

Test:
- request selection provider ID determines execution even after global fabric selection changes;
- `selection.modelID` becomes `ModelRequest.modelID` exactly;
- cancellation after a UI/global selection change still reaches the original provider;
- a provider failure is surfaced without fallback;
- conversation/context persistence behavior remains unchanged.

### Step 2.2 — Run RED

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/RequestCoordinatorTests \
  -only-testing:ZeroLoseTests/ProviderSelectionRequestTests
```

### Step 2.3 — Implement immutable Ask selection

Change only routing ownership. Do not alter context assembly or conversation semantics.

Remove provider/model display calculation from `V2ShellRuntimeController.publishSnapshot()`. `ShellProjectionSnapshot` should stop carrying `currentModelDisplay` if no non-legacy value is needed there. Provider presentation will move to `ProviderViewModel` in Task 4.

If the existing context meter depends on `AIModelNames` context-window guesses, remove that guessed denominator from the primary V2 shell projection rather than inventing provider metadata. Keep any independently valid context usage data only if it has a truthful source.

### Step 2.4 — Verify and commit

Run RequestCoordinator + shell/view-model tests and `git diff --check`.

Commit:

```text
refactor: bind chat requests to provider selection snapshots
```

---

## Task 3: Bind Agent planning to one immutable selection per run

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Autonomy/ModelPlanningAdapter.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Modify tests: `ZeroLose/ZeroLoseTests/V2/ModelPlanningAdapterTests.swift`
- Modify tests: `ZeroLose/ZeroLoseTests/V2/AgentApplicationCommandTests.swift`
- Modify tests: `ZeroLose/ZeroLoseTests/V2/ProviderCompositionTests.swift`
- Re-run: `AgentOrchestratorTests`, `AutonomousRuntimeResumeTests`, `AgentRestartIntegrationTests`, semantic-verification suites

**Required invariant:** changing provider/model UI state while one Agent run is active cannot change the provider/model used by later planning cycles inside that run. A new run after completion uses the newly selected snapshot.

### Step 3.1 — Write RED planner binding tests

Change `ModelPlanningAdapter` to require an immutable selection:

```swift
init(providerFabric: ModelProviderFabric, selection: ProviderSelectionSnapshot)
```

Test that planner traffic uses `selection.providerID` and `selection.modelID` even when fabric selected state changes.

### Step 3.2 — Write RED Agent runtime tests

Refactor `AgentCommandRuntime` composition so a new Agent execution captures control-plane selection before it creates/starts the orchestrator. Use a factory boundary rather than a live provider/model closure inside the planner.

Representative boundary:

```swift
nonisolated protocol AgentOrchestratorBuilding: Sendable {
    func make(selection: ProviderSelectionSnapshot) async throws -> any AgentOrchestrating
}
```

Production implementation may be a closure-backed builder owned by `ZeroLoseRuntimeContainer`, as long as:
- each new run gets exactly one selection snapshot;
- active run reuses its same orchestrator/planner;
- structured-planning capability is checked against that exact snapshot;
- existing TaskRuntime, scheduler, checkpoint/event stores, semantic verifiers, Tool Fabric, computer observation provider, and mutation state remain the same authorities.

Tests:
- first run captures provider A/model A;
- UI/control-plane changes to provider B/model B during first run do not alter first run;
- second run after terminal state uses provider B/model B;
- unavailable/non-JSON-capable selection fails before planning/tool execution;
- pause/resume/cancel/emergency-stop still target the active session;
- restart/reconciliation tests remain green.

### Step 3.3 — Implement minimal per-run planner/orchestrator factory

Do not fork verifier/tool composition. Extract existing container construction into a small factory so tests can prove the selection input while production reuses the already-created runtime dependencies.

### Step 3.4 — Focused Agent verification

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/ModelPlanningAdapterTests \
  -only-testing:ZeroLoseTests/AgentApplicationCommandTests \
  -only-testing:ZeroLoseTests/AgentOrchestratorTests \
  -only-testing:ZeroLoseTests/AutonomousRuntimeResumeTests \
  -only-testing:ZeroLoseTests/AgentRestartIntegrationTests \
  -only-testing:ZeroLoseTests/ProductionAgentTaskVerifierTests \
  -only-testing:ZeroLoseTests/ProductionAgentGoalVerifierTests
```

Commit:

```text
refactor: bind agent runs to provider selection snapshots
```

---

## Task 4: Add one shared `ProviderViewModel` and wire production composition

**Files:**
- Create: `ZeroLose/ZeroLose/V2/UI/ProviderViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/Application/ProviderSettingsController.swift` if credential mutation needs a presentation-safe boundary
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Modify: `ZeroLose/ZeroLose/V2/Credentials/KeychainCredentialBrokerAdapter.swift` only if a safe `isConfigured/save/remove` presentation protocol is missing
- Test: `ZeroLose/ZeroLoseTests/V2/ProviderViewModelTests.swift`
- Test/modify: `ZeroLose/ZeroLoseTests/V2/ProviderCompositionTests.swift`

**View-model contract:**

```swift
@MainActor
@Observable
final class ProviderViewModel {
    private(set) var snapshot: ProviderControlSnapshot
    private(set) var errorMessage: String?

    var selectedProvider: ProviderPresentation? { get }
    var selectedModelID: String { get }
    var canUseChat: Bool { get }
    var canUseAgent: Bool { get }

    func refresh() async
    func selectProvider(_ id: ModelProviderID) async
    func selectModel(_ id: String) async
    func saveOpenAIAPIKey(_ value: String) async
    func removeOpenAIAPIKey() async
}
```

If OpenAI credential state is exposed, the snapshot contains only a boolean such as `openAIKeyConfigured`; it never contains the stored key.

### Step 4.1 — RED view-model tests

Cover:
- refresh publishes backend status/model state;
- provider/model commands update one shared snapshot;
- Chat availability uses real provider status;
- Agent availability uses real capability gate;
- errors are safe and do not include submitted key text;
- saving a key clears the input-side value and exposes configured/not-configured only;
- main-window and Settings consumers can share one instance from the runtime container.

### Step 4.2 — Implement and compose

`ZeroLoseRuntimeContainer` creates exactly one `ProviderControlPlane` and one `ProviderViewModel`, and exposes the view model for both `ContentView` and `SettingsView`. Remove direct startup V2 provider/model persistence logic from the container once control-plane initialization owns it.

Keep Tavily and Groq outside this view model; they are tool/voice integrations, not model providers.

### Step 4.3 — Verify and commit

Commit:

```text
feat: expose shared V2 provider state to SwiftUI
```

---

## Task 5: Replace the primary `ContentView` provider/interview UI with Chat/Agent workspace controls

**Files:**
- Major refactor: `ZeroLose/ZeroLose/Views/ContentView.swift`
- Modify: `ZeroLose/ZeroLose/Services/WindowManager.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/ShellViewModel.swift`
- Reuse: `ZeroLose/ZeroLose/V2/UI/TaskRuntimeViewModel.swift`
- Reuse: `ZeroLose/ZeroLose/V2/UI/RuntimeDashboardView.swift`
- Create if needed for readability: `ZeroLose/ZeroLose/V2/UI/ProviderSelectorView.swift`
- Create if needed: `ZeroLose/ZeroLose/V2/UI/WorkspaceMode.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MainWorkspaceBoundaryTests.swift`
- Modify: `ZeroLose/ZeroLoseTests/V2/ViewModelProjectionTests.swift`

**Primary visible layout:**
- header: ZeroLose/status, provider selector, model selector, Chat/Agent segmented control, Settings;
- main body: conversation/task messages;
- compact runtime strip in Agent mode with real pause/resume/cancel/emergency-stop state;
- composer: attachments, web preference, screenshot analysis, voice/listening, text, Send/Stop;
- secondary runtime inspector remains available.

No provider/model selector remains in the composer.

### Step 5.1 — Write RED source-boundary tests

`MainWorkspaceBoundaryTests` reads production source and asserts:
- `ContentView` consumes `ProviderViewModel`;
- approved provider/model + Chat/Agent controls exist;
- no `@AppStorage("llm_provider")`;
- no `customOpenAIReasoningModel`, `customDeepSeekReasoningModel`, `customOpenCodeZenReasoningModel`, `customOpenCodeGoReasoningModel`, or `customOllamaReasoningModel`;
- no `LLMProvider.allCases`/`AIModelNames` routing in ContentView;
- no `InterviewVaultView`, `MockInterviewView`, `warmUpInterviewContext`, or Teleprompter action;
- no duplicate provider/model selector in the composer.

### Step 5.2 — Write RED mode/submit behavior tests

Add a small presentation-only `WorkspaceMode` and test command routing:
- Chat mode submits through `.sendChatMessage` / `ChatViewModel`;
- Agent mode submits `.submitUserGoal`;
- Agent submit disabled when `ProviderViewModel.canUseAgent == false`;
- active Agent exposes only controls supported by `TaskRuntimeViewModel`;
- Emergency Stop enabled only when `canEmergencyStop` is true.

### Step 5.3 — Implement UI cutover

Preserve:
- file drop/picker and attachment preview;
- forced web-search compatibility entry point until its V2 tool path is fully migrated;
- screenshot analysis entry point;
- mic/listening entry point;
- stop response;
- runtime dashboard;
- authority control if still useful, but do not label `.fullAccess` as selectable.

Remove from primary workspace:
- interview modals/buttons;
- Teleprompter action;
- Keyboard disguise modal/header action if it has no approved general workspace purpose;
- legacy provider model/effort controls;
- fabricated context-window meter if it cannot be driven by V2 metadata.

### Step 5.4 — Update WindowManager injection

Inject the same `providerViewModel` instance into the main view. Preserve `GhostWindow` behavior.

### Step 5.5 — Focused build/tests and commit

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ZeroLoseTests/MainWorkspaceBoundaryTests \
  -only-testing:ZeroLoseTests/ViewModelProjectionTests \
  -only-testing:ZeroLoseTests/RuntimeDashboardStateTests
```

Commit:

```text
refactor: replace interview-era main workspace
```

---

## Task 6: Rebuild Settings around real runtime domains

**Files:**
- Major refactor: `ZeroLose/ZeroLose/Views/SettingsView.swift`
- Modify/split: `ZeroLose/ZeroLose/V2/UI/SettingsViewModel.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Modify: `ZeroLose/ZeroLose/Services/WindowManager.swift`
- Create as needed:
  - `ZeroLose/ZeroLose/V2/UI/ProviderSettingsView.swift`
  - `ZeroLose/ZeroLose/V2/UI/RuntimeSettingsView.swift`
  - `ZeroLose/ZeroLose/V2/UI/ToolsSettingsView.swift`
  - `ZeroLose/ZeroLose/V2/UI/MemorySettingsView.swift`
  - `ZeroLose/ZeroLose/V2/UI/VoiceSettingsView.swift`
  - `ZeroLose/ZeroLose/V2/UI/PrivacySettingsView.swift`
  - `ZeroLose/ZeroLose/V2/UI/AppearanceSettingsView.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/SettingsSurfaceTests.swift`
- Test/modify: provider view-model and settings projection tests

**Approved sections:** Providers, Tools, Runtime, Memory, Voice, Appearance, Privacy/Diagnostics. Exact navigation presentation may be native SwiftUI sidebar/tabs, but data ownership is fixed.

### Step 6.1 — RED settings boundary tests

Assert:
- Providers shows only registered V2 provider IDs (Codex, Claude, OpenCode, Antigravity, OpenAI API in current production composition);
- provider status/models come from `ProviderViewModel`;
- OpenAI key is write-only after save;
- Tavily is under Tools/Web, not Providers;
- Groq is under Voice/transcription when still used;
- Settings source does not read `llm_provider` or `LLMProvider.allCases`;
- no DeepSeek/OpenCode Zen/OpenCode Go/Ollama credential cards presented as V2 model providers;
- no interview role/CV/JD/notes/teleprompter/mock-interview settings;
- authority mode excludes `.fullAccess` selection;
- appearance/privacy controls that are still real remain functional.

### Step 6.2 — Split legacy settings data ownership

Reduce `SettingsViewModel` to general settings/runtime/memory integrations. Replace `CredentialSettingsSnapshot` model-provider authority with:
- `ProviderViewModel` for model providers/OpenAI V2 key;
- a small integration settings controller for Tavily/Groq if required by current features;
- existing tool/runtime/memory controllers for their own domains.

Do not delete obsolete secrets here; simply stop exposing them as active provider configuration.

### Step 6.3 — Implement and verify

Use the shared `providerViewModel` from `WindowManager.showSettingsWindow()`.

Run focused settings/provider suites and a no-sign Debug build.

Commit:

```text
refactor: rebuild settings around V2 runtime domains
```

---

## Task 7: Remove interview runtime reachability and teleprompter lifecycle

**Files to remove when consumer audit proves they are interview-only:**
- `ZeroLose/ZeroLose/Views/InterviewVaultView.swift`
- `ZeroLose/ZeroLose/Views/MockInterviewView.swift`
- `ZeroLose/ZeroLose/Views/TeleprompterView.swift`
- `ZeroLose/ZeroLose/Services/MockInterviewService.swift`
- `ZeroLose/ZeroLose/Services/VaultService.swift`
- `ZeroLose/ZeroLose/Services/VaultSearchEngine.swift`
- `ZeroLose/ZeroLose/Services/ActiveRoleProfileService.swift`
- `ZeroLose/ZeroLose/Services/InterviewKnowledgeMatcher.swift`
- `ZeroLose/ZeroLose/Models/InterviewItem.swift`

**Candidate files requiring consumer audit before deletion/extraction:**
- `ZeroLose/ZeroLose/Services/IntelligenceService.swift`
- `ZeroLose/ZeroLose/Services/ResponseCacheService.swift`
- `ZeroLose/ZeroLose/Services/TextAnalysis.swift`
- `ZeroLose/ZeroLose/Services/LLMPromptBuilder.swift`
- `ZeroLose/ZeroLose/Views/CheatSheetView.swift`
- `ZeroLose/ZeroLose/ViewModels/CheatSheetViewModel.swift`
- `ZeroLose/ZeroLose/Views/KeyboardDisguiseView.swift`

**Modify:**
- `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift`
- `ZeroLose/ZeroLose/V2/UI/ShellViewModel.swift`
- `ZeroLose/ZeroLose/Services/WindowManager.swift`
- `ZeroLose/ZeroLose/Services/DependencyContainer.swift`
- `ZeroLose/ZeroLose/Info.plist`
- `ZeroLose/README.md`
- project file only if target membership is explicit and source deletion requires it
- Test: `ZeroLose/ZeroLoseTests/V2/InterviewDemolitionTests.swift`

### Step 7.1 — RED forbidden-path tests

Scan production source for executable references to:
- `InterviewVaultView`
- `MockInterviewView`
- `MockInterviewService`
- `TeleprompterView`
- `TeleprompterWindow`
- `toggleTeleprompterWindow`
- `warmUpInterviewContext`
- `ActiveRoleProfileService`
- interview-role/CV-JD UI settings

Also assert Info.plist privacy copy and README no longer define the product as an interview assistant.

### Step 7.2 — Characterize preserved general behavior before deleting shared legacy services

Before removing `IntelligenceService`, `TextAnalysis`, `LLMPromptBuilder`, or `ResponseCacheService`, run an exact consumer audit with `rg`/`code_query`.

For every still-required general behavior (image/screenshot analysis, AI refinement, language/text normalization, voice-related model name, etc.):
1. add a neutral regression test;
2. migrate it to RequestCoordinator/provider-neutral V2 code or a narrowly named general service;
3. verify its caller no longer depends on interview semantics;
4. only then delete the interview-era dependency closure.

If a candidate file still owns valid general behavior that is outside this cutover, keep it temporarily but remove all interview invocation/reachability and record its remaining explicit caller in the task commit. Never delete general functionality merely to satisfy a symbol scan.

### Step 7.3 — Remove warm-up and teleprompter runtime contracts

Delete `warmUpInterviewContext()` from `ShellFeatureControlling`, `ShellViewModel`, and `V2ShellRuntimeController`.

Remove Teleprompter window class/state/frame preferences/open-close methods from WindowManager. Do not delete stored user defaults; they become inert.

### Step 7.4 — Remove interview-only leaf files and consumers

Delete files only after `rg` proves no surviving production consumer outside the deletion set.

Update general privacy/product copy. Do not delete interview data files/databases/defaults.

### Step 7.5 — Verify and commit

Run interview demolition + preserved-feature regressions + ZeroLose build.

Commit:

```text
refactor: remove interview product runtime
```

---

## Task 8: Remove legacy provider authority from primary production paths and add permanent verification guards

**Files:**
- Modify: `ZeroLose/ZeroLose/ZeroLoseApp.swift`
- Modify: `ZeroLose/ZeroLose/Resources/Constants.swift` as consumer audit allows
- Modify: `ZeroLose/ZeroLose/Resources/Secrets.swift` only to remove now-unused executable authority/import behavior; preserve stored user data
- Modify/delete: `ZeroLose/ZeroLose/Services/OllamaService.swift` only after zero required general consumers remain
- Modify: `ZeroLose/ZeroLose/Services/DependencyContainer.swift`
- Modify: `scripts/verify_all.py`
- Test: `ZeroLose/ZeroLoseTests/V2/ProviderLegacyDemolitionTests.swift`

### Step 8.1 — RED authority scans

The permanent source gate must reject these from primary V2 production paths (`Views/ContentView.swift`, `Views/SettingsView.swift`, `V2/Application`, `V2/UI`, provider-selection composition):
- `@AppStorage("llm_provider")`
- authoritative `LLMProvider`
- authoritative `AIModelNames.currentProvider()`
- provider-specific `custom*Model` routing
- credential-validity provider fallback
- direct OpenCode Zen/Go endpoint routing
- automatic `.local/share/opencode/auth.json` credential import

Global scans may allow an explicitly documented compatibility-only use such as `AIModelNames.whisper` in a voice service until separately migrated, but no such allowance can reach Chat/Agent provider selection.

### Step 8.2 — Remove automatic legacy credential import

Remove `Secrets.importOpenCodeKeysIfNeeded()` from `ZeroLoseApp.applicationDidFinishLaunching` and any automatic auth-file scraping path. Existing stored keys remain untouched.

### Step 8.3 — Consumer-audit legacy router

Require:

```bash
rg -n "OllamaService|LLMProvider|AIModelNames|llm_provider|custom[A-Za-z]+Model" ZeroLose/ZeroLose --glob '*.swift'
```

Classify every remaining result as:
- deleted now because new V2 path has parity;
- retained temporarily for a named non-primary general feature with test coverage;
- test/migration-only reference.

Do not leave undocumented primary routing authority.

### Step 8.4 — Extend repository verification

Add bounded forbidden-symbol checks to `scripts/verify_all.py` for the primary Chat/Agent/UI paths and removed interview runtime surfaces. The gate must fail with actionable file/symbol output.

### Step 8.5 — Verify and commit

Run provider/control-plane tests, preserved general-feature tests, full ZeroLose build, and repository gate.

Commit:

```text
refactor: retire legacy provider and interview authority
```

---

## Task 9: Full local acceptance, Release build, install, and launch smoke

**Files:**
- Modify only if verification reveals a real defect.
- Record no generated build products in Git.

### Step 9.1 — Clean-state preflight

```bash
git status --short --branch
git diff --check
```

No unexplained changes/untracked files.

### Step 9.2 — Focused V2 regression matrix

Run at minimum:
- `ModelProviderFabricTests`
- `ProviderControlPlaneTests`
- `ProviderViewModelTests`
- `RequestCoordinatorTests`
- `ModelPlanningAdapterTests`
- `AgentApplicationCommandTests`
- `AgentOrchestratorTests`
- `TaskRuntimeTests`
- `AutonomousRuntimeResumeTests`
- `AgentRestartIntegrationTests`
- `ProductionAgentTaskVerifierTests`
- `ProductionAgentGoalVerifierTests`
- `MainWorkspaceBoundaryTests`
- `SettingsSurfaceTests`
- `InterviewDemolitionTests`
- `ProviderLegacyDemolitionTests`
- affected attachment/voice/screenshot/runtime projection tests.

Every failure gets fixed locally and the affected task commit amended only if repository policy allows; otherwise create a focused follow-up commit.

### Step 9.3 — Full repository gate

```bash
python3 scripts/verify_all.py
```

Expected: exit 0, ExamPilot tests green, ExamPilot release build green, CLI smoke green, ZeroLose universal Debug build green.

### Step 9.4 — Release app build

Build a Release macOS app from the exact committed feature HEAD into an isolated DerivedData path. Use local signing/ad-hoc signing appropriate to current project configuration. Do not introduce distribution secrets.

Verify:
- `xcodebuild` exit 0;
- produced bundle exists;
- `codesign --verify --deep --strict` (or the repository-appropriate local verification) passes;
- bundle identifier remains expected;
- executable architectures are expected.

### Step 9.5 — Install exact build and smoke launch

Replace `/Applications/ZeroLose.app` only after the Release bundle is verified locally. Record source bundle hash/identity and compare installed executable/bundle identity. Launch, verify process survives, main window/status utility initializes, quit/relaunch once, and confirm no immediate crash.

Do not claim acceptance if launch requires a different source tree or uncommitted file.

### Step 9.6 — Final feature-head cleanliness

```bash
git status --short --branch
git diff --check
git log -1 --oneline
```

Feature branch must be clean before publishing.

---

## Task 10: PR, exact-head verification, merge, and safe branch/worktree cleanup

This task begins **only after Task 9 is completely green locally**.

### Step 10.1 — Publish the verified feature branch

Push the current clean branch. Confirm remote SHA equals the locally verified feature HEAD.

### Step 10.2 — Open the PR

Use GitHub CLI/repository tooling to open one focused PR summarizing:
- V2 provider control-plane authority;
- immutable Chat/Agent selection binding;
- new workspace/settings surface;
- interview/legacy authority removal;
- local verification evidence;
- release/install smoke result.

Do not include secrets or raw logs containing user data.

### Step 10.3 — Verify exact PR head

Confirm GitHub PR head SHA equals locally verified SHA. If CI exists, require it green. If the remote platform changes the branch or required checks fail, return to local development; do not merge an unverified different SHA.

### Step 10.4 — Merge through the PR

Merge using repository-supported merge strategy. Record merge SHA.

### Step 10.5 — Verify merged `main`

Update local `main` to the merged remote SHA without carrying feature-tree dirt. Run at minimum:

```bash
python3 scripts/verify_all.py
git diff --check
git status --short --branch
```

If merge mechanics changed code, run the Release/install smoke again before cleanup.

### Step 10.6 — Prove branch cleanup safety

For each candidate old branch (including `feat/zerolose-agent-runtime-composition`, `feat/zerolose-context-request-pipeline`, and `feat/zerolose-provider-fabric` if still present):
- confirm its tip is an ancestor of merged `main`, or otherwise prove all unique commits are intentionally preserved elsewhere;
- confirm no dirty/untracked worktree depends on it;
- inspect `git branch --merged`/merge-base evidence;
- do not delete a branch with unique unmerged user work.

### Step 10.7 — Delete unused branches/worktrees

Delete only proven-merged/unused local branches, corresponding remote feature branches, and obsolete managed worktrees. Keep `main` and any intentionally active/recovery branch.

### Step 10.8 — Final repository hygiene proof

Final state:
- active repo remains `/Users/dogan/Desktop/akilli-asistan`;
- branch is `main` at merged SHA;
- `git status` is clean;
- no stale project worktree remains;
- no unused merged feature branch remains;
- repository verification is green.

Checkpoint the project record with merge SHA, verification evidence, install status, and cleanup result.

---

## Final Acceptance Checklist

- [ ] `AGENTS.md` / `CONTRIBUTING.md` enforce local-first development, PR-after-green, safe branch cleanup, and clean-repository rules.
- [ ] One `ProviderControlPlane` owns provider/model selection and V2 persistence.
- [ ] `ModelProviderFabric` can execute/cancel against an explicit provider independent of later UI selection.
- [ ] Chat request provider/model is immutable for the lifetime of the request.
- [ ] Agent provider/model is immutable for the lifetime of the run; next run sees new selection.
- [ ] Main window and Settings share one `ProviderViewModel` instance.
- [ ] Provider UI reflects real status, capabilities, and discovered/default models.
- [ ] No silent provider fallback or fabricated model catalog.
- [ ] Agent capability is gated before run start.
- [ ] Primary UI/V2 request paths no longer use `llm_provider`, `LLMProvider`, legacy `AIModelNames` selection, or `custom*Model` as authority.
- [ ] Interview Vault, Mock Interview, Teleprompter, interview warm-up, active role/CV-JD, and interview notes UI/runtime are unreachable/removed.
- [ ] General attachment, voice, screenshot, web/tool, memory, approval, and Agent controls have regression coverage and still work.
- [ ] User-owned obsolete interview data/credentials were not destructively deleted.
- [ ] Permanent verification guards detect regression to interview/legacy provider authority.
- [ ] Full local test/build gate passes from exact committed feature HEAD.
- [ ] Release app builds, verifies, installs to `/Applications/ZeroLose.app`, and passes launch/relaunch smoke.
- [ ] Verified feature branch is pushed only after local green.
- [ ] PR exact head is verified and merged through the PR.
- [ ] Merged `main` passes repository verification.
- [ ] Unused merged branches/worktrees are deleted only after no-unique-work proof.
- [ ] Final `main` worktree is clean.
