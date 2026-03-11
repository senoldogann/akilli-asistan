# Maestro Agent Rules

## Supported Providers
- `Antigravity`: read `AGENTS.md` -> `.agent/SYSTEM.md` -> `.agent/rules/GEMINI.md`
- `Codex`: read `AGENTS.md` and `.codex/config.toml`
- `Claude Code`: read `CLAUDE.md` (symlink to `AGENTS.md`), `.claude/settings.json`, and project assets under `.claude/`
- `OpenCode`: read `AGENTS.md`, `opencode.json`, and `.opencode/commands/`

## Source Of Truth
- Shared policy lives in `AGENTS.md` and `.agent/SYSTEM.md`
- Antigravity rule modules live in `.agent/rules/*.md`
- Provider adapters must stay thin and must not fork policy text

## Repo Contract
- Maintain only `Antigravity`, `Codex`, `Claude Code`, and `OpenCode`
- Remove adapters for unsupported providers instead of keeping stale compatibility shims
- Prefer documented provider entry points over custom compatibility layers

## Required Workflow
- Research current official docs before changing provider config
- Do not guess config keys, file locations, or command directories
- If a required skill or capability is missing, run `scripts/skill.sh ensure "<skill-or-query>"`
- Run `python3 scripts/sync_agents.py` after any rule or adapter change
- Run `python3 scripts/verify_all.py` before declaring the work complete

## Research Escalation
- If a fact may be stale, use live web search or current primary-source docs before answering
- If the task asks for the best, latest, current, recommended, or official solution, verify it first
- Prefer official docs, release notes, changelogs, standards, and security advisories over memory
- If research is unavailable, state the limitation explicitly instead of presenting memory as confirmed fact

## Anti-Loop
- Do not repeat the same failing command, search, or reasoning path without a changed hypothesis
- After two non-progressing attempts, stop and change strategy: inspect evidence, search current docs, or ask the user for the missing fact
- Treat web search and current documentation as the default escape hatch when uncertainty or drift appears

## Skill Resolution
- Search shared repo skills first, then user-level Codex skills, then remote skill ecosystems
- Prefer shared repo installation when the skill should benefit Antigravity, Claude Code, and OpenCode together
- Use `scripts/skill.sh install <github-url>` for explicit repo-backed skills
- `scripts/skill.sh install <skills.sh-url>` supports direct installs from pages like `https://skills.sh/vercel-labs/skills/find-skills`
- Use `scripts/skill.sh install <owner/repo@skill>` or `scripts/skill.sh ensure "<query>"` when only a remote Codex-native package is available
- Regenerate the shared index after repo-local installation; `scripts/skill.sh` does this automatically

## Quality Bar
- Keep instruction files concise, specific, and non-duplicative
- Keep provider permissions least-privilege by default
- Treat failed sync or verification as incomplete work
- Scope provider-specific behavior to provider-specific files only
- Require explicit architecture boundaries, failure modes, and data flow before implementation
- Require security review, performance checks, edge-case coverage, and regression coverage on changed behavior
- Treat missing critical-path unit, integration, or e2e coverage as incomplete unless the user explicitly waives it
