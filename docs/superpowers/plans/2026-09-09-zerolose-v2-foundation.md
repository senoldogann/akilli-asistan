# ZeroLose V2 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the typed V2 kernel contracts for identity, policy, tool descriptors/invocations, credential scope, and runtime events without changing legacy execution behavior.

**Architecture:** New code lives under `ZeroLose/ZeroLose/V2/` and remains inert until later tracks wire it into production. Use immutable value types across boundaries and actors for shared mutable runtime state. Do not touch `GhostViewModel`, `ZeroOperator`, ExamPilot execution, or legacy `[ACTION]` dispatch in this track.

**Tech Stack:** Swift 5 language mode, Foundation, Swift Concurrency actors, XCTest, macOS Keychain adapter boundary.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Source of truth when available: `/Users/dogan/Desktop/akilli-asistan` via `@chatgpt-system-local`.
- Preserve `.freebuff/` untouched.
- Baseline SHA: `471d025f7ed3477197e0b507aec748fee72a539f`.
- Swift-first trusted kernel; no Node/TypeScript dependency in the kernel.
- Keep current Swift 5 language mode; Swift 6 migration is separate.
- SwiftUI state is `@MainActor`; runtime/kernel state uses explicit isolation.
- No raw credentials, Authorization headers, private typed content, or raw screenshots in V2 persistence/telemetry.
- No `[ACTION: {...}]` compatibility at V2 boundaries.
- TDD for behavior changes: RED → minimal GREEN → focused verification → affected suite.
- Repository completion gate: `python3 scripts/verify_all.py`.

---

### Task 1: Runtime IDs and approved risk vocabulary

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Core/RuntimeIDs.swift`
- Create: `ZeroLose/ZeroLose/V2/Policy/RiskModel.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RuntimeIDsTests.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RiskModelTests.swift`

**Interfaces:** Produces `GoalID`, `TaskID`, `SessionID`, `InvocationID`, `RuntimeEventID`, `AuthorityMode`, `RiskLevel`, `EffectClass`.

- [ ] **Step 1: Write failing tests**

```swift
func testGoalIDHasValueSemantics() {
    XCTAssertEqual(GoalID(rawValue: "g1"), GoalID(rawValue: "g1"))
}

