# ZeroLose V2 UI Control Plane and Interview Removal Design

Date: 2026-09-13
Status: Design approved in chat; implementation pending written-spec approval
Base: `feat/zerolose-agent-runtime-composition` at `e95473db4acfad2e006e700607320322c2d43c20`
Active development root: `/Users/dogan/Desktop/akilli-asistan`

## 1. Purpose

The V2 backend is now substantially ahead of the visible ZeroLose product surface. The application already has a provider-neutral `ModelProviderFabric`, a `RequestCoordinator`, persistent Agent runtime, Tool Fabric, policy gates, production semantic task/goal verification, runtime-owned computer freshness, and verified computer mutation composition. The main window and Settings UI still expose a different, legacy model of the product.

Today the visible UI still reads `LLMProvider`, `AIModelNames`, `llm_provider`, and provider-specific `custom*Model` preferences. Settings still presents legacy credential/model cards whose options do not correspond one-to-one with providers registered in `ModelProviderFabric`. Interview Vault, Mock Interview, active interview role/CV/JD flows, interview notes, and Teleprompter also remain visible or reachable even though the product direction is now a general Chat/Agent macOS assistant.

This design completes the cutover. It makes the V2 provider/model runtime the single authority for both UI and execution, redesigns the user-facing surfaces around Chat and Agent, and removes interview-specific product/runtime behavior rather than merely hiding it.

## 2. Goals

1. Make one V2 provider/model control plane authoritative for the main UI, Settings, Chat requests, and Agent planning.
2. Preserve the existing floating/stealth macOS window behavior while replacing the information architecture inside it.
3. Show only providers and models that are represented by real V2 backend adapters.
4. Make provider availability, capabilities, model discovery, and configuration state come from backend contracts instead of UI guesses.
5. Ensure Chat and Agent use the same selected provider/model snapshot.
6. Remove interview-specific product surfaces and runtime entry points.
7. Preserve general-purpose file/context, memory, voice, screenshot analysis, tools, web search, approvals, and Agent functionality.
8. Keep credentials and obsolete user data non-destructive during the migration.
9. Finish with deterministic tests, full repository verification, a Release build, local installation, code-sign verification, and a real launch smoke test.

## 3. Non-Goals

- Rewriting the floating overlay into a conventional Dock-first macOS application.
- Replacing the already-working Tool Fabric, Policy Kernel, persistence, semantic verification, or ComputerAgent composition.
- Adding new model providers only to preserve legacy UI choices.
- Keeping a permanent compatibility bridge from `LLMProvider`/`AIModelNames` to V2.
- Automatically deleting old Keychain entries, interview databases, notes, exports, or other user-owned data.
- Treating Tavily, Groq, or other integrations as model providers unless they implement the V2 `ModelProvider` contract.
- Building a new cloud account system.

## 4. Product Surface

ZeroLose has two primary modes:

- **Chat** — conversational requests, attachments/context, read-oriented tools, web search, screenshot analysis, and voice input/output where configured.
- **Agent** — persistent goal/task execution through the existing V2 autonomous runtime, Tool Fabric, policy gates, observation, and semantic verification.

The main floating window remains the primary workspace. Settings remains a separate macOS window. The product no longer exposes interview-specific navigation or dedicated interview utilities.

## 5. Authoritative Provider/Model Architecture

### 5.1 Existing execution authority

`ModelProviderFabric` remains the execution authority. It already owns registered providers and the selected provider used for streaming. `RequestCoordinator` and Agent planning already depend on it.

The production provider set at the design base is:

- `CodexCLIProvider`
- `ClaudeCLIProvider`
- `OpenCodeCLIProvider`
- `AntigravityCLIProvider`
- `OpenAIAPIProvider`

The UI must not invent additional model providers from old settings. A legacy credential can remain stored without being exposed as a model provider.

### 5.2 New Provider Control Plane

Add one provider/model control-plane component between `ModelProviderFabric` and presentation state. The exact type name may be `ProviderControlPlane` unless implementation reveals a clearer existing boundary.

