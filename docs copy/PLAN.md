# Active Plan

## Goal
- [ ] Define the current task in one sentence.

## Constraints
- [ ] Stay within `Antigravity`, `Codex`, `Claude Code`, and `OpenCode` only.
- [ ] Keep shared policy in `AGENTS.md` and `.agent/`.
- [ ] Do not introduce undocumented provider keys or unofficial adapter layouts.

## Tasks
- [ ] Identify the files that must change.
  Verify: affected files are listed before editing.
- [ ] Update the shared source-of-truth files first.
  Verify: shared policy/config is correct in `AGENTS.md`, `.agent/`, or `scripts/sync_agents.py`.
- [ ] Regenerate provider adapters if needed.
  Verify: `python3 scripts/sync_agents.py` exits successfully.
- [ ] Review provider-specific outputs.
  Verify: `.codex/config.toml`, `.claude/settings.json`, `opencode.json`, and symlinked directories match the intended change.
- [ ] Run full verification.
  Verify: `python3 scripts/verify_all.py` exits successfully.

## Done When
- [ ] The requested change is implemented.
- [ ] `python3 scripts/sync_agents.py` passes.
- [ ] `python3 scripts/verify_all.py` passes.
- [ ] No unsupported provider adapter was added back.

## Notes
- Replace this file in place for each active task instead of creating parallel plan files.
- Keep the plan short and update checkboxes as work progresses.
