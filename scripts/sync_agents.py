#!/usr/bin/env python3
import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

UNSUPPORTED_PATHS = [
    ".cursor",
    ".roo",
    ".windsurf",
    ".kilocode",
    ".clinerules",
    ".roorules",
    ".cursorrules",
    ".windsurfrules",
    ".aiderules",
    ".kilocoderules",
    ".rules",
    "QWEN.md",
    ".agents",
]

EXTRANEOUS_PATHS = [
    ".DS_Store",
    ".opencode/.gitignore",
    ".opencode/package.json",
    ".opencode/package-lock.json",
    ".opencode/bun.lock",
    ".opencode/node_modules",
]

CODEX_CONFIG = """# Codex CLI — Project Configuration
# Ref: https://developers.openai.com/codex/config-basic

model = \"gpt-5.4\"
# GPT-5.4 supports a 1,050,000-token context window in OpenAI's official model docs.
model_context_window = 1050000
# Compact before the hard limit so Codex preserves headroom for the next response.
model_auto_compact_token_limit = 1000000
# Use scripts/codex-*.sh for task-specific overrides.
# Project-local profile blocks are intentionally omitted because current Codex CLI
# builds do not resolve them consistently across subcommands.

project_doc_max_bytes = 65536
project_doc_fallback_filenames = [\"AGENTS.md\", \"CLAUDE.md\", \".agent/SYSTEM.md\"]

[features]
multi_agent = true

[agents.reviewer]
description = \"Kod incelemesi, mimari, guvenlik, performans ve test risk analizi\"

[agents.explorer]
description = \"Hızlı codebase keşfi (read-only)\"

[agents.researcher]
description = \"Guncel dokumantasyon, web arastirmasi ve kaynak dogrulama\"
"""

CLAUDE_SETTINGS = {
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "permissions": {
        "defaultMode": "acceptEdits",
        "disableBypassPermissionsMode": "disable",
        "allow": [
            "Bash(pwd)",
            "Bash(ls)",
            "Bash(ls *)",
            "Bash(readlink *)",
            "Bash(find *)",
            "Bash(rg *)",
            "Bash(cat *)",
            "Bash(sed *)",
            "Bash(head *)",
            "Bash(tail *)",
            "Bash(wc *)",
            "Bash(sort *)",
            "Bash(uniq *)",
            "Bash(diff *)",
            "Bash(git status)",
            "Bash(git status *)",
            "Bash(git diff)",
            "Bash(git diff *)",
            "Bash(python3 scripts/sync_agents.py)",
            "Bash(python3 scripts/verify_all.py)",
            "Bash(python3 scripts/generate_skill_index.py)",
            "Bash(python3 scripts/provider_config_validator.py)",
            "Bash(python3 scripts/checklist.py)",
            "Bash(python3 scripts/dependency_analyzer.py)",
            "Bash(scripts/skill.sh *)",
            "WebFetch",
            "WebSearch",
        ],
        "ask": [
            "Bash(python3 *)",
            "Bash(git add *)",
            "Bash(git commit *)",
            "Bash(git push *)",
        ],
        "deny": [
            "Bash(curl *)",
            "Bash(wget *)",
            "Bash(sudo *)",
            "Bash(rm -rf *)",
            "Bash(git reset --hard)",
            "Bash(git reset --hard *)",
            "Bash(git clean -fd)",
            "Bash(git clean -fd *)",
            "Read(./.env)",
            "Read(./.env.*)",
            "Read(./secrets/**)",
            "Read(./config/credentials.json)",
            "Read(./*.pem)",
            "Read(./*.key)",
        ],
    }
}