Its responsibilities are:

- enumerate registered provider presentation state;
- query each provider's `ProviderStatus`;
- expose provider capabilities;
- discover model descriptors through `ModelProviderFabric`;
- own the active provider ID and active model ID used for subsequent requests;
- persist those non-secret selections in the `v2.*` namespace;
- apply provider selection to `ModelProviderFabric`;
- provide immutable request-selection snapshots so in-flight work cannot silently switch provider/model mid-request;
- expose a capability decision for whether Agent planning is currently supported;
- normalize safe presentation errors for refresh/discovery/configuration failure.

The control plane does **not** execute model requests itself and does not own Tool Fabric or Agent policy.

### 5.3 Presentation snapshot

Presentation should be driven by one bounded snapshot rather than direct reads from UserDefaults or `Secrets` throughout SwiftUI views. A representative domain shape is:

```swift
struct ProviderControlSnapshot: Sendable, Equatable {
    let providers: [ProviderPresentation]
    let selectedProviderID: ModelProviderID
    let selectedModelID: String
    let selectionRevision: UInt64
}

struct ProviderPresentation: Identifiable, Sendable, Equatable {
    let id: ModelProviderID
    let displayName: String
    let availability: ProviderAvailability
    let capabilities: ModelCapabilities
    let models: [ModelDescriptor]
    let modelDiscoveryState: ModelDiscoveryState
}
```

The implementation may refine names, but the ownership and data flow are fixed.

### 5.4 Selection semantics

Provider selection is authoritative and has no silent fallback.

When the user selects a provider:

1. Validate that it is a registered provider ID.
2. Persist `v2.modelProviderID`.
3. Apply the selection to `ModelProviderFabric`.
4. Resolve that provider's model selection. If no valid model selection exists, use `default` when the adapter supports a provider-defined default behavior.
5. Publish one updated provider snapshot.

When the user selects a model:

1. The model must either be a descriptor discovered for the active provider or the explicit provider-defined `default` selection.
2. Persist the value under V2-owned model preference state.
3. Publish an updated snapshot.

An active request captures its provider/model selection at request creation. Changing the UI while a request is streaming affects only subsequent requests. Cancellation remains explicit through the existing request/session cancellation path.

### 5.5 Persistence migration

The new UI/runtime reads only V2-owned provider/model keys.

- Keep a valid existing `v2.modelProviderID`.
- If the stored provider is absent or no longer registered, deterministically select `codex` when it is registered; otherwise select the first deterministic registered provider and surface its real availability.
- Keep `v2.modelDefaultID` only when it is valid for the selected provider or represents the supported `default` behavior.
- Provider change resets an incompatible model selection to `default`.
- Stop reading `llm_provider` and provider-specific `custom*Model` values from the authoritative UI/request path.
- Legacy preferences may remain on disk for rollback but are inert.

## 6. Provider Availability and Capabilities

The UI reflects backend state, not optimistic assumptions.

The existing availability vocabulary remains authoritative:

- `ready`
- `detected`
- `notInstalled`
- `loginRequired`
- `configurationRequired`
- `unavailable`
- `unsupportedVersion`

A provider that is not usable for the requested operation blocks that operation and displays the actual reason. The UI never silently routes to another provider because another credential happens to be present.

Model discovery is also explicit. If discovery returns no models, the UI must not substitute an unrelated hard-coded catalog. If the adapter supports its own `default` model behavior, `Default` may be presented as that explicit behavior. Otherwise model selection remains unavailable until discovery/configuration succeeds.

Capability controls are derived from provider/model declarations. In particular, Agent planning is disabled unless the selected provider/model can satisfy the structured planning contract required by the current runtime. At the current base, `.jsonOutput` is the minimum planning capability gate already used by Agent composition. The UI must explain the disabled state instead of allowing a request that is guaranteed to fail later.

## 7. V2 Provider View Model

Add a presentation model dedicated to provider/model state, for example `ProviderViewModel`.

It may expose:

- current `ProviderControlSnapshot`;
- `refresh()`;
- `selectProvider(_:)`;
- `selectModel(_:)`;
- provider availability/status text;
- selected capability summary;
- `canUseChat` and `canUseAgent` decisions;
- safe current error state.

SwiftUI views do not call `UserDefaults`, `Secrets`, CLI locators, or provider transports directly for provider/model state.

The same `ProviderViewModel` instance is injected into the main `ContentView` and Settings so both surfaces display and mutate the same control-plane state.

## 8. Request and Agent Integration

### 8.1 Chat

Normal V2 Chat requests use the control plane's immutable current selection when the request is created. `V2ShellRuntimeController` must stop reconstructing provider/model display or context-window behavior from `AIModelNames.currentProvider()`.

The request path remains:

```text
UI
 -> typed application/runtime command
 -> RequestCoordinator
 -> ContextOrchestrator
 -> ModelProviderFabric
 -> selected real provider
```

Legacy `OllamaService` routing may remain temporarily for general features that have not yet moved, but it must not decide the provider/model used by the primary Chat or Agent V2 request path.

### 8.2 Agent

Agent uses the same provider/model selection authority as Chat. Agent planning receives the selected model captured for that run, not a separately read UserDefaults value.

Before starting a goal, UI/backend capability validation must fail closed when structured planning is unavailable. Once an Agent run starts, later provider/model UI changes do not mutate that run's planning identity unless an explicit future run-reconfiguration feature is designed.

### 8.3 Status display

`ShellProjectionSnapshot.currentModelDisplay` must be derived from the V2 provider selection snapshot or removed in favor of direct `ProviderViewModel` presentation. It must not be rebuilt from legacy provider helpers.

## 9. Main Floating Window Design

The current custom `GhostWindow`, screen-sharing policy, opacity behavior, positioning, hotkey, and floating level remain unless a test proves one must change for the new UI.

The content becomes one compact desktop workspace.

### 9.1 Header

The header contains:

- active provider selector;
- active model selector;
- `Chat / Agent` mode selector;
- concise runtime/provider status;
- Settings entry point.

Removed from the header:

- Interview Notes / Teleprompter;
- Interview Prep Vault;
- AI Mock Interview;
- any interview-role action;
- duplicate legacy model/provider selectors.

### 9.2 Conversation/task surface

One central conversation surface remains. Chat responses and user messages continue to render there.

In Agent mode, a compact runtime strip is presented with only actionable state:

- lifecycle/status;
- current task summary when available;
- Pause when supported;
- Resume when supported;
- Cancel when supported;
- Emergency Stop when mutation execution is active or the existing runtime contract requires it to remain immediately available.

Detailed event/debug data remains secondary UI under Settings → Runtime rather than dominating the main conversation.

### 9.3 Composer

The composer keeps general-purpose controls:

- text input;
- file attachment;
- web/tool preference where currently supported;
- voice input/output controls where configured;
- send/stop;
- authority indicator where useful.

The composer does not contain a second provider/model hierarchy. Provider/model selection exists once in the header and is shared with Settings.

### 9.4 General features preserved

The redesign preserves, subject to existing permissions and backend readiness:

- attachments and file context;
- conversation context;
- memory/context retrieval;
- screenshot analysis;
- voice/listening/transcription;
- web search;
- Tool Fabric tools;
- approvals;
- Agent task controls.

Preserving a feature does not require preserving a legacy provider-routing implementation. A preserved feature should be routed through its appropriate current backend boundary.

## 10. Settings Information Architecture

Settings remains a separate window and uses desktop-appropriate SwiftUI sections/navigation. It is reorganized around real runtime domains.

### 10.1 Providers

Show only registered V2 model providers:

- Codex
- Claude
- OpenCode
- Antigravity
- OpenAI API

Each provider row/card displays:

- display name;
- real availability;
- declared capabilities;
- discovered/default model state;
- refresh action;
- configuration guidance when required.

OpenAI API configuration is the model-provider credential surface that is currently part of V2. Its secret remains in Keychain and is never echoed back as plaintext after save.

