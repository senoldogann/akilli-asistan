# ZeroLose UI, Settings, and Legacy Demolition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the interview-era UI/settings with a focused general autonomous-agent workspace, then delete obsolete interview and legacy provider runtime code after new-path parity is proven.

**Architecture:** SwiftUI binds only to presentation-focused V2 view models and typed application commands. The main workspace exposes provider/model, Ask/Agent mode, conversation/task timeline, attachment, context/runtime inspectors, and stop controls; settings are split into provider accounts, model defaults, autonomy/safety, memory/context, tools/MCP, privacy/data, and diagnostics.

**Tech Stack:** SwiftUI, Observation, macOS Liquid Glass availability guards, V2 provider/context/agent/application services, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-11-zerolose-general-autonomous-agent-redesign.md`

## Global Constraints

- No Interview Vault, Mock Interview, Teleprompter, Cheat Sheet, active interview role, keyboard-disguise, or interview-only action remains in the primary product UI.
- UI never owns `Process`, raw API key, ToolFabric, PolicyKernel, CredentialHandle, InputDriving, NativeInputDriver, or direct provider transport.
- Provider/model capability determines which controls are visible/enabled.
- Existing interview data files remain untouched on disk but the new runtime never loads them.
- Obsolete Keychain entries remain untouched during this redesign unless the user explicitly requests cleanup later.
- Do not redesign runtime semantics in SwiftUI; UI reflects command/projection state only.

---

### Task 1: Workspace presentation model

**Files:**
- Create: `ZeroLose/ZeroLose/V2/UI/WorkspaceViewModel.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/TaskRuntimeViewModel.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/ShellViewModel.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/WorkspaceViewModelTests.swift`

**Interfaces:**
- Consumes: `ApplicationCommandSending`, provider status/model projection, context summary, task runtime snapshot.
- Produces: `WorkspaceMode`, `ProviderPresentation`, `WorkspaceProjectionSnapshot`, `WorkspaceViewModel`.

- [ ] **Step 1: Write RED state/capability tests**

```swift
enum WorkspaceMode: String, Sendable, Equatable { case ask, agent }

struct ProviderPresentation: Sendable, Equatable {
    let providerID: ModelProviderID
    let displayName: String
    let availability: ProviderAvailability
    let selectedModelID: String?
    let modelCapabilities: ModelCapabilities
}

struct WorkspaceProjectionSnapshot: Sendable, Equatable {
    let mode: WorkspaceMode
    let provider: ProviderPresentation
    let availableModels: [ModelDescriptor]
    let mutationExecutionActive: Bool
    let contextSummary: String
    let runtimeSummary: String
}

private actor RecordingWorkspaceCommandSender: ApplicationCommandSending {
    private(set) var commands: [ApplicationCommand] = []
    func send(_ command: ApplicationCommand) async throws { commands.append(command) }
}

func makeWorkspaceSnapshot(mode: WorkspaceMode) -> WorkspaceProjectionSnapshot {
    let providerID = ModelProviderID(rawValue: "codex")
    return WorkspaceProjectionSnapshot(
        mode: mode,
        provider: ProviderPresentation(
            providerID: providerID,
            displayName: "Codex",
            availability: .ready,
            selectedModelID: "default",
            modelCapabilities: [.textStreaming, .structuredTools]
        ),
        availableModels: [],
        mutationExecutionActive: false,
        contextSummary: "",
        runtimeSummary: "Ready"
    )
}

func testAgentSubmitUsesGoalCommandWhileAskUsesChatCommand() async throws {
    let sender = RecordingWorkspaceCommandSender()
    let vm = WorkspaceViewModel(commandSender: sender)
    vm.apply(makeWorkspaceSnapshot(mode: .ask))
    try await vm.submit("hello")
    vm.apply(makeWorkspaceSnapshot(mode: .agent))
    try await vm.submit("open Safari and finish the task")
    let commands = await sender.commands
    XCTAssertEqual(commands.count, 2)
    if case .sendChatMessage(let text) = commands[0] {
        XCTAssertEqual(text, "hello")
    } else {
        XCTFail("expected Ask command")
    }
    if case .submitUserGoal(let text) = commands[1] {
        XCTAssertEqual(text, "open Safari and finish the task")
    } else {
        XCTFail("expected Agent command")
    }
}
```

Add tests: provider unavailable disables submit; Agent mode disabled when selected model lacks required structured-planning capability; Emergency Stop visible/enabled only for active mutation-capable Agent session; no interview state exists in snapshot.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/WorkspaceViewModelTests
```

- [ ] **Step 3: Implement presentation-only workspace**