func testRiskScaleMatchesApprovedOrder() {
    XCTAssertLessThan(RiskLevel.readOnly.rawValue, RiskLevel.reversibleLocalMutation.rawValue)
    XCTAssertLessThan(RiskLevel.reversibleLocalMutation.rawValue, RiskLevel.externalCommunication.rawValue)
    XCTAssertLessThan(RiskLevel.externalCommunication.rawValue, RiskLevel.highImpactExternalMutation.rawValue)
    XCTAssertLessThan(RiskLevel.highImpactExternalMutation.rawValue, RiskLevel.irreversible.rawValue)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeIDsTests -only-testing:ZeroLoseTests/RiskModelTests test CODE_SIGNING_ALLOWED=NO
```

Expected: missing V2 types.

- [ ] **Step 3: Implement minimal values**

```swift
struct GoalID: Hashable, Codable, Sendable { let rawValue: String }
struct TaskID: Hashable, Codable, Sendable { let rawValue: String }
struct SessionID: Hashable, Codable, Sendable { let rawValue: String }
struct InvocationID: Hashable, Codable, Sendable { let rawValue: String }
struct RuntimeEventID: Hashable, Codable, Sendable { let rawValue: String }

enum AuthorityMode: String, Codable, Sendable { case manual, auto, autonomous, fullAccess }
enum RiskLevel: Int, Codable, Comparable, Sendable {
    case readOnly = 0, reversibleLocalMutation = 1, externalCommunication = 2, highImpactExternalMutation = 3, irreversible = 4
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
enum EffectClass: String, Codable, Sendable { case read, reversibleLocalMutation, externalCommunication, highImpactExternalMutation, irreversible }
```

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Core ZeroLose/ZeroLose/V2/Policy/RiskModel.swift ZeroLose/ZeroLoseTests/V2/RuntimeIDsTests.swift ZeroLose/ZeroLoseTests/V2/RiskModelTests.swift
git commit -m "feat: add ZeroLose V2 runtime vocabulary"
```

### Task 2: Fail-closed PolicyKernel contract

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Policy/PolicyContext.swift`
- Create: `ZeroLose/ZeroLose/V2/Policy/PolicyKernel.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/PolicyKernelTests.swift`

**Interfaces:** Policy input carries mode, declared risk, effect class, capability presence, credential scope result, taint, optional tool/task/destination/argument digest. Provider metadata never becomes authoritative risk.

- [ ] **Step 1: Write failing tests**

```swift
func testUnknownCapabilityFailsClosed() async {
    let decision = await DefaultPolicyKernel().evaluate(.test(capabilityKnown: false))
    XCTAssertEqual(decision, .deny(reason: .unknownCapability))
}

func testFullAccessCannotBypassMissingCredentialScope() async {
    let decision = await DefaultPolicyKernel().evaluate(.test(authorityMode: .fullAccess, credentialScopeSatisfied: false))
    XCTAssertEqual(decision, .deny(reason: .credentialScopeMissing))
}

func testIrreversibleEffectIsHardDeniedByDefault() async {
    let decision = await DefaultPolicyKernel().evaluate(.test(authorityMode: .fullAccess, declaredRisk: .readOnly, effectClass: .irreversible))
    XCTAssertEqual(decision, .deny(reason: .hardPolicyDenied))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/PolicyKernelTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement policy boundary**

```swift
struct PolicyContext: Sendable, Equatable {
    let authorityMode: AuthorityMode
    let declaredRisk: RiskLevel
    let effectClass: EffectClass
    let capabilityKnown: Bool
    let credentialScopeSatisfied: Bool
    let tainted: Bool
    let toolID: String?
    let taskID: TaskID?
    let destination: String?
    let argumentsDigest: String?
}

enum PolicyDenialReason: String, Sendable, Equatable { case unknownCapability, credentialScopeMissing, approvalRequired, hardPolicyDenied }
enum PolicyDecision: Sendable, Equatable { case allow, deny(reason: PolicyDenialReason) }
protocol PolicyEvaluating: Sendable { func evaluate(_ context: PolicyContext) async -> PolicyDecision }
```

`DefaultPolicyKernel` computes effective risk as at least the floor implied by `effectClass`; irreversible is hard-denied by default; external/high-impact require appropriate current authority and never bypass missing credential scope.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/PolicyKernelTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Policy ZeroLose/ZeroLoseTests/V2/PolicyKernelTests.swift
git commit -m "feat: add fail-closed V2 policy kernel"
```

### Task 3: Complete ToolDescriptor and revisioned ToolRegistry

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Tools/ToolDescriptor.swift`
- Create: `ZeroLose/ZeroLose/V2/Tools/ToolInvocation.swift`
- Create: `ZeroLose/ZeroLose/V2/Tools/ToolRegistry.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ToolRegistryTests.swift`

**Interfaces:** `ToolDescriptor` contains stable ID, provider/provenance, input/output schemas, effect, declared risk, credential scopes, idempotency, concurrency class, enabled state, verification contract. `ToolInvocation` binds to registry revision + descriptor revision + schema digest.

- [ ] **Step 1: Write failing snapshot/revoke tests**

```swift
func testOldSnapshotDoesNotChangeAfterRegister() async {
    let registry = ToolRegistry()
    let before = await registry.snapshot()
    await registry.register(.test(id: "builtin.echo"))
    let after = await registry.snapshot()
    XCTAssertEqual(before.revision, 0)
    XCTAssertEqual(after.revision, 1)
    XCTAssertNil(before.descriptors[.init(rawValue: "builtin.echo")])
}

func testRevokedToolCannotResolve() async {
    let registry = ToolRegistry()
    let id = ToolID(rawValue: "builtin.echo")
    await registry.register(.test(id: id.rawValue))
    await registry.revoke(id)
    XCTAssertNil(await registry.resolve(id))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ToolRegistryTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement descriptor/registry contracts**

```swift
struct ToolID: Hashable, Codable, Sendable { let rawValue: String }
enum ToolConcurrencyClass: String, Codable, Sendable { case read, mutation }
enum IdempotencySemantics: String, Codable, Sendable { case none, logicalOperationKeyRequired, providerNative }
struct VerificationContract: Codable, Sendable, Equatable { let kind: String }

struct ToolDescriptor: Sendable, Equatable {
    let id: ToolID
    let providerID: String
    let provenance: String
    let descriptorRevision: UInt64
    let schemaDigest: String
    let inputSchemaJSON: Data
    let outputSchemaJSON: Data?
    let effectClass: EffectClass
    let declaredRisk: RiskLevel
    let requiredCredentialScopes: Set<String>
    let idempotency: IdempotencySemantics
    let concurrencyClass: ToolConcurrencyClass
    let verificationContract: VerificationContract
    let enabled: Bool
}
```

`ToolRegistry` is an actor with monotonically increasing revision and immutable snapshots.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Tools ZeroLose/ZeroLoseTests/V2/ToolRegistryTests.swift
git commit -m "feat: add revisioned V2 tool registry"
```

### Task 4: CredentialBroker metadata/opaque-handle boundary

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Credentials/CredentialBroker.swift`
- Create: `ZeroLose/ZeroLose/V2/Credentials/KeychainCredentialBrokerAdapter.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/CredentialBrokerTests.swift`
- Read-only reference: `ZeroLose/ZeroLose/Resources/Secrets.swift`

**Interfaces:** Public broker APIs expose only credential scope availability and opaque handles. The Keychain-backed adapter may read existing secrets internally, but never returns raw values to model/runtime metadata.

- [ ] **Step 1: Write failing availability/revocation tests**

```swift
func testAvailabilityExposesOnlyScopeMetadata() async {
    let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])
    XCTAssertTrue(await broker.availability(for: .init(rawValue: "openai.responses")).available)
}

func testRevocationInvalidatesHandle() async throws {
    let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])
    let scope = CredentialScope(rawValue: "openai.responses")
    let handle = try await broker.issueHandle(for: scope)
    await broker.revoke(scope: scope)
    XCTAssertFalse(await broker.isValid(handle))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/CredentialBrokerTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement boundary**