### 10.2 Tools

Contains tool/integration controls that are not model-provider selection:

- Tool Fabric enable/disable state;
- web search/Tavily configuration;
- MCP server/tool state;
- computer-tool readiness and permission status where useful.

Tavily is not displayed as a model provider.

### 10.3 Runtime

Contains:

- authority mode;
- Agent lifecycle/detail;
- approvals;
- bounded runtime/event diagnostics;
- task controls when a real active session supports them.

No control is enabled unless it has a real production command target.

### 10.4 Memory

Contains general memory/index state and user-visible clear/inspect actions. Interview-specific notes/vault concepts are not part of the memory UI.

### 10.5 Voice

Contains voice/transcription integration configuration. Groq may remain here if it is still a real voice/transcription backend; that does not make Groq a V2 model provider.

### 10.6 Appearance

Contains general display preferences such as window dimensions, opacity, typography/theme, and related non-runtime presentation settings.

### 10.7 Privacy

Contains:

- screen-capture permission state;
- Accessibility/computer-control permission state;
- stealth/window-sharing behavior;
- credential-storage explanation;
- local data/privacy controls appropriate to existing implementation.

Permission copy must describe general screenshot/computer/voice functionality and must not mention interviews.

## 11. Interview Product Removal

The user explicitly requested removal of the interview product, not a hidden compatibility mode.

### 11.1 Remove UI surfaces

Remove production reachability and target membership where no longer needed for:

- `InterviewVaultView`;
- `MockInterviewView`;
- `TeleprompterView`;
- interview Cheat Sheet UI;
- active interview role UI;
- CV/JD interview-role settings;
- interview notes settings;
- interview-specific header buttons and sheets;
- teleprompter window lifecycle in `WindowManager`.

### 11.2 Remove runtime entry points

Remove interview-specific runtime contracts such as `warmUpInterviewContext()` from `ShellFeatureControlling`, `ShellViewModel`, and `V2ShellRuntimeController`.

Remove or neutralize interview-only request behavior so normal Chat/Agent requests no longer depend on:

- interview vault retrieval;
- interview-note cache priming;
- interview role grounding;
- interview-specific response profiles;
- interview fast paths;
- interview-specific prompt instructions.

### 11.3 Shared helper extraction rule

Some legacy files use interview-named helpers for text normalization, language detection, or keyword handling that may also support general features. Those behaviors must not be deleted blindly.

When a generally useful algorithm is still required:

1. characterize it with a general-purpose test;
2. extract it behind a neutral type/name;
3. migrate remaining general callers;
4. then remove the interview type/file.

The final production request path must not retain interview semantics merely because a utility was historically located in an interview subsystem.

### 11.4 Data retention

Existing interview data files, exports, defaults, or Keychain values are not automatically deleted. The new runtime stops loading them. Destructive user-data cleanup requires a separate explicit action/approval.

## 12. Legacy Provider UI Removal

The authoritative production UI/request path must stop using:

- `LLMProvider` for V2 provider selection;
- `AIModelNames` for V2 provider/model selection or display;
- `llm_provider`;
- `customOpenAIReasoningModel` and other provider-specific `custom*Model` selection keys;
- cached legacy provider model lists as authority;
- credential validity as an implicit provider fallback mechanism.

`AIModelNames` or legacy service code may survive temporarily only if a preserved non-primary feature still requires it during migration. Such surviving use must not influence main Chat/Agent provider selection and must have an explicit removal/migration task in the implementation plan.

The acceptance gate scans the production UI/V2 request path for forbidden legacy authority symbols.

## 13. Credential and Integration Boundaries

Credentials remain scoped to the subsystem that actually consumes them.

- OpenAI API key: V2 provider credential, Keychain-backed.
- Tavily key: Tools/Web Search integration.
- Groq key: Voice/transcription integration if still used.
- Legacy DeepSeek/Ollama/OpenCode Zen/OpenCode Go keys: not shown as active V2 model-provider accounts unless corresponding real V2 providers are added in a separately designed feature.

