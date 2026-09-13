# Agent Handoff Notes — ZeroLose V2 Provider Control Plane Cutover

> **To the active agent working on this repo (Codex / Claude / OpenCode / Antigravity):**
> These notes were originally written by an external reviewer on 2026-09-13 after a full audit of
> `feat/zerolose-agent-runtime-composition` at commit `a4fcd69` — Tasks 1-6 of
> `docs/superpowers/plans/2026-09-13-zerolose-v2-ui-control-plane-cutover.md`.
> They are continuously updated with **verified** status. An item is only marked resolved when
> implementation **and** local verification actually completed; anything else stays open.
> All results below are from `/Users/dogan/Desktop/akilli-asistan` on 2026-09-13.

---

## Ship state

| | |
| --- | --- |
| Merged | **PR #28** `feat/zerolose-agent-runtime-composition` → `main`, merge commit `e7e2a3b` |
| `main` after merge | local `main` == `e7e2a3b459ae63cb17943b439b7300176e12296b`, `python3 scripts/verify_all.py` → **exit 0** |
| Cleanup | merged branch deleted locally and on the remote after proving it was an ancestor of `main` |
| Active branch | `feat/zerolose-v2-vision-provider-contract` (based on merged `main`) |

Test-suite totals moved from **458** (before this session's migration) to **376**, because roughly
90 tests whose subjects were deleted went with them (`ResponseCacheServiceTests`,
`ActiveRoleProfileServiceTests`, `InterviewKnowledgeMatcherTests`,
`IntelligenceServiceQuerySplitTests`, and the vault/`AIModelNames`/`OllamaService` cases inside
`ZeroLoseTests.swift`). 0 failures, 0 skipped.

---

## Verification snapshot (2026-09-13, current branch)

- `xcodebuild -project ZeroLose/ZeroLose.xcodeproj -scheme ZeroLose -destination 'platform=macOS,arch=arm64' test`
  → **TEST SUCCEEDED**, 376 tests, 0 failures.
- `python3 scripts/verify_all.py` → **exit 0**: layout guard, legacy-demolition scan,
  provider-fabric token scan, provider-authority scan (now whole-tree), interview-demolition scan,
  ExamPilot 196 tests, ExamPilot release build, ExamPilot CLI smoke, ZeroLose Debug build, and the
  full ZeroLose test suite.
- `git diff --stat` for this branch: **35 files changed, 561 insertions(+), 9404 deletions(-)** —
  17 source files deleted (13 production, 4 legacy test files).

---

## Completed in this session

### ✅ Task 7/8 remainder — vision-capable V2 request, then the legacy closure deleted

The previous session correctly refused to delete `IntelligenceService` while the screenshot /
answer-refinement features still ran through it. This session removed that blocker instead of
working around it.

**Vision in the V2 provider contract** (verified against the official OpenAI Responses API
contract, which uses `input_text` + `input_image` content parts with a data-URL `image_url`):

- `ModelMessage` gained `images: [Data]` (explicit memberwise init keeps every existing
  `ModelMessage(role:content:)` call site valid; decoding tolerates a missing `images` key).
- `OpenAITransportInput` gained the same payload and `OpenAITransport.requestBody` now encodes a
  multimodal content-part array for user turns that carry images, while text-only turns keep the
  compact `content: String` shape. Image parts are emitted **only** for `.user` turns, the only role
  the Responses contract accepts them on.
- `OpenAIAPIProvider` advertises `.vision` and forwards the payload.
- `AskRequest` gained `imageData: Data?`; `RequestCoordinator` fails **closed** with
  `RequestCoordinatorError.visionUnsupported` before any persistence or provider call when the
  bound provider/model does not declare `.vision`.
- `RequestCoordinatorError` now conforms to `LocalizedError`, so the vision gate surfaces
  "The selected provider does not support image analysis. Choose a vision-capable provider in
  Settings." instead of a raw Swift error description.

**Shell runtime migration** (`V2ShellRuntimeController`):

- `processImage` (screen capture, image attachments, auto-screenshot) and the AI-refine path now
  stream through `RequestCoordinator` via a new shared `streamAsk(_:query:assistantIndex:assistantID:)`
  helper; `processAsk` uses the same helper, so chat, image analysis and refinement share one
  coordinator/cancellation/stop path. `processText` is gone.
- Image turns now participate in cancellation and Emergency/Stop bookkeeping
  (`activeAskSessionID` / `activeAskSelection`), which the legacy path did not.
- Removed the `IntelligenceService` dependency, its `clearHistory()` call and the
  `assistantOrigin(for:)` bridge from the controller.
- `WebSearchMode` moved to `V2/UI/ShellViewModel.swift` with the `ShellFeatureControlling`
  protocol. Note: the "Zorla Web Arama" (force web search) toggle was already inert on the chat
  path before this change — `processAsk` never consumed `webSearchMode` — so moving the type
  preserves existing behaviour rather than regressing it. See "Still open" for the real gap.

**Deleted (each proven to have no consumer outside the deletion set first):**

`Services/IntelligenceService.swift`, `Services/OllamaService.swift`,
`Services/ResponseCacheService.swift`, `Services/TextAnalysis.swift`,
`Services/LLMPromptBuilder.swift`, `Services/CodingSandboxService.swift`,
`Services/VaultService.swift`, `Services/VaultSearchEngine.swift`,
`Services/ActiveRoleProfileService.swift`, `Services/InterviewKnowledgeMatcher.swift`,
`Services/RAG/SemanticRetriever.swift`, `Models/InterviewItem.swift`, and — now that
`AIModelNames` had exactly one remaining consumer — `Resources/Constants.swift` (the whole legacy
`LLMProvider`/`AIModelNames` provider router).

`GroqService` (voice transcription, the documented compatibility-only exception) now pins its own
models: `gpt-4o-mini-transcribe` for the OpenAI endpoint and `whisper-large-v3-turbo` for Groq.
That removes the last `AIModelNames` consumer and is strictly more correct than the previous
router lookup.

`DependencyContainer` no longer owns `ollamaService`, `semanticRetriever` or `intelligenceService`
(and the V2 runtime container no longer clears legacy history).

### ✅ Task 8 — legacy provider authority is now fully retired (closure is empty)

`ProviderLegacyDemolitionTests` now pins the allowed legacy-authority closure to **`[]`** and the
`llm_provider` readers to exactly `V2/Migration/SettingsMigrationCoordinator.swift` (a migration-only
reader that never routes a request). `scripts/verify_all.py` was strengthened accordingly:

- `OBSOLETE_ZEROLOSE_LEGACY_PROVIDER_SOURCES` — every retired legacy source must stay deleted.
- `FORBIDDEN_ZEROLOSE_TREE_TOKENS` — a **whole-tree** scan (previously primary paths only) for
  `LLMProvider`, `AIModelNames`, `OllamaService` and every `custom*Model` key.
- `ALLOWED_ZEROLOSE_LEGACY_DEFAULT_READERS` — only the migration coordinator may read `llm_provider`.

### ✅ Guard updates that followed from the migration (not weakened)

- `AskModeBoundaryTests.testNormalAskPathContainsNoLegacyInterviewOrProviderSpecificOrchestration`
  now inspects both `processAsk` and the shared `streamAsk` body, so the forbidden-token scan
  covers the real ask path after the refactor (previously it only read `processAsk`).
- `LegacyDemolitionTests.testModelProviderDoesNotSelectToolsFromLegacyCapabilityRegistry` and
  `testIntelligenceServiceDoesNotInjectLegacyAutomationPrompt` became **absence guards**: the files
  they inspected are gone, so they now assert the files stay gone from disk.
- `LegacyDemolitionTests.testShellRuntimeInjectsV2NativeToolsIntoModelBoundary` was replaced. It
  only passed because the legacy image/refine path injected native tools into
  `IntelligenceService`; the V2 chat path never did. The replacement,
  `testShellRuntimeDelegatesModelTurnsToV2CoordinatorWithoutLegacyBridge`, asserts what is actually
  true and still worth protecting: the shell delegates model turns to `RequestCoordinator`, still
  binds `nativeToolRuntime.setAuthorityMode(`, and references no `IntelligenceService`,
  `OllamaService` or `AgentCapabilityRegistry`.

### ✅ Task 10 — merge, merged-`main` verification and branch cleanup

- PR #28 verified `CLEAN` with CI `SUCCESS` on the exact head before merging (merge commit
  `e7e2a3b`).
