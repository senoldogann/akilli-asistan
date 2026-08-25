#!/usr/bin/env python3
"""Validate the Maestro provider config layer against the *installed* toolchain.

This validator intentionally does NOT rewrite configuration. It verifies that:
  - The provider config files exist and parse (JSON / TOML).
  - The configs use the schema the installed CLI accepts (opencode 1.18.x uses
    the object form `permission` + `agent`, NOT the newer `permissions` array).
  - Critical local artifacts / build caches are covered by .gitignore so they
    cannot silently end up in git history.
  - No real credentials / API tokens are present in the repo tree.
  - The documented symlink contract is intact.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {
    ".git",
    "data",
    "_library",
    "node_modules",
    # Generated runtime / build caches; these are git-ignored and cannot leak
    # into history, so skipping them avoids scanning hundreds of MB of cache.
    "build",
    ".derived",
    ".review-derived",
    "dist",
    "DerivedData",
    ".build",
    "__pycache__",
    ".swiftpm",
}

SECRET_PATTERNS = [
    re.compile(r"\bsk-[A-Za-z0-9._-]{16,}\b"),
    re.compile(r"\bghp_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgho_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(r"\bsbp_[A-Za-z0-9]{16,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\btvly-[A-Za-z0-9]{16,}\b"),
    re.compile(r"\bgsk_[A-Za-z0-9]{16,}\b"),
]

# Files that are known to contain intentionally-illustrative example secrets.
# These are documentation samples, not real credentials.
EXAMPLE_SECRET_FILES = {
    ".agent/skills/broken-authentication/SKILL.md",
    ".agent/skills/api-design-principles/references/rest-best-practices.md",
    ".agent/skills/ffuf-web-fuzzing/SKILL.md",
    ".agent/skills/security/aws-iam-best-practices/SKILL.md",
}


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def load_json(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        raise RuntimeError(f"JSON parse error in {path}: {exc}") from exc


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


def scan_secrets() -> list[str]:
    findings: list[str] = []
    for base, dirs, files in os.walk(ROOT):
        rel_parts = Path(base).relative_to(ROOT).parts
        if any(part in SKIP_DIRS for part in rel_parts):
            dirs[:] = []
            continue
        for name in files:
            if name.endswith((".pyc", ".png", ".jpg", ".ico", ".lock")):
                continue
            path = Path(base) / name
            rel = path.relative_to(ROOT).as_posix()
            if rel in EXAMPLE_SECRET_FILES:
                continue
            try:
                content = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            for pattern in SECRET_PATTERNS:
                match = pattern.search(content)
                if match:
                    findings.append(f"{rel}: matched {pattern.pattern[:12]}...")
                    break
    return findings


def main() -> int:
    errors: list[str] = []

    codex_path = ROOT / ".codex" / "config.toml"
    claude_path = ROOT / ".claude" / "settings.json"
    opencode_path = ROOT / "opencode.json"

    # 1. Config files must exist and parse.
    for path in (codex_path, claude_path, opencode_path):
        if not path.exists():
            fail(f"Missing provider config: {path}", errors)
    if errors:
        print("Provider config validation failed:")
        for item in errors:
            print(f"- {item}")
        return 1

    codex = parse_codex_config(codex_path)
    try:
        claude = load_json(claude_path)
    except RuntimeError as exc:
        fail(str(exc), errors)
        claude = {}
    try:
        opencode = load_json(opencode_path)
    except RuntimeError as exc:
        fail(str(exc), errors)
        opencode = {}

    # 2. Codex required keys.
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

    codex_agents = codex.get("agents", {})
    for agent_name in ("reviewer", "explorer", "researcher"):
        agent = codex_agents.get(agent_name)
        if not isinstance(agent, dict):
            fail(f"Codex agent '{agent_name}' is missing.", errors)
        elif "description" not in agent:
            fail(f"Codex agent '{agent_name}' is missing a description.", errors)

    # 3. Claud settings permissions buckets.
    claude_permissions = claude.get("permissions", {})
    for required in ("allow", "ask", "deny"):
        if required not in claude_permissions:
            fail(f"Claude settings missing permissions.{required}.", errors)

    # 4. OpenCode schema: installed 1.18.x uses object form `permission` + `agent`.
    if "permissions" in opencode:
        fail(
            "opencode.json uses the newer `permissions` array schema which is not "
            "accepted by the installed opencode 1.18.x; keep `permission` object.",
            errors,
        )
    if "agents" in opencode:
        fail(
            "opencode.json uses the newer `agents` plural schema; the installed "
            "opencode 1.18.x accepts `agent` singular.",
            errors,
        )
    opencode_permissions = opencode.get("permission", {})
    for key in ("*", "external_directory", "webfetch", "websearch", "bash", "read", "edit"):
        if key not in opencode_permissions:
            fail(f"OpenCode global permission missing key: {key}", errors)
    for agent_name in ("review", "verify", "research"):
        if agent_name not in opencode.get("agent", {}):
            fail(f"OpenCode agent '{agent_name}' is missing.", errors)

    # OpenCode provider composition: opencode-go (Go sub), opencode (Zen/free),
    # and deepseek (own API key) must be declared so they can be selected.
    providers = opencode.get("provider", {})
    for provider_id in ("opencode-go", "opencode", "deepseek"):
        if provider_id not in providers:
            fail(f"OpenCode provider '{provider_id}' is not declared.", errors)
    deepseek = providers.get("deepseek", {})
    if deepseek.get("options", {}).get("baseURL") != "https://api.deepseek.com/v1":
        fail("OpenCode deepseek baseURL must be https://api.deepseek.com/v1", errors)
    for model_id in ("deepseek-v4-flash", "deepseek-v4-pro"):
        model = deepseek.get("models", {}).get(model_id, {})
        if not model.get("reasoning"):
            fail(f"OpenCode deepseek model '{model_id}' must declare reasoning: true", errors)
        if model.get("interleaved", {}).get("field") != "reasoning_content":
            fail(f"OpenCode deepseek model '{model_id}' must interleave reasoning_content", errors)

    # 5. .gitignore covers critical generated caches / data.
    gitignore_path = ROOT / ".gitignore"
    if gitignore_path.exists():
        gitignore = gitignore_path.read_text(encoding="utf-8")
        for ignored in ("data/", "ZeroLose/.derived/", "ZeroLose/.review-derived/",
                        "ZeroLose/build.log", "__pycache__/"):
            if ignored not in gitignore:
                fail(f".gitignore is missing: {ignored}", errors)
    else:
        fail("Missing .gitignore", errors)

    # 6. Symlink contract.
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

    # 7. Secret scan (repo tree, skipping known example files and generated dirs).
    secret_findings = scan_secrets()
    if secret_findings:
        fail(f"Real secrets detected in repo tree: {secret_findings[0]}", errors)

    if errors:
        print("Provider config validation failed:")
        for item in errors:
            print(f"- {item}")
        return 1

    print("Provider config validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
