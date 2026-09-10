# ZeroLose Context and Request Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace interview-specific request orchestration with a general relevance-based `ContextOrchestrator` and provider-neutral Ask request pipeline.

**Architecture:** Context sources are independent, presentation-safe services that return provenance-carrying candidates. `ContextOrchestrator` queries every configured source on every request, rejects credential material, deterministically scores/deduplicates/budgets candidates, and produces a `ContextBundle`; `RequestCoordinator` assembles provider-neutral model messages and persists conversation output without owning physical execution authority.

**Tech Stack:** Swift 5, Swift Concurrency, existing `ConversationStoring`, `MemoryStoring`, RuntimeEvent/evidence projections, provider fabric from the provider plan, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-11-zerolose-general-autonomous-agent-redesign.md`

## Global Constraints

- Retrieval runs for every user request; injection is relevance/budget based.
- Latest direct user instruction is always outside retrieved context and therefore outranks memory/context.
- Unverified model output cannot become verified semantic memory automatically.
- Credentials, provider session IDs, cookies, authorization material, and raw secret-bearing tool payloads are never context candidates.
- Ask mode cannot receive physical computer mutation tool schemas.
- Do not add interview-specific intents, score thresholds, response profiles, or caches.
- First release uses deterministic local scoring; no model reranker is introduced in this plan.

---

### Task 1: Context domain, sensitivity, and deterministic tokenizer

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Context/ContextItem.swift`
- Create: `ZeroLose/ZeroLose/V2/Context/ContextSource.swift`
- Create: `ZeroLose/ZeroLose/V2/Context/ContextScorer.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ContextDomainTests.swift`

**Interfaces:**
- Produces: `ContextSourceKind`, `ContextSensitivity`, `ContextProvenance`, `ContextItem`, `ContextQuery`, `ContextSource`, `ContextScorer`.

- [ ] **Step 1: Write RED domain tests**

```swift
func testCredentialMaterialCannotBecomeContextItem() {
    let provenance = ContextProvenance(
        sourceID: "runtime:credential",
        kind: .runtimeEvidence,
        timestamp: nil,
        tainted: false,
        sensitivity: .credentialMaterial
    )
    XCTAssertThrowsError(
        try ContextItem.validated(
            content: "opaque-secret-material",
            provenance: provenance,
            mandatory: false
        )
    ) { error in
        XCTAssertEqual(error as? ContextValidationError, .credentialMaterialRejected)
    }
}

func testPrivateContentMayRemainContextWithoutBecomingCredentialMaterial() throws {
    let item = try ContextItem.validated(
        content: "User-provided project note",
        provenance: .init(
            sourceID: "attachment:a1",
            kind: .attachment,
            timestamp: Date(timeIntervalSince1970: 10),
            tainted: false,
            sensitivity: .privateContent
        ),
        mandatory: false
    )
    XCTAssertEqual(item.provenance.sensitivity, .privateContent)
}
```

Add tests that `ContextScorer.tokens("SwiftUI, swift-ui SWIFTUI") == ["swiftui"]`, token order is deterministic, and empty/whitespace content is rejected.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ContextDomainTests
```
Expected: context types do not exist.

- [ ] **Step 3: Implement immutable context domain**

```swift
enum ContextSourceKind: String, Codable, Sendable {
    case conversation, memory, attachment, activeTask, runtimeEvidence
}

enum ContextSensitivity: String, Codable, Sendable {
    case normal, privateContent, credentialMaterial
}

struct ContextProvenance: Codable, Sendable, Equatable {
    let sourceID: String
    let kind: ContextSourceKind
    let timestamp: Date?
    let tainted: Bool
    let sensitivity: ContextSensitivity
}

struct ContextItem: Sendable, Equatable, Identifiable {
    let id: String
    let content: String
    let provenance: ContextProvenance
    let mandatory: Bool
    let sourceScore: Double
}

struct ContextQuery: Sendable, Equatable {
    let text: String
    let conversationID: String
    let activeGoalID: GoalID?
}

protocol ContextSource: Sendable {
    var kind: ContextSourceKind { get }
    func candidates(for query: ContextQuery) async throws -> [ContextItem]
}
```

`ContextItem.validated` trims text, rejects empty content and `.credentialMaterial`, clamps `sourceScore` to `0...1`, and derives `id` from the stable provenance source ID plus a content digest when a source-specific record ID is not already unique. `ContextScorer` lowercases with POSIX locale, tokenizes letters/digits, removes duplicate tokens, and scores lexical overlap as `intersection / max(1, queryTokenCount)`.

- [ ] **Step 4: Run focused tests; expect PASS**
- [ ] **Step 5: Commit `feat: add general context domain`**

### Task 2: Conversation and memory context sources

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Context/ConversationContextSource.swift`
- Create: `ZeroLose/ZeroLose/V2/Context/MemoryContextSource.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ConversationMemoryContextSourceTests.swift`