`WorkspaceViewModel` owns no runtime/provider object. It forwards selection/submit/stop commands and applies immutable projection snapshots. Remove `warmUpInterviewContext` from `ShellFeatureControlling`/`ShellViewModel`. Remove clipboard and listening controls from the primary workspace contract and toolbar in this redesign. This task does not delete their underlying services; it removes only primary-workspace exposure. Task 6 consumer audit determines whether any now-unreferenced legacy service is deleted.

- [ ] **Step 4: Run GREEN**
- [ ] **Step 5: Commit `feat: add general agent workspace view model`**

### Task 2: Replace the main ContentView information architecture

**Files:**
- Replace/major refactor: `ZeroLose/ZeroLose/Views/ContentView.swift`
- Modify: `ZeroLose/ZeroLose/Services/WindowManager.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/ContextInspectorView.swift`
- Reuse/modify: `ZeroLose/ZeroLose/V2/UI/RuntimeDashboardView.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MainWorkspaceBoundaryTests.swift`

**Interfaces:**
- Consumes: `WorkspaceViewModel`, chat/task/approval/timeline presentations.
- Produces: one primary workspace; Context and Runtime are secondary inspectors.

- [ ] **Step 1: Write RED production-source boundary test**

Read `ContentView.swift` and assert it references `WorkspaceViewModel`, provider/model selection, `WorkspaceMode`, attachment action, Runtime inspector and Context inspector. Assert it contains none of `InterviewVaultView`, `MockInterviewView`, `Teleprompter`, `CheatSheet`, `warmUpInterviewContext`, `MockInterviewService`, `KeyboardDisguiseView`.

- [ ] **Step 2: Write RED interaction tests**

Use `ZeroLoseUITests` accessibility identifiers: `workspace.provider`, `workspace.model`, `workspace.mode.ask`, `workspace.mode.agent`, `workspace.input`, `workspace.submit`, `workspace.stop`, `workspace.context`, `workspace.runtime`. Launch a fixture configuration and assert these controls exist; assert deleted interview identifiers do not exist.

- [ ] **Step 3: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/MainWorkspaceBoundaryTests
```

- [ ] **Step 4: Implement the new single-workspace layout**

Top row: app/status, provider menu, model menu, Ask/Agent segmented control. Center: conversation/task timeline. Composer: attachment, text input, submit/stop. Bottom/secondary controls: Context and Runtime inspectors. Emergency Stop renders only when workspace projection says mutation execution is active. Keep native Liquid Glass guards/fallbacks but delete interview-era toolbar buttons and overlay sheets.

- [ ] **Step 5: Remove teleprompter-window creation from active WindowManager API**

Do not delete the source file yet; demolition occurs after parity. Main window composition must no longer create/toggle Teleprompter or Cheat Sheet windows.

- [ ] **Step 6: Run focused unit/UI compile tests**
- [ ] **Step 7: Commit `refactor: replace ZeroLose main workspace`**

### Task 3: Provider/account settings model

**Files:**
- Create: `ZeroLose/ZeroLose/V2/UI/ProviderSettingsViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/ProviderSettingsView.swift`
- Replace provider credential portions of: `ZeroLose/ZeroLose/V2/UI/SettingsViewModel.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ProviderSettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `ProviderSettingsControlling` application boundary implemented by provider fabric/OpenAI key store.
- Produces: status/model rows and write-only OpenAI key editing.

- [ ] **Step 1: Write RED provider status tests**

```swift
struct ProviderSettingsSnapshot: Sendable, Equatable {
    let providers: [ProviderStatus]
    let selectedProviderID: ModelProviderID
    let models: [ModelProviderID: [ModelDescriptor]]
    let selectedModels: [ModelProviderID: String]
    let openAIAPIKeyConfigured: Bool
}

@MainActor
protocol ProviderSettingsControlling: AnyObject {
    func snapshot() async -> ProviderSettingsSnapshot
    func selectProvider(_ id: ModelProviderID) async throws
    func selectModel(_ modelID: String, providerID: ModelProviderID) async throws
    func saveOpenAIAPIKey(_ value: String) async throws
    func removeOpenAIAPIKey() async throws
    func refreshProvider(_ id: ModelProviderID) async
}
```

Tests assert Codex/Claude/OpenCode/Antigravity rows show actual status; absent `agy` renders setup-required/not-installed; model list includes only selected provider's discovered supported models.

- [ ] **Step 2: Write RED secret UI test**

After `saveOpenAIAPIKey("sk-secret")`, refreshing snapshot may only return `openAIAPIKeyConfigured=true`; no snapshot/text-field value equals the stored key. The SecureField clears after save.

- [ ] **Step 3: Run RED**
- [ ] **Step 4: Implement view model and view**

