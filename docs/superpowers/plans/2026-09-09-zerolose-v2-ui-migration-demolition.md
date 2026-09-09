# ZeroLose V2 UI Migration and Legacy Demolition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move ZeroLose UI onto V2 application commands/projections, migrate valuable user data safely, switch authoritative execution to V2, and then delete legacy `[ACTION]`, approval, and GhostViewModel execution responsibilities.

**Architecture:** Keep the useful SwiftUI visual shell, but views talk only to `@MainActor` V2 view models and an `ApplicationFacade`. Runtime state is projected from EventStore. Migration is versioned/idempotent/restart-safe. Legacy code is deleted only after deterministic parity gates prove V2 replacements.

**Tech Stack:** SwiftUI, Observation `@Observable`, `@MainActor`, Swift Concurrency, UserDefaults/AppStorage for presentation preferences only, Keychain through CredentialBroker, XCTest/XCUITest where valuable.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- UI never executes tools, physical input, or model providers directly.
- UI never owns PolicyKernel decisions or raw credentials.
- Runtime authority is not stored as a UserDefaults/AppStorage string.
- Existing Liquid Glass appearance may remain; this track is not a gratuitous redesign.
- Legacy `full` approval migrates to V2 Auto, never V2 Full Access.
- Migration is versioned, idempotent, restart-safe, and preserves valuable user data until V2 readback is verified.
- No new V2 feature is added to `GhostViewModel`.
- Legacy demolition happens only after deterministic parity.
- No permanent dual runtime remains.
- TDD required for behavior changes; final gate `python3 scripts/verify_all.py`.

---