**Interfaces:**
- Consumes: `ConversationStoring`, `MemoryStoring`, `ContextScorer`.
- Produces: conversation and memory `ContextItem` candidates.

- [ ] **Step 1: Write RED conversation-source tests**

Use an in-memory `ConversationStoring` fake with four messages. Assert only the configured latest window is returned, each item uses `.conversation`, native/legacy provenance is retained in sourceID metadata, assistant messages remain conversation context but are never marked verified semantic truth merely because they exist.

```swift
func testConversationSourceReturnsRecentMessagesInRecordedOrder() async throws {
    let store = InMemoryConversationStore(messages: [m1, m2, m3])
    let source = ConversationContextSource(store: store, maxMessages: 2)
    let items = try await source.candidates(for: .init(text: "continue", conversationID: "c1", activeGoalID: nil))
    XCTAssertEqual(items.map(\.provenance.sourceID), ["conversation:m2", "conversation:m3"])
}
```

- [ ] **Step 2: Write RED memory-source tests**

Use semantic, episodic, procedural records. Semantic/episodic non-invalidated records are candidates; procedural records are excluded from ordinary Ask context unless explicitly marked applicable by future task context. Assert `tainted` and provenance map through, invalidated records are excluded, and user-confirmed semantic memory gets a higher `sourceScore` than unconfirmed derived memory.

- [ ] **Step 3: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ConversationMemoryContextSourceTests
```

- [ ] **Step 4: Implement both adapters**

`ConversationContextSource` calls `messages(conversationID:)`, sorts by `(recordedAt, id)`, takes suffix `maxMessages`, and maps to presentation-safe context. `MemoryContextSource` queries `.user` plus optional active goal/application scopes configured by the caller, maps `fact`/`summary`, excludes invalidated records, and never creates new memory.

- [ ] **Step 5: Run GREEN**
- [ ] **Step 6: Commit `feat: add conversation and memory context sources`**

### Task 3: Attachment, active-task, and runtime-evidence context sources

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Context/AttachmentContextSource.swift`
- Create: `ZeroLose/ZeroLose/V2/Context/ActiveTaskContextSource.swift`
- Create: `ZeroLose/ZeroLose/V2/Context/RuntimeEvidenceContextSource.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/OperationalContextSourceTests.swift`

**Interfaces:**
- Consumes: new read-only snapshot protocols `AttachmentContextProviding`, `ActiveTaskContextProviding`, `VerifiedRuntimeEvidenceProviding`.
- Produces: attachment/task/evidence candidates only; no tool execution.

- [ ] **Step 1: Define test seams and write RED source tests**

```swift
struct AttachmentContextSnapshot: Sendable, Equatable {
    let id: String
    let displayName: String
    let extractedText: String
    let recordedAt: Date
}

protocol AttachmentContextProviding: Sendable {
    func attachments(conversationID: String) async -> [AttachmentContextSnapshot]
}

struct ActiveTaskContextSnapshot: Sendable, Equatable {
    let goalID: GoalID
    let summary: String
    let lifecycle: String
    let mandatoryForActiveGoal: Bool
}

protocol ActiveTaskContextProviding: Sendable {
    func activeTask(goalID: GoalID?) async -> ActiveTaskContextSnapshot?
}

struct VerifiedRuntimeEvidenceSnapshot: Sendable, Equatable {
    let evidenceID: String
    let summary: String
    let recordedAt: Date
    let tainted: Bool
    let sensitivity: ContextSensitivity
}
```

Tests assert attachment uses `.privateContent`, active task with matching goal is `mandatory=true`, verified evidence can be included, and any evidence snapshot marked `.credentialMaterial` is rejected before returning candidates.

- [ ] **Step 2: Run RED**
- [ ] **Step 3: Implement the three source adapters**

No adapter accepts `ToolInvocation`, `CredentialHandle`, raw browser cookies, provider stdout, or Authorization headers. Runtime evidence accepts only `VerifiedRuntimeEvidenceSnapshot` produced after verification/redaction.

- [ ] **Step 4: Run GREEN**
- [ ] **Step 5: Commit `feat: add operational context sources`**

