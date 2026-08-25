# Agent Handoff Notes — ZeroLose / Maestro

> **To the active agent working on this repo (Codex / Claude / OpenCode / Antigravity):**
> These notes were written by an external reviewer (Hermes Agent) on 2026-08-25 after a full
> audit: source review + real `xcodebuild` run + live test run. Read this before making changes.

---

## ✅ Verified Current State (2026-08-25)

- `xcodebuild build` (Debug): **SUCCEEDED**
- Test suite: **was broken, now FIXED** — `ZeroLoseTests.swift:405-407` called
  `MessageContent(text:isUser:)` but the init gained a required `thinking:` parameter.
  Added `thinking: nil` to the three calls. **Re-run tests before continuing.**
- `python3 scripts/verify_all.py`: **SUCCESS** (provider config, structure, deps, build)
- `scan_results.json`: regenerated OK
- The `ComputerUseService` (AX-first) + `AgentCapabilityRegistry` (23 tools) work is
  **genuinely strong**: AXObserver invalidation, `passRetained` use-after-free guard,
  3-tier click fallback (CGEvent → AXPress → AXClick), Retina 2× OCR point conversion,
  post-action diff verification. Keep this direction.

---

## 🔴 Priority Fixes (do these next)

1. **Swift 6 language mode is not clean.** Current build shows warnings that become
   **errors** in Swift 6 mode:
   - `ComputerUseService.swift:751-760` — `ComputerUseElement` is `@MainActor`-isolated
     but conforms to `Equatable` used from `nonisolated` context (`diff(...)`,
     `elementLines(...)`, OCR comparison). Fix: make the model types `Sendable` +
     `Equatable` without MainActor isolation, or mark the conformance
     `nonisolated` / move comparison off MainActor.
   - `SettingsView.swift:1024` — deprecated `onChange(of:perform:)` → use two/zero-param
     closure version.
   - Project claims "Swift 6.0" in `ZeroLose/AGENTS.md` but compiles in Swift 5 mode.
     Either migrate properly (see Apple's "Adopting strict concurrency" doc) or fix the
     claim. Recommendation: enable `SWIFT_STRICT_CONCURRENCY=complete` first, burn down
     warnings, then flip language mode — don't `@unchecked Sendable` your way out.

2. **Structured tool calling instead of `[ACTION: {...}]` + regex.**
   The current pipeline (model emits JSON inside brackets → `NSRegularExpression` parse →
   `JSONSerialization`) is fragile: escape bugs, partial tags, hallucinated JSON. DeepSeek
   (the configured provider) supports native **function calling / JSON Schema**. Migrate
   the 23 `AgentCapability` entries to schema-driven tool calls. The capability registry is
   already the single source of truth — emit the schema from it.

3. **Move action execution out of the UI layer.**
   `GhostViewModel.swift` (2940 lines) hosts the entire `handleActions` switch. Extract a
   dedicated `AgentActionExecutor` service (protocol + implementation) that the ViewModel
   calls. This is the biggest maintainability debt in the app right now.

4. **Break the god classes (in priority order):**
   - `IntelligenceService.process(...)` is **773 lines** (file: 2584 lines, 83 funcs).
     Split into pipeline stages: normalize → decide (search? cache? vault? direct?) →
     ground → generate → enforce-contract → post-process.
   - `GhostViewModel` 2940 lines → split into focused extensions/view-models per feature
     (chat, computer-use, tools, vault, mock-interview).
   - `OllamaService` 1165 lines.

---

## 🚀 For "Top-Tier Autonomy" (Hermes-level)

ZeroLose is already strong at **computer use**. To reach full agent autonomy:

1. **Persistent memory** — cross-session facts about the user (preferences, learned
   context). Currently only in-session conversation history exists. A simple
   key-value/vector store per user (you already have `VectorStore` + embeddings!) would
   give the agent durable memory for free.
2. **Task planning / todo queue** — multi-step tasks need a plan object, progress
   tracking, and status reporting back to the user. `docs/PLAN.md` is an empty template —
   either fill it per task or implement a runtime plan structure.
3. **Self-correction at the task level** — computer use has diff-verification, but the
   general loop has no "if this approach failed twice, change strategy" mechanism. Add a
   bounded retry + strategy-switch policy.
4. **Sub-agent delegation** — for long tasks, spawn focused sub-tasks (web research,
   file audit, test run) and merge results.
5. **Scheduled tasks** — beyond recurring AppleScript; a real cron/timer surface.
6. **Context/token budget management** — `trimConversationHistory` exists but there's no
   summarization tier; summarize old turns instead of dropping them.

## ✅ Already Correct (don't regress)

- Approval separation: read-only tools free / mutations require approval (`allowMutations`)
- `AgentCapabilityRegistry` as single source of truth injected into the system prompt
- Background-safe input: `CGEventPostToPid` — no focus stealing, no real cursor movement
- SafetyGuard blacklist + Keychain secrets + allowlist shell commands
- Maestro multi-provider sync (`scripts/sync_agents.py` + `scripts/verify_all.py`)

## 📚 Research References (verified 2026-08-25)

- **Tactile: Giving Computer-Using Agents Hands and Feet** (arXiv 2607.14443) — academic
  validation of exactly this architecture: accessibility-first operating ladder
  (AX semantics → OCR-grounded coordinates → visual fallback), normalized coordinate
  contract (screen points, not mixed retina pixels), verifiability/auditability as
  first-class runtime properties. ZeroLose's ComputerUseService already matches most of
  this — read it for the remaining gaps (e.g. MCP-style tool surface, audit logs).
- **Apple: "Adopting strict concurrency in Swift 6 apps"** — migration path for the
  warnings above: strict concurrency `complete` → fix warnings → flip language mode.
- **Apple Xcode 27 Agent Skill / SwiftUI best practices** — worth adopting as a shared
  skill for UI work (`ForEach` identity, `Equatable` short-circuit, etc.).

## ⚠️ Environment Note

- The machine is heavily loaded: Codex Router `ModelRouterTray` was at **~96% CPU**
  (538+ min CPU time) during this audit; builds were killed once by the scheduler.
  Consider pausing long-running router processes during heavy `xcodebuild` runs.
