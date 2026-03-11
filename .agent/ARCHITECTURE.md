# Antigravity Kit Architecture

## Runtime Layers
- `AGENTS.md`: shared cross-provider policy
- `.agent/`: Antigravity-native runtime assets
- Provider adapters: `.codex/`, `.claude/`, `.opencode/`

## Supported Providers
- `Antigravity`: native `.agent/` layout
- `Codex`: `AGENTS.md`, `.codex/config.toml`
- `Claude Code`: `CLAUDE.md`, `.claude/settings.json`, `.claude/agents/`, `.claude/skills/`, `.claude/commands/`
- `OpenCode`: `AGENTS.md`, `opencode.json`, `.opencode/agents/`, `.opencode/skills/`, `.opencode/commands/`

## Shared Assets
- `.agent/agents/`: markdown agent definitions reused by Antigravity, Claude Code, and OpenCode
- `.agent/skills/`: shared skill library exposed through provider-native directories where supported
- `.agent/workflows/`: markdown command/workflow files exposed to Claude Code via `.claude/commands/`
- `.agent/rules/`: Antigravity constitutional modules and shared policy references
- `scripts/skill.sh`: missing-capability resolver for shared skills and Codex-native remote installs

## Adapter Principles
- Keep provider adapters documentation-compliant and minimal
- Use symlinks where the provider supports direct filesystem discovery
- Avoid duplicated combined prompt files when the provider already supports root instruction files
- Keep provider permissions least-privilege and repo-scoped by default
- Keep current-information access available so agents can verify stale or uncertain facts
- Encode loop-breaking behavior in shared rules and provider permissions where supported
- Provide a supported path to acquire missing skills instead of letting agents hallucinate missing capabilities
- Remove unsupported providers from sync logic and the filesystem
- Do not present unofficial compatibility mirrors as provider-native features

## Sync Ownership
- `scripts/sync_agents.py` is the only script that should regenerate adapter files or symlinks
- After rule changes, sync first, then run full verification