### Task 4: Deterministic ContextOrchestrator

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Context/ContextOrchestrator.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/ContextOrchestratorTests.swift`

**Interfaces:**
- Consumes: `[any ContextSource]`, `ContextScorer`.
- Produces: `ContextPolicy`, `ContextExclusion`, `ContextBundle`, `ContextOrchestrator.buildContext(for:)`.

- [ ] **Step 1: Write RED every-source and relevance tests**

```swift
actor RecordingContextSource: ContextSource {
    let kind: ContextSourceKind
    let output: [ContextItem]
    private(set) var queryCount = 0
    init(kind: ContextSourceKind, output: [ContextItem]) { self.kind = kind; self.output = output }
    func candidates(for query: ContextQuery) async throws -> [ContextItem] {
        queryCount += 1
        return output
    }
}

func testEveryRequestQueriesEveryConfiguredSource() async throws {
    let a = RecordingContextSource(kind: .memory, output: [])
    let b = RecordingContextSource(kind: .attachment, output: [])
    let orchestrator = ContextOrchestrator(
        sources: [a, b],
        policy: .init(maxCharacters: 4_000, minimumRelevance: 0.25)
    )
    _ = try await orchestrator.buildContext(
        for: .init(text: "open the project", conversationID: "c1", activeGoalID: nil)
    )
    XCTAssertEqual(await a.queryCount, 1)
    XCTAssertEqual(await b.queryCount, 1)
}
```

Add tests: unrelated memory excluded; relevant memory included; mandatory active-task context survives low lexical overlap; duplicate normalized content keeps the higher-priority provenance; taint preserved; result order stable across repeated builds; total content characters never exceed budget except a single mandatory item, which is truncated with an exclusion record rather than silently overflowing.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/ContextOrchestratorTests
```

- [ ] **Step 3: Implement policy and ranking**

```swift
struct ContextPolicy: Sendable, Equatable {
    let maxCharacters: Int
    let minimumRelevance: Double
}

struct ContextExclusion: Sendable, Equatable {
    enum Reason: String, Sendable { case belowThreshold, duplicate, budgetExceeded, credentialMaterial, empty, sourceFailure }
    let sourceID: String
    let reason: Reason
}

struct ContextBundle: Sendable, Equatable {
    let items: [ContextItem]
    let excluded: [ContextExclusion]
    let usedCharacters: Int
}
```

For each candidate compute `finalScore = max(sourceScore, lexicalOverlap)`. Mandatory active-task context ranks first. Remaining sort key is: final score descending, source priority `activeTask > runtimeEvidence > attachment > conversation > memory`, timestamp descending, sourceID ascending. Deduplicate by normalized content digest. Apply minimum relevance to nonmandatory candidates and then the character budget. Query all sources even when one fails; source failures become presentation-safe exclusions/diagnostics and never cause another provider fallback.

- [ ] **Step 4: Run GREEN and repeat test twice for deterministic ordering**
- [ ] **Step 5: Commit `feat: add relevance-based context orchestrator`**

### Task 5: Safe memory candidate policy

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Context/MemoryCandidatePolicy.swift`
- Modify: `ZeroLose/ZeroLose/V2/Memory/MemoryModels.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/MemoryCandidatePolicyTests.swift`

**Interfaces:**
- Consumes: explicit source category + content + provenance, never arbitrary hidden provider state.
- Produces: optional `MemoryCandidate`; writing remains the caller's explicit action.

- [ ] **Step 1: Write RED candidate tests**

```swift
enum MemoryCandidateSource: Sendable { case explicitUserFact, explicitPin, verifiedTaskFact, assistantOutput, transientToolOutput }

func testAssistantOutputIsNotAutomaticallyMemorable() {
    let policy = MemoryCandidatePolicy()
    XCTAssertNil(policy.candidate(source: .assistantOutput, content: "User likes Rust", provenance: .derived))
}