### Task 1: ApplicationFacade and typed UI commands

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Application/ApplicationCommand.swift`
- Create: `ZeroLose/ZeroLose/V2/Application/ApplicationFacade.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ApplicationFacadeTests.swift`

**Interfaces:** Commands cover goal/chat submit, pause/resume/cancel, approval decisions, tool/MCP enable-disable, memory pin/forget, and authority-mode change. Facade delegates to runtime/services and exposes no raw execution primitives to SwiftUI.

- [ ] **Step 1: Write failing routing test**

```swift
func testPauseCommandRoutesToRuntime() async throws {
    let runtime = RecordingAutonomousRuntime()
    let facade = ApplicationFacade(runtime: runtime)
    try await facade.send(.pauseGoal(.init(rawValue: "g1")))
    XCTAssertEqual(await runtime.pauseCount, 1)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ApplicationFacadeTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement typed command/facade boundary**

```swift
enum ApplicationCommand: Sendable {
    case submitUserGoal(String)
    case sendChatMessage(String)
    case pauseGoal(GoalID)
    case resumeGoal(GoalID)
    case cancelGoal(GoalID)
    case approveInvocation(InvocationID)
    case denyInvocation(InvocationID)
    case enableTool(ToolID)
    case disableTool(ToolID)
    case enableMCPServer(String)
    case disableMCPServer(String)
    case forgetMemoryEntry(String)
    case pinMemoryEntry(String)
    case changeAuthorityMode(AuthorityMode)
}
```

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Application ZeroLose/ZeroLoseTests/V2/ApplicationFacadeTests.swift
git commit -m "feat: add V2 application command facade"
```

### Task 2: Event projections and focused MainActor view models

**Files:**
- Create: `ZeroLose/ZeroLose/V2/UI/TimelineProjection.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/ChatViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/TaskRuntimeViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/ApprovalViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/ToolManagementViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/MemoryInspectorViewModel.swift`
- Create: `ZeroLose/ZeroLose/V2/UI/SettingsViewModel.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ViewModelProjectionTests.swift`

**Interfaces:** View models consume immutable projection snapshots + `ApplicationFacade`; they render state and forward commands only. Success presentation requires verification evidence.

- [ ] **Step 1: Write failing projection test**

```swift
@MainActor
func testTimelineDoesNotShowSuccessForReceiptAlone() {
    let projection = TimelineProjection()
    projection.consume(.test(kind: .toolExecutionCompleted))
    XCTAssertFalse(projection.items.contains { $0.state == .succeeded })
    projection.consume(.test(kind: .verificationCompleted))
    XCTAssertTrue(projection.items.contains { $0.state == .succeeded })
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ViewModelProjectionTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement focused observables**

```swift
@MainActor
@Observable
final class ApprovalViewModel {
    private(set) var pending: [ApprovalPresentation] = []
    private let facade: ApplicationFacade
    init(facade: ApplicationFacade) { self.facade = facade }
}
```

Do not rebuild a second god object. Each view model has one product responsibility.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/UI ZeroLose/ZeroLoseTests/V2/ViewModelProjectionTests.swift
git commit -m "feat: add V2 UI projections and view models"
```

### Task 3: Versioned settings and credential migration

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Migration/MigrationStateStore.swift`
- Create: `ZeroLose/ZeroLose/V2/Migration/SettingsMigrationCoordinator.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/SettingsMigrationTests.swift`
- Read-only references: `ContentView.swift`, `SettingsView.swift`, `Resources/Secrets.swift`.

**Interfaces:** Presentation settings migrate to V2 settings. Existing Keychain remains canonical. Legacy approval mapping: ask→manual, auto→auto, full→auto.

- [ ] **Step 1: Write failing safety/idempotency tests**

```swift
func testLegacyFullDoesNotMigrateToV2FullAccess() throws {
    XCTAssertEqual(try SettingsMigrationCoordinator.mapLegacyApprovalMode("full"), .auto)
}

func testSettingsMigrationIsIdempotent() async throws {
    let coordinator = makeMigrationCoordinator()
    try await coordinator.run()
    let first = await coordinator.snapshot()
    try await coordinator.run()
    XCTAssertEqual(await coordinator.snapshot(), first)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/SettingsMigrationTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement restart-safe migration state**

```swift
enum MigrationStepState: String, Codable, Sendable { case notStarted, running, completed, failed }
```

Do not delete legacy values in the initial copy operation; mark migration complete only after V2 readback verifies expected data.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Migration ZeroLose/ZeroLoseTests/V2/SettingsMigrationTests.swift
git commit -m "feat: add restart-safe V2 settings migration"
```

### Task 4: Conversation/history migration into ConversationStore

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Conversation/ConversationStore.swift`
- Create: `ZeroLose/ZeroLose/V2/Conversation/SQLiteConversationStore.swift`
- Create: `ZeroLose/ZeroLose/V2/Migration/LegacyConversationMigrator.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ConversationMigrationTests.swift`
- Read-only references: `ChatHistoryService.swift`, `VectorStore.swift`.

**Interfaces:** ConversationStore is separate from EventStore and MemoryStore. Legacy vector entries preserve provenance and are not automatically promoted to verified semantic truth.

- [ ] **Step 1: Write failing separation/duplicate tests**

```swift
func testConversationMigrationDoesNotAppendRuntimeEvents() async throws {
    let eventStore = RecordingEventStore()
    let migrator = makeLegacyConversationMigrator(eventStore: eventStore)
    try await migrator.run()
    XCTAssertEqual(await eventStore.appendCount, 0)
}

func testRerunDoesNotDuplicateConversation() async throws {
    let migrator = makeLegacyConversationMigrator()
    try await migrator.run()
    let count = await migrator.destinationCount
    try await migrator.run()
    XCTAssertEqual(await migrator.destinationCount, count)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ConversationMigrationTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement separate store/migrator**

Preserve user-visible history and source provenance. Do not copy raw credentials, headers, or complete provider payloads.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Conversation ZeroLose/ZeroLose/V2/Migration/LegacyConversationMigrator.swift ZeroLose/ZeroLoseTests/V2/ConversationMigrationTests.swift
git commit -m "feat: migrate legacy conversations into V2 store"
```

### Task 5: Route existing SwiftUI shell through V2 boundaries

**Files:**
- Modify: `ZeroLose/ZeroLose/Views/ContentView.swift`
- Modify: `ZeroLose/ZeroLose/Views/SettingsView.swift`
- Modify: `ZeroLose/ZeroLose/Services/DependencyContainer.swift`
- Create: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/UIBoundaryTests.swift`

**Interfaces:** Runtime container assembles V2 services and exposes facade/view models. Views retain presentation behavior but lose direct secrets/model/tool/runtime execution access.

- [ ] **Step 1: Add boundary tests that initially fail**

```swift
func testContentViewContainsNoDirectCredentialAccess() throws {
    let source = try String(contentsOfFile: sourcePath("Views/ContentView.swift"))
    XCTAssertFalse(source.contains("Secrets."))
}

func testV2UISourcesDoNotReferenceExecutionKernel() throws {
    for source in try v2UISources() {
        XCTAssertFalse(source.contents.contains("ToolFabric"))
        XCTAssertFalse(source.contents.contains("PolicyKernel"))
    }
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/UIBoundaryTests test CODE_SIGNING_ALLOWED=NO
```

Expected: current `ContentView` direct `Secrets` access causes RED.

- [ ] **Step 3: Move provider/settings/runtime actions behind V2 view models/facade**

Preserve macOS 26 Liquid Glass `#available` gating and fallbacks. Do not perform unrelated visual redesign.

- [ ] **Step 4: Verify GREEN and repository gate**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
python3 scripts/verify_all.py
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/Views/ContentView.swift ZeroLose/ZeroLose/Views/SettingsView.swift ZeroLose/ZeroLose/Services/DependencyContainer.swift ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift ZeroLose/ZeroLoseTests/V2/UIBoundaryTests.swift
git commit -m "refactor: route ZeroLose UI through V2 facade"
```

### Task 6: Switch authoritative runtime and demolish legacy execution

**Files:**
- Modify/Delete after parity: `GhostViewModel.swift`, `AgentCapability.swift`, legacy ACTION prompt/parser paths, obsolete direct ZeroOperator/computer-use hooks.
- Modify: `scripts/verify_all.py`
- Test: `ZeroLose/ZeroLoseTests/V2/LegacyDemolitionTests.swift`

**Interfaces:** V2 is the only authoritative execution runtime. No V2→ACTION→legacy executor compatibility path remains.

- [ ] **Step 1: Add release-blocking guard tests**

```swift
func testProductionTreeContainsNoLegacyActionExecutionTokens() throws {
    let forbidden = ["[ACTION:", "actionRegex", "handleActions("]
    for source in try productionSwiftSources() {
        for token in forbidden {
            XCTAssertFalse(source.contents.contains(token), "\(source.path): \(token)")
        }
    }
}
```

Extend `scripts/verify_all.py` with the same deterministic forbidden-token scan after V2 parity.

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/LegacyDemolitionTests test CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL while legacy paths still exist.

- [ ] **Step 3: Delete only in verified dependency order**

1. ACTION prompt generation
2. `actionRegex`
3. `handleActions`
4. broken JSON recovery
5. native-tool→ACTION conversion
6. AgentCapabilityRegistry execution dependency
7. legacy approval semantics
8. direct UI→ZeroOperator mutation path
9. obsolete computer-use path
10. GhostViewModel responsibilities after consumers move
11. dead adapters

Do not delete user history/settings/vector DB/Keychain data as part of source demolition.

- [ ] **Step 4: Run all gates**

```bash
cd ExamPilot
swift test
swift build -c release
cd ..
python3 scripts/verify_all.py
git grep -n '\[ACTION:\|actionRegex\|handleActions' -- ZeroLose
```

Expected: all tests/builds PASS and production grep is empty.

- [ ] **Step 5: Commit only after checking `.freebuff/` is not staged**

```bash
git add -A ZeroLose scripts/verify_all.py
git status --short
git commit -m "refactor: remove legacy ZeroLose action runtime"
```

### Track completion gate

```bash
python3 scripts/verify_all.py
git status --short
```

Expected: PASS; V2 is authoritative, valuable user data is preserved, no permanent dual runtime remains, and `.freebuff/` is untouched.