- Local `main` fast-forwarded to the merge SHA; `python3 scripts/verify_all.py` → exit 0 on merged
  `main`.
- `origin/feat/zerolose-agent-runtime-composition` was proven an ancestor of `main` with
  `git merge-base --is-ancestor` before deleting it locally and on the remote.

---

## Still open

### 🟠 Chat has no model-visible tools, so "Zorla Web Arama" is inert

This is **pre-existing on `main`**, not introduced here, and it is now the most valuable next
feature. `RequestCoordinator` is constructed in production without `readOnlyToolSchemas`, and it
only yields `.toolCall` events without executing them. Consequences:

- the `builtin.web_search` / `builtin.system_status` descriptors never reach a chat request;
- `forceWebSearch` (ContentView toggle) cannot influence an answer;
- `builtin.web_search` is currently reachable only from the agent path
  (`V2BuiltinToolCatalog.descriptors` → agent tool composition).

Closing this needs a bounded read-only tool-call loop in `RequestCoordinator`: pass the filtered
read-only schemas, execute approved calls through `ToolFabric` (scope-gated credentials already
exist), feed results back, and keep the fail-closed/per-invocation handle semantics. Do **not**
just forward schemas — a model that can request a tool nobody executes is worse than no tool.

### 🟡 Legacy credential *scope availability* in the V2 adapter

