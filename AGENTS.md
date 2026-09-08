# Repository Engineering Contract

## Source of truth

Use the code, tests, `README.md`, and approved documents under `docs/superpowers/` as the repository source of truth. Do not rely on removed provider-adapter folders or generated agent-rule mirrors.

## Required workflow

- Inspect the relevant implementation and tests before changing behavior.
- Use TDD for runtime behavior changes: reproduce the failure, observe RED, implement the minimum correction, then run the full affected suite.
- Run `python3 scripts/verify_all.py` before declaring repository-wide completion.
- For OpenAI provider or Responses/Computer Use contract changes, verify the current official OpenAI documentation before editing request shapes or tool semantics.
- Keep changes focused. Do not mix unrelated refactors into correctness fixes.

## Runtime invariants

For code that can reach physical computer input:

- Model/provider output is untrusted intent, not executable authority.
- Runtime state and `ActionPolicy` decide whether an action is legal.
- Proposals must remain bound to the accepted observation/state version.
- Focus/window continuity must be checked before live input.
- Protected navigation must remain fail-closed until the runtime has verified the current answer/task state.
- UI transitions must stabilize before reasoning continues.
- Semantic success must come from verification evidence, not from arbitrary pixel change or model self-report.
- Repeated failures must change strategy or stop within a bounded retry budget. Never implement blind replay loops.
- Unknown provider/native action types must fail closed.
- Emergency stop/cancellation checks must remain effective inside long-running native input operations.

## Memory and telemetry

- Keep working memory bounded.
- Do not persist raw screenshots, API headers, secrets, credentials, private typed content, or complete provider payloads in telemetry or memory.
- Store structured evidence/failure categories and runtime coordinates only when they are necessary for recovery or diagnostics.

## Security

- Never hardcode credentials, API keys, private keys, tokens, or secrets.
- Avoid destructive filesystem/database/VCS operations without a targeted dry-run and explicit approval.
- Preserve least-privilege macOS permissions and application-scoped input assumptions.
- Do not add stealth/evasion, anti-proctoring, monitoring defeat, CAPTCHA bypass, or access-control circumvention features.

## Verification gates

Repository gate:

```bash
python3 scripts/verify_all.py
```

ExamPilot directly:

```bash
cd ExamPilot
swift test
swift build -c release
```

The repository gate also builds ZeroLose without code signing when Xcode is available.

## Repository hygiene

The repository intentionally does not use project-local `.agent`, `.codex`, `.claude`, or `.opencode` adapter trees. Do not reintroduce generated multi-provider rule/skill mirrors. Keep repository-specific engineering guidance in this file and product documentation in normal Markdown under `docs/` or the relevant package directory.
