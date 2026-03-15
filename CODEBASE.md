# Maestro Codebase Map

This file documents the top-level repository layout used by the Maestro multi-provider agent stack and the ZeroLose macOS application.

## Repository Tree

```text
.
├── AGENTS.md
├── CLAUDE.md
├── CONTRIBUTING.md
├── LICENSE
├── OPERATIONS.md
├── README_GHOST.md
├── SECURITY.md
├── USAGE_GUIDE.md
├── CODEBASE.md
├── scan_results.json
├── docs/
│   └── PLAN.md
├── scripts/
│   ├── checklist.py
│   ├── common_utils.py
│   ├── dependency_analyzer.py
│   ├── provider_config_validator.py
│   ├── skill.sh
│   ├── sync_agents.py
│   └── verify_all.py
├── .agent/
│   ├── ARCHITECTURE.md
│   ├── SYSTEM.md
│   ├── agents/
│   ├── rules/
│   ├── skills/
│   └── workflows/
├── .codex/
│   ├── config.toml
│   └── rules/
├── .claude/
│   ├── agents/
│   ├── commands/
│   ├── settings.json
│   └── skills/
├── .opencode/
│   ├── agents/
│   ├── commands/
│   └── skills/
└── ZeroLose/
    ├── AGENTS.md
    ├── README.md
    ├── SYSTEM_AUDIO_SETUP.md
    ├── ZeroLose/
    ├── ZeroLose.xcodeproj/
    ├── ZeroLoseTests/
    ├── ZeroLoseUITests/
    └── dist/
```

## Notes

- `scan_results.json` is a repo-level verification artifact referenced by dependency audit scripts.
- `ZeroLose/` contains the product code, tests, packaging output, and app-specific documentation.
- Provider-specific agent adapters must remain thin and defer shared policy to `AGENTS.md`, `.agent/SYSTEM.md`, and `.agent/rules/`.