Do not expose legacy `CredentialProvider` values for DeepSeek/OpenCode Zen/OpenCode Go/Ollama/Groq in this new settings path. OpenAI key operations call `OpenAIKeyStoring`; local CLI providers show login/setup status only and never present token fields.

- [ ] **Step 5: Run GREEN**
- [ ] **Step 6: Commit `feat: add provider account settings`**

### Task 4: General settings surfaces and persistence

**Files:**
- Replace/major refactor: `ZeroLose/ZeroLose/Views/SettingsView.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/AutonomySettingsView.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/MemoryContextSettingsView.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/ToolsSettingsView.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/PrivacyDiagnosticsSettingsView.swift`
- Create: `ZeroLose/ZeroLose/V2/Application/GeneralSettingsStore.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/SettingsSurfaceTests.swift`

**Interfaces:**
- Produces only sections: Provider Accounts, Model Defaults, Autonomy & Safety, Memory & Context, Tools & MCP, Privacy & Data, Diagnostics.

- [ ] **Step 1: Write RED settings-schema round-trip tests**

```swift
struct GeneralSettings: Codable, Sendable, Equatable {
    var defaultMode: WorkspaceMode
    var contextMaxCharacters: Int
    var contextMinimumRelevance: Double
    var longTermMemoryEnabled: Bool
    var approvalPolicy: AuthorityMode
}
```

Use an isolated `UserDefaults(suiteName:)` fake. Assert allowed values round-trip, context characters clamp to a documented safe range (2,000...40,000), relevance clamps to 0...1, and `.fullAccess` is not a selectable approval mode.

- [ ] **Step 2: Write RED source guard for settings sections**

Assert `SettingsView.swift` includes exactly the approved section views and contains no interview role, interview notes, OpenCode Zen/Go API key, Ollama model slots, teleprompter, mock interview, or cheat-sheet settings.

- [ ] **Step 3: Run RED**
- [ ] **Step 4: Implement store and focused section views**

Provider Accounts uses Task 3 view. Model Defaults uses discovered provider models. Autonomy & Safety exposes Ask/Agent default, approval policy, Accessibility/Screen Recording readiness, Emergency Stop semantics. Memory & Context exposes enable toggle, context budget, inspect/pin/forget links. Tools & MCP uses typed tool/server commands. Privacy/Data exposes scoped clear/export operations. Diagnostics contains sanitized build/provider/runtime status only.

- [ ] **Step 5: Run GREEN plus settings migration regression**
- [ ] **Step 6: Commit `refactor: simplify ZeroLose settings`**

