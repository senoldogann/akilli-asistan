# Contributing

## Development setup

The primary computer-use runtime is the Swift Package under `ExamPilot/`.

Requirements:

- macOS 14+
- Swift 5.10+
- Xcode for the `ZeroLose` application build

## Verification

All implementation, tests, builds, and release verification are performed locally first. Run the repository gate before opening a pull request:

```bash
python3 scripts/verify_all.py
```

For focused ExamPilot development:

```bash
cd ExamPilot
swift test
swift build -c release
```

## Pull request rules

- Keep changes focused and reviewable.
- Do not use a pull request as a remote development/test loop. Finish the scoped implementation and required verification locally first.
- Once local gates are green, push the focused feature branch, open a pull request, verify the exact PR head, and merge through the pull request rather than committing directly to `main`.
- Add a regression test before fixing runtime behavior.
- Do not weaken `ActionPolicy`, stale-state checks, focus continuity, semantic verification, recovery budgets, or emergency-stop behavior to make a test pass.
- Treat provider/model output as untrusted input.
- Do not introduce hardcoded secrets, credentials, private keys, or tokens.
- Update architecture documentation when a change modifies component authority or data flow.
- Use current official OpenAI documentation before changing Responses API or Computer Use request contracts.

## Swift conventions

- Prefer explicit types at runtime boundaries.
- Use structured concurrency and propagate cancellation.
- Keep UI-only state on the appropriate actor.
- Avoid force unwraps outside tightly controlled test fixtures.
- Bound retries, waits, action counts, and memory growth.
- Return structured errors instead of silently recovering from malformed provider output.

## Repository hygiene

Project-local `.agent`, `.codex`, `.claude`, and `.opencode` adapter trees are not part of the repository architecture. Do not regenerate or commit them.

- Keep working trees clean and remove accidental temporary/generated files before handoff or merge.
- After a pull request is merged and verified, prune merged/unused feature branches and obsolete worktrees only after confirming they contain no unique unmerged commits or user work.
- Retain a branch or worktree only when it is still active, intentionally preserved, or needed for recovery.