`V2/Credentials/KeychainCredentialBrokerAdapter.isCredentialPresent(for:)` still answers for
`deepseek.chat`, `opencode.zen`, `opencode.go`, `ollama.cloud` and `groq.chat` by reading the
matching `Secrets.is*KeyValid`. Only `tavily.search` (and the empty scope) is used by any shipped
tool today, so these branches are effectively dead. They are credential *presence* plumbing, not
model-routing authority, so they were deliberately left alone. Trimming them means a plugin
manifest that declares such a scope reports "unavailable" (fail-closed) — acceptable, but it is a
separate, evidence-backed change.

### 🟡 Dead `Secrets` accessors retained on purpose

`Secrets.ollamaApiKey`, `deepSeekApiKey`, `openCodeZenApiKey`, `openCodeGoApiKey`, `openAIApiKey`
(plus their validity flags) and `resetToDefaults()`/`clearAll()` have no production caller now.
They were **not** removed because they are storage plumbing for existing Keychain accounts and
touching them risks making previously stored keys look missing. `Secrets.groqApiKey`,
`tavilyApiKey`, `isGroqKeyValid`, `isTavilyKeyValid` and `isOpenAIKeyValid` (transcription provider
preference) are still live.

### 🟢 Low #12 — repo hygiene follow-up

`.freebuff/` (client state from the Freebuff agent host, not user work) is untracked. Confirm the
desired treatment (ignore file vs. leave untracked) at the next cleanup boundary.

### ✅ Stale remote branches — swept, with the proof kept

Every remote branch was classified with `git merge-base --is-ancestor origin/<branch> main`.
**22 branches proven to be ancestors of `main` were deleted** (`chore/repository-cleanup`,
`design/computer-agent-runtime-v2`, `feat/computer-agent-runtime-v2-slice1..7`,
`feat/runtime-diagnostics`, `feat/zerolose-v2-{computer-agent-core,foundation,persistence-replay,tool-fabric}`,
`fix/exampilot-cgs-bootstrap-{final,real,red,work}`, `fix/navigation-question-identity`,
`plan/computer-agent-runtime-v2-slice{2,3,4}`).

**6 branches were deliberately preserved** because they carry unique unmerged commits:
`feat/computer-agent-runtime-v2-slice8-browser-semantics` (+23),
`feat/exampilot-visual-agent` (+66), `feat/zerolose-context-request-pipeline` (+18),
`feat/zerolose-provider-fabric` (+9), `fix/exampilot-cgs-bootstrap` (+3),
`fix/localized-answer-verification` (+8). Re-run the same ancestor check before touching them.

---

## Suggested next order

1. Read-only tool loop in `RequestCoordinator` → makes `builtin.web_search` and the force-search
   toggle real in Chat (biggest user-visible gap on `main`).
2. Prove-and-trim the legacy credential scopes and dead `Secrets` accessors as one focused cleanup.
3. Merged-only sweep of stale remote branches, plus a `.freebuff/` ignore decision.
4. Re-run `python3 scripts/verify_all.py`, release build, install smoke.