### Task 5: General-data migration and legacy-data isolation

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Migration/GeneralAgentMigrationCoordinator.swift`
- Modify: `ZeroLose/ZeroLose/V2/Migration/MigrationStateStore.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/GeneralAgentMigrationTests.swift`

**Interfaces:**
- Consumes: old UserDefaults and existing V2 general conversation/memory stores.
- Produces: migration version `general-agent-v1` and new `GeneralSettings`; no interview data import.

- [ ] **Step 1: Write RED fixture migration tests**

Fixture old defaults include `llm_provider`, custom OpenCode model slots, interview role/notes flags, existing general authority/context settings. Assert migration maps only general settings with safe semantics, never maps old `full` authority above `.auto`/approved equivalent, and ignores interview/provider-secret fields.

- [ ] **Step 2: Write RED non-destructive data tests**

Create temporary interview JSON/database fixture path and hash it before/after migration; hash/path must remain unchanged. Existing V2 ConversationStore/MemoryStore records remain readable and unduplicated. Legacy OpenCode key importer is never invoked.

- [ ] **Step 3: Write RED restart/idempotency tests**

Interrupt after writing staged settings but before migration marker; rerun verifies readback and completes once. Third run is no-op.

- [ ] **Step 4: Run RED**
- [ ] **Step 5: Implement versioned readback-verified migration**
- [ ] **Step 6: Run GREEN**
- [ ] **Step 7: Commit `feat: migrate ZeroLose to general agent settings`**

### Task 6: Remove interview runtime and UI

**Files:**
- Delete: `ZeroLose/ZeroLose/Views/InterviewVaultView.swift`
- Delete: `ZeroLose/ZeroLose/Views/MockInterviewView.swift`
- Delete: `ZeroLose/ZeroLose/Views/TeleprompterView.swift`
- Delete: `ZeroLose/ZeroLose/Views/CheatSheetView.swift`
- Delete: `ZeroLose/ZeroLose/Views/KeyboardDisguiseView.swift`
- Delete: `ZeroLose/ZeroLose/Services/MockInterviewService.swift`
- Delete: `ZeroLose/ZeroLose/Services/VaultService.swift`
- Delete: `ZeroLose/ZeroLose/Services/VaultSearchEngine.swift`
- Delete: `ZeroLose/ZeroLose/Services/ActiveRoleProfileService.swift`
- Delete: `ZeroLose/ZeroLose/Services/InterviewKnowledgeMatcher.swift`
- Delete: `ZeroLose/ZeroLose/Models/InterviewItem.swift`
- Delete: `ZeroLose/ZeroLose/Services/ResponseCacheService.swift`
- Delete: `ZeroLose/ZeroLose/Services/IntelligenceService.swift`
- Delete: `ZeroLose/ZeroLose/Services/TextAnalysis.swift`
- Delete: `ZeroLose/ZeroLose/Services/LLMPromptBuilder.swift`
- Delete: `ZeroLose/ZeroLose/ViewModels/CheatSheetViewModel.swift`
- Modify: `ZeroLose/ZeroLose/Services/WindowManager.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/InterviewDemolitionTests.swift`

**Interfaces:**
- Consumes: `RequestCoordinator` already authoritative for Ask; AgentOrchestrator authoritative for Agent.
- Produces: zero production dependency on interview-only runtime.

- [ ] **Step 1: Write RED forbidden-production-symbol test**

Recursively scan `ZeroLose/ZeroLose` and fail on `InterviewVault`, `MockInterview`, `Teleprompter`, `InterviewKnowledgeMatcher`, `warmUpInterviewContext`, `interviewConcise`, `ActiveRoleProfileService`, `CheatSheetView`, `KeyboardDisguiseView`. Exclude migration comments/tests from the production scan only when necessary; no executable path may reference them.

- [ ] **Step 2: Write RED consumer audit test**

Assert new authoritative container/controller types contain neither `IntelligenceService` nor `ResponseCacheService`. Before deletion, `rg` must show that their only remaining consumers are the files being deleted in this task. `TextAnalysis`, `LLMPromptBuilder`, and `CheatSheetViewModel` are deleted as part of the same dependency closure because the current repo inventory shows they are consumed only by the interview-era intelligence/cheat-sheet path.

- [ ] **Step 3: Run RED**
- [ ] **Step 4: Delete leaf views/services first, then remove WindowManager/ContentView/Settings consumers, then delete `IntelligenceService`, `ResponseCacheService`, `TextAnalysis`, `LLMPromptBuilder`, matcher/vault services, and CheatSheetViewModel**

Do not delete user data files or obsolete Keychain records.

- [ ] **Step 5: Run demolition tests and full ZeroLose suite**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/InterviewDemolitionTests
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test
```

- [ ] **Step 6: Commit `refactor: remove interview-era ZeroLose product surfaces`**

### Task 7: Remove legacy provider router and direct OpenCode HTTP

**Files:**
- Delete: `ZeroLose/ZeroLose/Services/OllamaService.swift`
- Modify: `ZeroLose/ZeroLose/Resources/Constants.swift`
- Modify: `ZeroLose/ZeroLose/Resources/Secrets.swift`
- Modify: `ZeroLose/ZeroLose/Services/DependencyContainer.swift`
- Modify: `ZeroLose/ZeroLose/ZeroLoseApp.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ProviderLegacyDemolitionTests.swift`
- Modify: `scripts/verify_all.py`

**Interfaces:**
- Consumes: `ModelProviderFabric` authoritative in both Ask and Agent paths.
- Produces: no OpenCode Zen/Go direct HTTP, credential fallback, auth-file import, or hard-coded authoritative model catalog.

- [ ] **Step 1: Write RED forbidden-symbol/source tests**

Production scan rejects: `openCodeZen`, `openCodeGo`, `fallbackProvider`, `importOpenCodeKeysIfNeeded`, `.local/share/opencode/auth.json`, `opencode.ai/zen`, `/zen/go/`, legacy provider selection based on `Secrets.is...KeyValid`, and `OllamaService` provider routing.

- [ ] **Step 2: Run RED**
- [ ] **Step 3: Remove app-start credential import and old provider settings/constants**
- [ ] **Step 4: Require `rg -n "OllamaService" ZeroLose/ZeroLose --glob "*.swift"` to show only `OllamaService.swift` itself, then delete it. Any needed general message/transport types must already have moved to provider-neutral files in earlier plans; do not retain a compatibility router.**
- [ ] **Step 5: Extend `verify_all.py` with the same production forbidden surface**
- [ ] **Step 6: Run provider + full ZeroLose suites and `python3 scripts/verify_all.py`**
- [ ] **Step 7: Commit `refactor: remove legacy model provider router`**
