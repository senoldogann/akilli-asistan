#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_codex_config(path: Path) -> dict:
    data: dict = {"agents": {}}
    current_section: tuple[str, str] | str | None = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            if section.startswith("agents."):
                agent_name = section.split(".", 1)[1]
                data["agents"].setdefault(agent_name, {})
                current_section = ("agents", agent_name)
            else:
                data.setdefault(section, {})
                current_section = section
            continue
        if "=" not in line:
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        if current_section is None:
            data[key] = value
        elif isinstance(current_section, tuple) and current_section[0] == "agents":
            data["agents"][current_section[1]][key] = value
        else:
            data[current_section][key] = value

    return data


def main() -> int:
    errors: list[str] = []

    codex_path = ROOT / ".codex" / "config.toml"
    claude_path = ROOT / ".claude" / "settings.json"
    opencode_path = ROOT / "opencode.json"

    codex = parse_codex_config(codex_path)
    claude = load_json(claude_path)
    opencode = load_json(opencode_path)

    required_codex_keys = {
        "model",
        "model_context_window",
        "model_auto_compact_token_limit",
        "project_doc_max_bytes",
        "project_doc_fallback_filenames",
    }
    missing_codex = sorted(required_codex_keys - set(codex))
    if missing_codex:
        fail(f"Codex config missing keys: {', '.join(missing_codex)}", errors)
    if "profiles" in codex:
        fail("Codex config must not contain project-local [profiles.*] blocks.", errors)

    codex_agents = codex.get("agents", {})
    for agent_name in ("reviewer", "explorer", "researcher"):
        agent = codex_agents.get(agent_name)
        if not isinstance(agent, dict) or "description" not in agent:
            fail(f"Codex agent '{agent_name}' is missing a description.", errors)

    claude_permissions = claude.get("permissions", {})
    for required in ("allow", "ask", "deny"):
        if required not in claude_permissions:
            fail(f"Claude settings missing permissions.{required}.", errors)
    for bucket_name in ("allow", "ask", "deny"):
        for item in claude_permissions.get(bucket_name, []):
            if item.startswith("Bash(") and ":" in item:
                fail(
                    f"Claude Bash permission uses unsupported ':' syntax: {item}",
                    errors,
                )

    expected_symlinks = {
        ROOT / "CLAUDE.md": "AGENTS.md",
        ROOT / ".claude" / "agents": "../.agent/agents",
        ROOT / ".claude" / "skills": "../.agent/skills",
        ROOT / ".claude" / "commands": "../.agent/workflows",
        ROOT / ".opencode" / "agents": "../.agent/agents",
        ROOT / ".opencode" / "skills": "../.agent/skills",
    }
    for link_path, target in expected_symlinks.items():
        if not link_path.is_symlink():
            fail(f"Expected symlink missing: {link_path}", errors)
            continue
        if os.readlink(link_path) != target:
            fail(f"Symlink target drift: {link_path} -> {os.readlink(link_path)}", errors)

    forbidden_local_artifacts = [
        ROOT / ".DS_Store",
        ROOT / ".opencode" / ".gitignore",
        ROOT / ".opencode" / "package.json",
        ROOT / ".opencode" / "bun.lock",
        ROOT / ".opencode" / "node_modules",
    ]
    for path in forbidden_local_artifacts:
        if path.exists():
            fail(f"Extraneous local artifact must be removed: {path}", errors)

    allowed_global_permission_keys = {
        "*",
        "external_directory",
        "doom_loop",
        "webfetch",
        "websearch",
        "bash",
        "read",
        "edit",
    }
    opencode_permissions = opencode.get("permission", {})
    unexpected_global_keys = sorted(set(opencode_permissions) - allowed_global_permission_keys)
    if unexpected_global_keys:
        fail(
            "OpenCode global permission keys are unsupported: "
            + ", ".join(unexpected_global_keys),
            errors,
        )

    allowed_agent_permission_keys = {"edit", "bash", "webfetch"}
    for agent_name, agent_value in opencode.get("agent", {}).items():
        permission = agent_value.get("permission", {})
        unexpected_agent_keys = sorted(set(permission) - allowed_agent_permission_keys)
        if unexpected_agent_keys:
            fail(
                f"OpenCode agent '{agent_name}' has unsupported permission keys: "
                + ", ".join(unexpected_agent_keys),
                errors,
            )

    if errors:
        print("Provider config validation failed:")
        for item in errors:
            print(f"- {item}")
        return 1

    print("Provider config validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