func testExplicitUserFactCanBecomeCandidate() throws {
    let candidate = try XCTUnwrap(
        MemoryCandidatePolicy().candidate(
            source: .explicitUserFact,
            content: "Prefer concise build logs",
            provenance: .user
        )
    )
    XCTAssertEqual(candidate.provenance, .user)
}
```

Add rejection tests for `.credentialMaterial` sensitivity, authorization/cookie/session structured metadata, empty text, and transient tool output. Verified task fact is allowed only with runtime evidence provenance and evidence ID.

- [ ] **Step 2: Run RED**
- [ ] **Step 3: Implement `MemoryCandidate` and policy**

`MemoryCandidate` includes content, scope, provenance, confidence, tainted, sourceEvidenceID. The policy creates candidates only for the three allowlisted source cases above; no regex-based inference turns ordinary assistant text into memory.

- [ ] **Step 4: Run GREEN plus existing MemoryStore tests**
- [ ] **Step 5: Commit `feat: define safe memory candidate policy`**

### Task 6: Provider-neutral Ask request coordinator

**Files:**
- Create: `ZeroLose/ZeroLose/V2/Application/AskRequest.swift`
- Create: `ZeroLose/ZeroLose/V2/Application/RequestCoordinator.swift`
- Test: `ZeroLose/ZeroLoseTests/V2/RequestCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ContextOrchestrator`, `ModelProviderFabric`, `ConversationStoring`.
- Produces: `stream(_ request: AskRequest) -> AsyncThrowingStream<ModelEvent, Error>` and cancellation by session ID.

- [ ] **Step 1: Write RED ordering and persistence tests**

```swift
struct AskRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversationID: String
    let text: String
    let modelID: String
    let activeGoalID: GoalID?
}
```

Use recording orchestrator/fabric/store fakes. Assert context build happens before provider stream starts; the outgoing conversation contains system context followed by recent conversation and latest direct user message; final assistant text is persisted with `.native` provenance and `verifiedSemanticTruth == false`.

- [ ] **Step 2: Write RED Ask-mode authority test**

Inspect the outgoing `ModelRequest.tools` and assert no tool schema name begins with `computer.`, `browser.mutate`, `shell.`, or any physical-mutation namespace. Read-only tools may be included only through an explicit read-only schema source.

- [ ] **Step 3: Write RED cancellation/error tests**

Cancellation must call `ModelProviderFabric.cancel(sessionID:)`; provider error is surfaced unchanged as normalized `ProviderError` and does not trigger another provider. Partial assistant text is not persisted as a final assistant message after cancellation unless explicitly marked partial in a future schema.

- [ ] **Step 4: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/RequestCoordinatorTests
```

- [ ] **Step 5: Implement coordinator**

The coordinator validates nonempty user text, saves the user conversation message, calls `ContextOrchestrator.buildContext`, renders a bounded context message with source labels but no hidden chain-of-thought, asks the currently selected provider exactly once, forwards streaming events, accumulates text deltas, and saves one final assistant message on `.completed`. It owns no ToolFabric or ComputerMutation dependency.

- [ ] **Step 6: Run GREEN plus ConversationStore tests**
- [ ] **Step 7: Commit `feat: add provider-neutral ask request pipeline`**

### Task 7: Cut normal chat away from IntelligenceService

**Files:**
- Modify: `ZeroLose/ZeroLose/V2/Application/V2ShellRuntimeController.swift`
- Modify: `ZeroLose/ZeroLose/V2/Application/ZeroLoseRuntimeContainer.swift`
- Modify: `ZeroLose/ZeroLose/V2/UI/ChatViewModel.swift` only if streamed presentation needs a typed projection method.
- Test: `ZeroLose/ZeroLoseTests/V2/AskModeBoundaryTests.swift`

**Interfaces:**
- Consumes: `RequestCoordinator`.
- Produces: normal chat/attachment text requests through provider-neutral context/provider contracts only.

- [ ] **Step 1: Write RED source boundary guard**

Read `V2ShellRuntimeController.swift` and production container source. Assert chat submission owns/invokes `RequestCoordinator` and the normal text path contains none of `IntelligenceService`, `InterviewKnowledgeMatcher`, `ResponseCacheService`, `warmUpInterviewContext`, `OllamaService`, or direct provider-specific HTTP methods.

- [ ] **Step 2: Write RED behavior test**

Recording RequestCoordinator receives exactly one Ask request for `sendChatMessage`. Its emitted `.textDelta` events update the assistant presentation; Stop calls coordinator cancellation. Attachment-derived text is fed through `AttachmentContextProviding`, not concatenated into a hidden interview prompt.

- [ ] **Step 3: Run RED**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AskModeBoundaryTests
```

- [ ] **Step 4: Wire RequestCoordinator into shell controller/container**

Do not delete `IntelligenceService` yet; legacy interview/provider demolition occurs only after this new path and UI parity are green. Remove it from the authoritative normal text request path now.

- [ ] **Step 5: Run focused regression**

```bash
xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test -only-testing:ZeroLoseTests/AskModeBoundaryTests -only-testing:ZeroLoseTests/RequestCoordinatorTests -only-testing:ZeroLoseTests/ConversationMigrationTests -only-testing:ZeroLoseTests/MemoryStoreTests
```

- [ ] **Step 6: Commit `refactor: route normal chat through general request coordinator`**
