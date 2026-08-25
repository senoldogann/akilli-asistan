# Maestro System Map

## Shared Source Of Truth
- `AGENTS.md`: shared operating policy for every supported provider
- `.agent/SYSTEM.md`: provider map, directory contract, sync behavior
- `.agent/rules/GEMINI.md`: Antigravity-native constitutional entry point
- `.agent/rules/02-research-and-anti-loop.md`: mandatory current-info escalation and loop prevention
- `.agent/rules/03-skill-resolution.md`: mandatory missing-skill acquisition flow

## Supported Providers
| Provider | Repo entry points | Notes |
| --- | --- | --- |
| `Antigravity` | `.agent/rules/GEMINI.md`, `.agent/agents/`, `.agent/skills/`, `.agent/workflows/` | Native runtime layout; use native `web_search` or approved MCP research tools when uncertainty is temporal |
| `Codex` | `AGENTS.md`, `.codex/config.toml` | Codex project instructions come from `AGENTS.md`; current-info sessions should use `scripts/codex-research.sh` or `codex --search`; use `scripts/codex-*.sh` wrappers for task-specific overrides |
| `Claude Code` | `CLAUDE.md`, `.claude/settings.json`, `.claude/agents/`, `.claude/skills/`, `.claude/commands/` | `CLAUDE.md` is a symlink to `AGENTS.md`; `settings.json` allows `WebSearch` / `WebFetch` for current verification |
| `OpenCode` | `AGENTS.md`, `opencode.json`, `.opencode/agents/`, `.opencode/skills/`, `.opencode/commands/` | OpenCode uses `AGENTS.md` first, loads extra instructions from config, enables `websearch` / `webfetch`, and blocks repeat loops with global `doom_loop` |

## Provider Credentials & Model Routing

`opencode.json` declares a `provider` map so the installed OpenCode CLI can select:

- `opencode-go/*` — OpenCode Go subscription models (e.g. `qwen3.8-max`, `glm-5.2`).
  Note: some `opencode-go/deepseek-*` variants are China-hosted and require explicit
  workspace opt-in before they respond.
- `opencode/*` — OpenCode Zen free models (e.g. `mimo-v2.5-free`).
- `deepseek/*` — the user's own DeepSeek API key (`api.deepseek.com/v1`), configured
  with `reasoning: true` + `interleaved.reasoning_content` so thinking traces are
  captured. Verified working with `deepseek/deepseek-v4-pro`.

Credentials live in `~/.local/share/opencode/auth.json` (`opencode auth list`).
ZeroLose mirrors this with its own Keychain-backed `Secrets.deepSeekApiKey` and
`AIModelNames` DeepSeek defaults.

## Directory Contract
```text
.
├── AGENTS.md
├── CLAUDE.md -> AGENTS.md
├── opencode.json
├── .agent/
│   ├── SYSTEM.md
│   ├── ARCHITECTURE.md
│   ├── agents/
│   ├── skills/
│   ├── workflows/
│   └── rules/
├── .codex/
│   ├── config.toml
│   └── rules/
├── .claude/
│   ├── agents/ -> ../.agent/agents
│   ├── settings.json
│   ├── skills/ -> ../.agent/skills
│   └── commands/ -> ../.agent/workflows
├── .opencode/
│   ├── agents/ -> ../.agent/agents
│   ├── skills/ -> ../.agent/skills
│   └── commands/
└── scripts/
    ├── codex-fast.sh
    ├── codex-research.sh
    ├── codex-review.sh
    ├── codex-safe.sh
    ├── skill.sh
    ├── provider_config_validator.py
    ├── sync_agents.py
    └── verify_all.py
```

## Sync Rules
- `scripts/sync_agents.py` owns provider adapter cleanup and regeneration
- Unsupported adapters must be deleted, not left dormant
- Shared content should be referenced once and exposed via documented provider entry points
- Provider permission policies must be regenerated from sync, not hand-maintained in drift

## Verification Rules
- Run `python3 scripts/sync_agents.py` after any rule change
- Run `python3 scripts/verify_all.py` before completion
- `verify_all.py` must include provider config validation, not only repo-local housekeeping checks
- If sync or verification fails, treat the task as unfinished

## Research Rules
- When a task is current, comparative, or uncertain, switch to live research before answering from memory
- Use official docs first, then secondary sources only if required
- Stop repeated non-progressing attempts and change strategy instead of looping

## Skill Acquisition Rules
- If the needed capability is missing, run `scripts/skill.sh ensure "<query-or-skill-name>"`
- Prefer repo-shared installation when the skill is generic and portable
- Use global Codex install when the upstream ecosystem only exposes a Codex-native package format