```swift
struct CredentialScope: Hashable, Codable, Sendable { let rawValue: String }
struct CredentialAvailability: Sendable, Equatable { let scope: CredentialScope; let available: Bool }
struct CredentialHandle: Hashable, Sendable { fileprivate let id: UUID; let scope: CredentialScope }
protocol CredentialBrokering: Sendable {
    func availability(for scope: CredentialScope) async -> CredentialAvailability
    func issueHandle(for scope: CredentialScope) async throws -> CredentialHandle
    func revoke(scope: CredentialScope) async
}
```

- [ ] **Step 4: Verify GREEN and scan public broker APIs**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
git grep -n 'Credential.*-> String\|secret.*-> String' -- ZeroLose/ZeroLose/V2/Credentials
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Credentials ZeroLose/ZeroLoseTests/V2/CredentialBrokerTests.swift
git commit -m "feat: add scoped credential broker boundary"
```

### Task 5: Canonical RuntimeEvent and EventStore protocol

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Events/RuntimeEvent.swift`
- Create: `ZeroLose/ZeroLose/V2/Events/EventStore.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RuntimeEventTests.swift`

**Interfaces:** Event envelope includes event/stream/sequence/schema IDs, goal/task/session, kind, causation/correlation, graph/tool/policy revisions, payload, redaction, provenance/taint, recordedAt. Existing ExamPilot `AgentEvent` remains diagnostic only.

- [ ] **Step 1: Write failing sequence/redaction tests**

```swift
func testSequenceIsOrderingAuthority() {
    let a = RuntimeEvent.test(sequence: 1, recordedAt: .distantFuture)
    let b = RuntimeEvent.test(sequence: 2, recordedAt: .distantPast)
    XCTAssertLessThan(a.sequence, b.sequence)
}

func testCredentialMaterialCannotBePersisted() {
    XCTAssertFalse(RedactionClass.credentialMaterial.isPersistable)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/RuntimeEventTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement canonical contracts**

```swift
enum RedactionClass: String, Codable, Sendable { case normal, privateContent, credentialMaterial }
protocol EventStoring: Sendable {
    func append(_ event: RuntimeEvent) async throws
    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent]
}
```

`RuntimeEventKind` must include goal/task graph/budget/observation/planning/tool/policy/approval/evidence/verification/recovery/memory/runtime/checkpoint/reconciliation families from the spec.

- [ ] **Step 4: Verify GREEN and repository gate**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
python3 scripts/verify_all.py
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Events ZeroLose/ZeroLoseTests/V2/RuntimeEventTests.swift
git commit -m "feat: define V2 runtime event contracts"
```

### Track completion gate

```bash
python3 scripts/verify_all.py
git status --short
```

Expected: repository verification passes, legacy behavior is unchanged, and `.freebuff/` remains untouched.
