# ZeroLose V2 Implementation Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver ZeroLose V2 through six independently reviewable implementation tracks without rewriting the working ExamPilot runtime or carrying legacy `[ACTION]` execution semantics into V2.

**Architecture:** The roadmap is a strangler migration. Each track establishes one authoritative boundary before the next track depends on it: foundation → providers → persistence/replay → ComputerAgentCore extraction → autonomous runtime → UI/migration/demolition. The old runtime stays operational until a V2 replacement has deterministic parity tests.

**Tech Stack:** Swift 5 language mode, Swift Concurrency, SwiftUI, XCTest, SQLite3, ScreenCaptureKit, Accessibility APIs, CoreGraphics/HID, macOS Keychain, optional MCP transports.

**Spec:** `docs/superpowers/specs/2026-09-09-zerolose-v2-design.md`

## Global Constraints

- Local checkout is the implementation source of truth when `@chatgpt-system-local` is available: `/Users/dogan/Desktop/akilli-asistan`.
- Preserve the pre-existing untracked `.freebuff/` directory and never stage or modify it.
- Baseline commit for this plan set: `471d025f7ed3477197e0b507aec748fee72a539f`.
- Trusted ZeroLose V2 runtime remains Swift-first; do not add Node/TypeScript to the trusted execution kernel.
- Keep ZeroLose in its current Swift 5 language mode during these tracks; Swift 6 language-mode migration is a separate verified change.
- SwiftUI-facing observable state is `@MainActor`; kernel/runtime mutable state uses explicit isolation and immutable `Sendable` snapshots across boundaries where practical.
- Do not use `@unchecked Sendable`, `nonisolated(unsafe)`, or `Task.detached` without a documented invariant and removal plan.
- Never hardcode, log, persist, or expose credentials, Authorization headers, raw API keys, or CredentialBroker handles.
- Never reintroduce `[ACTION: {...}]` as a V2 execution primitive.
- Every physical computer mutation in ZeroLose production must re-enter Tool Fabric and `PolicyKernel`.
- Runtime behavior changes use TDD: RED → minimal GREEN → focused verification → affected suite.
- Keep commits narrow; do not combine unrelated refactors.
- Before repository-wide completion run `python3 scripts/verify_all.py`.

---

## Track order

1. `docs/superpowers/plans/2026-09-09-zerolose-v2-foundation.md`
2. `docs/superpowers/plans/2026-09-09-zerolose-v2-tool-fabric.md`
3. `docs/superpowers/plans/2026-09-09-zerolose-v2-persistence-replay.md`
4. `docs/superpowers/plans/2026-09-09-zerolose-v2-computer-agent-core.md`
5. `docs/superpowers/plans/2026-09-09-zerolose-v2-autonomous-runtime.md`
6. `docs/superpowers/plans/2026-09-09-zerolose-v2-ui-migration-demolition.md`

## Cross-track release gates

- [ ] **Gate 1: Establish a clean feature branch before implementation**

Run:
```bash
git status --short --branch
git log -5 --oneline
```

Expected:
- the intended feature branch is active;
- `.freebuff/` is still the only known pre-existing untracked path unless later approved artifacts are present;
- HEAD ancestry includes `471d025f7ed3477197e0b507aec748fee72a539f`.

- [ ] **Gate 2: Run the current baseline before Track 1 code**

Run:
```bash
python3 scripts/verify_all.py
```

Expected: exit 0 and `[OK] repository verification completed successfully`.

- [ ] **Gate 3: Complete each track in order**

For every track:
1. execute only that track's plan;
2. observe RED before runtime behavior code;
3. commit every independently reviewable deliverable;
4. run that track's focused tests;
5. run the affected product suite;
6. inspect `git diff` before moving to the next track.

- [ ] **Gate 4: Never delete a legacy path before parity**

Before deleting any legacy executor, parser, registry, approval path, or `GhostViewModel` responsibility, require a deterministic V2 replacement test proving the same required user outcome through the new boundary.

- [ ] **Gate 5: Repository-wide verification after Track 6**

Run:
```bash
python3 scripts/verify_all.py
```

Expected: exit 0 and `[OK] repository verification completed successfully`.

- [ ] **Gate 6: Final architecture guard review**

Search:
```bash
git grep -n '\[ACTION:' -- ZeroLose ExamPilot
git grep -n 'actionRegex\|handleActions' -- ZeroLose
git grep -n 'InputDriving' -- ZeroLose/ZeroLose
```

Expected:
- no V2 execution path uses `[ACTION:`;
- deleted legacy symbols are absent after demolition;
- ZeroLose production does not directly call ExamPilot's raw native input driver outside the approved Tool Fabric-backed computer provider boundary.
