# ZeroLose V2 Tool Fabric Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the foundation contracts into a provider-based Unified Tool Fabric with authoritative policy gating, hot revoke, MCP/plugin boundaries, idempotency metadata, and an inventory-only legacy adapter.

**Architecture:** `ToolFabric` resolves an immutable registry snapshot, validates descriptor identity/revision, checks credential scope, asks the current `PolicyKernel`, and only then calls the selected provider. Providers implement capability, never approval authority. Legacy capability metadata may be mapped into descriptors temporarily, but V2 never executes through `[ACTION]`.

**Tech Stack:** Swift, Swift Concurrency actors, Codable/JSON, XCTest, MCP transport adapters.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Preserve `.freebuff/` untouched.
- Keep Swift 5 language mode during this track.
- Provider/MCP risk annotations are advisory only.
- Raw credentials never enter ToolDescriptor, prompts, events, or model-visible state.
- Every ZeroLose physical mutation re-enters Tool Fabric and `PolicyKernel`.
- External mutations carry explicit idempotency semantics.
- TDD required for behavior changes.
- Final track gate: `python3 scripts/verify_all.py`.

---

### Task 1: ToolProviding and authoritative ToolFabric pipeline

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Tools/ToolProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Tools/ToolExecutionReceipt.swift`
- Create: `ZeroLose/ZeroLose/V2/Tools/ToolFabric.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ToolFabricTests.swift`

**Interfaces:** Consumes `ToolRegistry`, `PolicyEvaluating`, `CredentialBrokering`, `ToolInvocation`; produces policy-gated provider dispatch and `ToolExecutionReceipt`.

- [ ] **Step 1: Write failing fail-closed tests**

```swift
func testUnknownToolNeverReachesProvider() async throws {
    let provider = RecordingToolProvider()
    let fabric = makeFabric(provider: provider)
    await XCTAssertThrowsErrorAsync(try await fabric.execute(.test(toolID: "builtin.missing")))
    XCTAssertEqual(await provider.executionCount, 0)
}