No migration step deletes obsolete credentials automatically. The new UI simply stops presenting unsupported credentials as active model-provider configuration.

## 14. Error and Failure Behavior

The cutover is fail-closed.

### 14.1 Provider/model selection errors

- Unknown persisted provider -> deterministic registered fallback and visible real status.
- Selected provider `notInstalled` -> block request and show installation state.
- `loginRequired` -> block request and show login requirement.
- `configurationRequired` -> block request and show configuration requirement.
- `unsupportedVersion` or `unavailable` -> block request and show safe reason.
- model discovery failure -> no invented catalog; preserve provider-defined `default` only when valid.
- selected model disappears -> reset to safe `default` or require selection.

### 14.2 Agent capability errors

If the selected provider/model cannot satisfy structured planning, Agent start is disabled/rejected before task execution. The UI explains the missing capability.

### 14.3 Active request selection changes

A provider/model change does not reroute an in-flight request. The active request completes or is explicitly cancelled using its captured selection. The next request uses the newly selected state.

### 14.4 Secret handling

Provider errors, UI snapshots, logs, event persistence, and diagnostics never contain raw credential values.

## 15. State Ownership

State ownership must remain narrow and explicit:

- `ModelProviderFabric` — registered providers and actual streaming selection.
- `ProviderControlPlane` — authoritative non-secret provider/model configuration and presentation snapshot.
- `ProviderViewModel` — MainActor observable UI projection and commands.
- `RequestCoordinator` / Agent runtime — consume immutable selection for work.
- `SettingsViewModel` — non-provider settings domains, or a reduced composition of domain-specific settings controllers after refactor.
- SwiftUI views — local presentation state only; no provider routing logic.

Provider status/model discovery must not be independently reimplemented in `ContentView` and `SettingsView`.

## 16. Migration Strategy

The migration is ordered to avoid a half-wired UI:

1. Introduce control-plane contracts and tests while existing UI still renders.
2. Bind Chat/Agent request creation to immutable V2 selection.
3. Add `ProviderViewModel` and backend-driven provider/model presentation.
4. Cut the main window over to the new provider/model state.
5. Cut Settings over to the new domain sections.
6. Remove interview UI/runtime entry points and extract any generally useful helpers.
7. Remove legacy provider/model authority from production UI/request paths.
8. Run forbidden-symbol and preserved-feature regressions.
9. Build/install/smoke the final app.

At no step may the legacy UI selection silently override or conflict with the V2 selection.

## 17. Testing Strategy

Behavior changes follow RED -> minimal GREEN -> focused regression -> broader verification.

### 17.1 Provider control-plane tests

Cover:

- deterministic initial selection;
- valid persisted V2 selection restore;
- invalid persisted provider fallback;
- provider selection updates `ModelProviderFabric`;
- provider change resets incompatible model;
- model selection validation;
- provider status refresh;
- model discovery success/empty/failure;
- no silent fallback;
- immutable in-flight selection snapshot;
- no secret values in presentation state.

### 17.2 View-model tests

Cover:

- `ProviderViewModel` snapshot refresh;
- provider/model selection commands;
- `canUseChat` and `canUseAgent` capability gating;
- safe status/error presentation;
- one shared view-model state reflected by main UI and Settings composition.

### 17.3 Request integration tests

Cover:

- selected provider actually receives Chat request;
- selected model is passed to the provider;
- UI selection change affects next request only;
- unavailable provider prevents request dispatch;
- Chat and Agent read the same selection authority;
- Agent rejects provider/model without required planning capability.

### 17.4 UI/source boundary tests

Cover or scan for:

- no authoritative `llm_provider` reads in main/Settings/V2 request path;
- no authoritative `AIModelNames`/`LLMProvider` routing in those paths;
- no duplicate provider/model selector in the composer;
- main UI exposes approved Chat/Agent controls;
- Settings contains approved domain sections;
- provider status is backend-derived;
- disabled Agent state has an explanation.

### 17.5 Interview removal tests

Verify production source/target has no reachable:

- Interview Vault UI;
- Mock Interview UI/service;
- Teleprompter UI/window lifecycle;
- interview warm-up command;
- interview role/CV-JD UI;
- interview-specific request grounding in the normal V2 path.

Any neutral helper extracted from interview code gets its own general-purpose characterization test before old code is removed.

### 17.6 Preserved feature regressions

At minimum verify preserved behavior for:

- attachment/file context;
- conversation submission/streaming;
- memory controls;
- screenshot analysis entry point;
- voice/listening entry point;
- web/Tavily tool path;
- Tool Fabric enable/disable state;
- approvals;
- Agent pause/resume/cancel/emergency stop;
- production semantic task/goal verification.

### 17.7 Release gates

Before claiming completion:

1. focused V2 provider/control-plane/UI/interview-removal tests;
2. affected existing ZeroLose test suites;
3. fresh Agent semantic-verification regression matrix;
4. ExamPilot full suite;
5. `git diff --check`;
6. production forbidden-symbol scans;
7. `python3 scripts/verify_all.py`;
8. Release ZeroLose build;
9. local code-sign verification;
10. install exact built bundle to `/Applications/ZeroLose.app`;
11. verify installed bundle identity/hash;
12. launch/relaunch smoke test with process survival and window creation.

Push/merge is not part of this implementation unless the user separately requests it.

## 18. Acceptance Criteria

The UI/backend cutover is complete only when all of the following are true:

- `/Users/dogan/Desktop/akilli-asistan` is the active development root.
- Main UI and Settings read one shared V2 provider/model state.
- Selecting a provider changes actual `ModelProviderFabric` routing.
- Selecting a model changes the model used for subsequent requests.
- No silent provider fallback occurs.
- Unavailable/misconfigured providers block dispatch with a clear state.
- No fake hard-coded model catalog substitutes for failed discovery.
- Chat and Agent use the same selection authority.
- Agent capability gating occurs before execution.
- Main Chat/Agent UI no longer uses legacy `LLMProvider`, `AIModelNames`, `llm_provider`, or provider-specific `custom*Model` values as authority.
- Settings shows only real V2 model providers under Providers.
- Tavily is presented as a tool/web integration, not a model provider.
- Groq is presented only under Voice/transcription when used there.
- Interview Vault, Mock Interview, Teleprompter, active interview role, CV/JD interview workflow, interview notes UI, and interview warm-up are removed from the product/runtime.
- General file/context, memory, voice, screenshot, tools, web, approvals, and Agent controls still work.
- Existing obsolete credentials/data are not destructively deleted by migration.
- Full repository verification passes on the final committed HEAD.
- The final Release app is built, signed for local installation, installed, and survives a real launch smoke test.

## 19. Engineering Constraints

- Develop only in `/Users/dogan/Desktop/akilli-asistan` for this project.
- Do not push or merge unless explicitly requested by the user.
- Preserve the V2 Tool Fabric, policy, observation, and semantic-verification boundaries already established.
- Do not reintroduce direct model-to-mouse/keyboard/browser mutation.
- Do not store credentials in UserDefaults, logs, runtime events, provider snapshots, or memory.
- Avoid a new monolithic Settings or provider service; split domain-specific views/controllers by responsibility.
- Keep SwiftUI state presentation-only; backend state belongs in control-plane/runtime types.
- Do not delete user-owned legacy data as part of code cleanup.
- Legacy deletion happens only after the new path is covered by deterministic tests.

## 20. Final Product Definition

After this cutover, the visible ZeroLose application matches the backend that actually executes requests. The user chooses one real provider and model, sees its real status and capabilities, and uses that same selection for Chat and Agent. The main floating window remains compact and stoppable; Settings reflects runtime domains rather than legacy provider heuristics.

ZeroLose no longer presents itself as an interview assistant. Interview Vault, mock interview, teleprompter, role/CV/JD flows, and interview-specific orchestration are absent from normal operation. The remaining product is a general-purpose V2 Chat/Agent macOS assistant whose UI, provider routing, safety boundaries, and verification semantics describe the same system.