OPENCODE_CONFIG = {
    "$schema": "https://opencode.ai/config.json",
    "model": "deepseek/deepseek-v4-pro",
    "small_model": "opencode/mimo-v2.5-free",
    "default_agent": "build",
    "instructions": [
        ".agent/SYSTEM.md",
        ".agent/rules/GEMINI.md",
    ],
    "provider": {
        "opencode-go": {},
        "opencode": {},
        "deepseek": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "DeepSeek",
            "options": {
                "baseURL": "https://api.deepseek.com/v1"
            },
            "models": {
                "deepseek-v4-flash": {
                    "name": "DeepSeek V4 Flash",
                    "reasoning": True,
                    "interleaved": {"field": "reasoning_content"},
                },
                "deepseek-v4-pro": {
                    "name": "DeepSeek V4 Pro",
                    "reasoning": True,
                    "interleaved": {"field": "reasoning_content"},
                },
                "deepseek-v4-flash-vision-exp": {
                    "name": "DeepSeek V4 Flash Vision",
                    "reasoning": True,
                    "interleaved": {"field": "reasoning_content"},
                },
            },
        },
    },
    "permission": {
        "*": "ask",
        "external_directory": "deny",
        "doom_loop": "deny",
        "webfetch": "allow",
        "websearch": "allow",
        "bash": {
            "*": "ask",
            "pwd": "allow",
            "ls *": "allow",
            "readlink *": "allow",
            "find *": "allow",
            "rg *": "allow",
            "cat *": "allow",
            "sed *": "allow",
            "head *": "allow",
            "tail *": "allow",
            "wc *": "allow",
            "git status*": "allow",
            "git diff*": "allow",
            "python3 scripts/sync_agents.py*": "allow",
            "python3 scripts/verify_all.py*": "allow",
            "python3 scripts/generate_skill_index.py*": "allow",
            "python3 scripts/provider_config_validator.py*": "allow",
            "python3 scripts/checklist.py*": "allow",
            "python3 scripts/dependency_analyzer.py*": "allow",
            "scripts/skill.sh*": "allow",
            "rm *": "deny",
            "sudo *": "deny",
        },
        "read": {
            "*": "allow",
            ".env": "deny",
            ".env.*": "deny",
            "secrets/**": "deny",
            "*.pem": "deny",
            "*.key": "deny",
            "config/credentials.json": "deny",
        },
        "edit": {
            "*": "ask",
            "AGENTS.md": "allow",
            ".agent/**": "allow",
            ".codex/**": "allow",
            ".claude/**": "allow",
            ".opencode/**": "allow",
            "opencode.json": "allow",
            "scripts/**": "allow",
        },
    },
    "agent": {
        "review": {
            "description": "Read-only review for provider rules, drift, security, and verification gaps",
            "mode": "subagent",
            "temperature": 0.1,
            "permission": {
                "edit": "deny",
                "webfetch": "allow",
                "bash": {
                    "*": "ask",
                    "git status*": "allow",
                    "git diff*": "allow",
                    "find *": "allow",
                    "rg *": "allow",
                    "cat *": "allow",
                    "sed *": "allow",
                    "head *": "allow",
                    "tail *": "allow",
                    "wc *": "allow",
                    "python3 scripts/checklist.py*": "allow",
                    "python3 scripts/dependency_analyzer.py*": "allow",
                    "python3 scripts/provider_config_validator.py*": "allow",
                    "python3 scripts/verify_all.py*": "allow",
                },
            },
            "prompt": "Review changes to this rules repository. Focus on provider-doc drift, unsupported config keys, architecture regressions, security exposure, performance blind spots, missing edge-case coverage, and verification gaps. Do not modify files.",
        },
        "verify": {
            "description": "Run Maestro sync and verification workflow with minimal drift risk",
            "mode": "subagent",
            "temperature": 0.1,
            "permission": {
                "webfetch": "allow",
                "edit": "ask",
                "bash": {
                    "*": "ask",
                    "pwd": "allow",
                    "ls *": "allow",
                    "rg *": "allow",
                    "cat *": "allow",
                    "sed *": "allow",
                    "python3 scripts/sync_agents.py*": "allow",
                    "python3 scripts/verify_all.py*": "allow",
                    "python3 scripts/generate_skill_index.py*": "allow",
                    "python3 scripts/provider_config_validator.py*": "allow",
                    "python3 scripts/checklist.py*": "allow",
                    "python3 scripts/dependency_analyzer.py*": "allow",
                    "scripts/skill.sh*": "allow",
                },
            },
            "prompt": "Run the repository sync and verification workflow. If a check fails, identify the exact file or config mismatch before making any fix.",
        },
        "research": {
            "description": "Current-docs and web research specialist for stale, comparative, or uncertain tasks",
            "mode": "subagent",
            "temperature": 0.1,
            "permission": {
                "edit": "deny",
                "webfetch": "allow",
                "bash": {
                    "*": "ask",
                    "pwd": "allow",
                    "ls *": "allow",
                    "find *": "allow",
                    "rg *": "allow",
                    "cat *": "allow",
                    "sed *": "allow",
                    "scripts/skill.sh search*": "allow",
                },
            },
            "prompt": "When a task depends on current facts, official guidance, or the best available option, search the web and read primary-source documentation before answering. Do not loop on the same failed attempt; change evidence source immediately.",
        },
    },
}


def remove_path(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    shutil.rmtree(path)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def ensure_symlink(link_path: Path, target: str) -> None:
    if link_path.is_symlink() and os.readlink(link_path) == target:
        return
    remove_path(link_path)
    ensure_dir(link_path.parent)
    link_path.symlink_to(target)


def write_text(path: Path, content: str) -> None:
    ensure_dir(path.parent)
    path.write_text(content, encoding="utf-8")


def write_json(path: Path, content: dict) -> None:
    write_text(path, json.dumps(content, indent=2) + "\n")


def sync_codex() -> None:
    print("  - Syncing Codex...")
    write_text(ROOT / ".codex" / "config.toml", CODEX_CONFIG)


def sync_claude() -> None:
    print("  - Syncing Claude Code...")
    ensure_symlink(ROOT / "CLAUDE.md", "AGENTS.md")
    ensure_symlink(ROOT / ".claude" / "agents", "../.agent/agents")
    ensure_symlink(ROOT / ".claude" / "skills", "../.agent/skills")
    ensure_symlink(ROOT / ".claude" / "commands", "../.agent/workflows")
    write_json(ROOT / ".claude" / "settings.json", CLAUDE_SETTINGS)
    remove_path(ROOT / ".claude" / "rules")
    remove_path(ROOT / ".claude" / "workflows")


def sync_opencode() -> None:
    print("  - Syncing OpenCode...")
    write_json(ROOT / "opencode.json", OPENCODE_CONFIG)

    ensure_symlink(ROOT / ".opencode" / "agents", "../.agent/agents")
    ensure_symlink(ROOT / ".opencode" / "skills", "../.agent/skills")
    ensure_dir(ROOT / ".opencode" / "commands")
    remove_path(ROOT / ".opencode" / "instructions")


def cleanup_unsupported() -> None:
    print("  - Removing unsupported provider adapters...")
    for rel in UNSUPPORTED_PATHS:
        remove_path(ROOT / rel)


def cleanup_extraneous() -> None:
    print("  - Removing extraneous local runtime artifacts...")
    for rel in EXTRANEOUS_PATHS:
        remove_path(ROOT / rel)


def main() -> None:
    print("🔄 Maestro Sync Engine starting...")
    cleanup_unsupported()
    cleanup_extraneous()
    sync_codex()
    sync_claude()
    sync_opencode()
    print("✅ Sync completed for Antigravity, Codex, Claude Code, and OpenCode.")


if __name__ == "__main__":
    main()