func testStaleRegistryRevisionNeverReachesProvider() async throws {
    let provider = RecordingToolProvider()
    let fabric = makeFabric(provider: provider)
    await XCTAssertThrowsErrorAsync(try await fabric.execute(.test(toolID: "builtin.echo", registryRevision: 0)))
    XCTAssertEqual(await provider.executionCount, 0)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ToolFabricTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement ordered gate**

```swift
protocol ToolProviding: Sendable {
    var providerID: String { get }
    func execute(descriptor: ToolDescriptor, invocation: ToolInvocation, credentialHandle: CredentialHandle?) async throws -> ToolExecutionReceipt
}

struct ToolExecutionReceipt: Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let startedAt: Date
    let completedAt: Date
    let providerReference: String?
}
```

`ToolFabric.execute` must perform, in order: registry snapshot/revision check → descriptor/schema check → required credential availability → current policy evaluation → opaque credential handle issuance → provider execution. Provider execution before any earlier gate is a bug.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Tools ZeroLose/ZeroLoseTests/V2/ToolFabricTests.swift
git commit -m "feat: add policy-gated V2 tool fabric"
```

### Task 2: Builtin and Computer provider boundaries

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Tools/Providers/BuiltinToolProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Tools/Providers/ComputerToolProvider.swift`
- Create: `ZeroLose/ZeroLose/V2/Computer/ComputerMutationGateway.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ComputerToolProviderTests.swift`

**Interfaces:** Computer provider converts validated invocation arguments into `ComputerPhysicalProposal`; it cannot call CoreGraphics/InputDriving directly.

- [ ] **Step 1: Write failing re-entry test**

```swift
func testComputerProviderRoutesMutationThroughGateway() async throws {
    let gateway = RecordingComputerMutationGateway()
    let provider = ComputerToolProvider(gateway: gateway)
    _ = try await provider.execute(descriptor: .test(id: "computer.pointer.click"), invocation: .test(toolID: "computer.pointer.click"), credentialHandle: nil)
    XCTAssertEqual(await gateway.proposalCount, 1)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/ComputerToolProviderTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement gateway contract**

```swift
struct ComputerPhysicalProposal: Sendable, Equatable {
    let action: String
    let stateVersion: UInt64
    let observationID: String
    let argumentsJSON: Data
}

protocol ComputerMutationGating: Sendable {
    func executePhysicalProposal(_ proposal: ComputerPhysicalProposal, parentInvocationID: InvocationID) async throws -> ToolExecutionReceipt
}
```

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Tools/Providers ZeroLose/ZeroLose/V2/Computer ZeroLose/ZeroLoseTests/V2/ComputerToolProviderTests.swift
git commit -m "feat: add builtin and computer provider boundaries"
```

### Task 3: First-class MCP discovery and refresh

**Files:**
- Create: `ZeroLose/ZeroLose/V2/MCP/MCPClient.swift`
- Create: `ZeroLose/ZeroLose/V2/MCP/MCPModels.swift`
- Create: `ZeroLose/ZeroLose/V2/MCP/MCPToolMapper.swift`
- Create: `ZeroLose/ZeroLose/V2/MCP/MCPToolProvider.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MCPToolProviderTests.swift`

**Interfaces:** Maps `tools/list` to `mcp.<server>.<tool>` descriptors; list changes update registry revision; external tool descriptions/results preserve provenance/taint.

- [ ] **Step 1: Write failing namespace/advisory-annotation tests**

```swift
func testMCPToolUsesStableNamespace() throws {
    let descriptor = try MCPToolMapper(serverID: "gmail").descriptor(for: .test(name: "send_message"))
    XCTAssertEqual(descriptor.id.rawValue, "mcp.gmail.send_message")
}

func testReadOnlyHintCannotDowngradeKnownExternalEffect() throws {
    let descriptor = try MCPToolMapper(serverID: "gmail").descriptor(for: .test(name: "send_message", readOnlyHint: true))
    XCTAssertEqual(descriptor.effectClass, .externalCommunication)
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/MCPToolProviderTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement normalized MCP protocol**

```swift
protocol MCPClient: Sendable {
    func listTools() async throws -> [MCPDiscoveredTool]
    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolResult
}
```

`refresh()` maps current discovery into descriptors, revokes removed tools, and advances registry revision.

- [ ] **Step 4: Verify GREEN**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/MCP ZeroLose/ZeroLoseTests/V2/MCPToolProviderTests.swift
git commit -m "feat: add first-class MCP tool provider"
```

### Task 4: Declarative Plugin boundary

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Plugins/PluginManifest.swift`
- Create: `ZeroLose/ZeroLose/V2/Plugins/PluginExecutionBoundary.swift`
- Create: `ZeroLose/ZeroLose/V2/Plugins/PluginToolProvider.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/PluginManifestTests.swift`

**Interfaces:** Manifest declares ID/version/capabilities/credential scopes/provenance/optional MCP config. No arbitrary in-process third-party Swift loading.

- [ ] **Step 1: Write failing manifest test**

```swift
func testManifestDecodesCapabilitiesAndScopes() throws {
    let data = #"{"id":"github-workflows","version":"1.0.0","capabilities":["issues.create"],"credentialScopes":["github.issues.write"]}"#.data(using: .utf8)!
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    XCTAssertEqual(manifest.id, "github-workflows")
    XCTAssertEqual(manifest.credentialScopes, ["github.issues.write"])
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/PluginManifestTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement manifest/boundary**

```swift
struct PluginManifest: Codable, Sendable, Equatable {
    let id: String
    let version: String
    let capabilities: [String]
    let credentialScopes: [String]
}

protocol PluginExecutionBoundary: Sendable {
    func invoke(pluginID: String, capability: String, argumentsJSON: Data) async throws -> Data
}
```

- [ ] **Step 4: Verify and scan for dynamic loading**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
git grep -n 'dlopen\|Bundle.*load' -- ZeroLose/ZeroLose/V2/Plugins
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Plugins ZeroLose/ZeroLoseTests/V2/PluginManifestTests.swift
git commit -m "feat: add declarative V2 plugin boundary"
```

### Task 5: Idempotency enforcement and inventory-only legacy adapter

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Legacy/AgentCapabilityRegistryAdapter.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/LegacyCapabilityAdapterTests.swift`
- Read-only reference: `ZeroLose/ZeroLose/Services/AgentCapability.swift`

**Interfaces:** Adapter returns `[ToolDescriptor]` only. External mutation descriptors cannot use `.none` idempotency. No execution method, `[ACTION]`, or `handleActions` dependency.

- [ ] **Step 1: Write failing source/metadata tests**

```swift
func testAdapterContainsNoActionRoundTrip() throws {
    let source = try String(contentsOfFile: sourcePath("V2/Legacy/AgentCapabilityRegistryAdapter.swift"))
    XCTAssertFalse(source.contains("[ACTION:"))
    XCTAssertFalse(source.contains("handleActions"))
}
```

- [ ] **Step 2: Observe RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' -only-testing:ZeroLoseTests/LegacyCapabilityAdapterTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement inventory mapping**

Every external mutation maps to `.logicalOperationKeyRequired` or `.providerNative` and carries a verification contract.

- [ ] **Step 4: Verify and scan V2 tree**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
git grep -n '\[ACTION:\|handleActions' -- ZeroLose/ZeroLose/V2
```

- [ ] **Step 5: Commit**

```bash
git add ZeroLose/ZeroLose/V2/Legacy ZeroLose/ZeroLoseTests/V2/LegacyCapabilityAdapterTests.swift
git commit -m "feat: complete V2 tool provider boundaries"
```

### Track completion gate

```bash
python3 scripts/verify_all.py
git diff --check
```

Expected: PASS; V2 Tool Fabric is independently testable while legacy production behavior remains unchanged.
