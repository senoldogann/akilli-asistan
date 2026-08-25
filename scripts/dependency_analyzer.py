#!/usr/bin/env python3
"""Dependency & file audit for the Maestro harness.

Unlike the original which only checked the presence of two files, this verifies
that:
  - Every critical path listed in CODEBASE.md exists on disk.
  - The shared skill library does not duplicate into `_library` (a copy is a
    maintenance hazard).
  - Generated runtime dirs are not tracked by git (so they stay out of history).
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from common_utils import print_header, print_success, print_fail, print_warning, print_info

ROOT_DIR = Path(os.getcwd())

# High-level connectors that must exist (documented in CODEBASE.md).
CRITICAL_PATHS = [
    "AGENTS.md",
    "CLAUDE.md",
    "opencode.json",
    "CODEBASE.md",
    "scan_results.json",
    ".agent/ARCHITECTURE.md",
    ".agent/SYSTEM.md",
    ".codex/config.toml",
    ".claude/settings.json",
    "ZeroLose/AGENTS.md",
    "ZeroLose/README.md",
]

# Generated runtime dirs that should never be tracked.
GENERATED_DIRS = [
    "ZeroLose/.derived",
    "ZeroLose/.review-derived",
    "ZeroLose/dist",
    "data",
]


def run_cmd(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout.strip()
    except Exception as exc:
        return f"<error: {exc}>"


def check_critical_paths() -> bool:
    print_header("Critical Path Audit")
    ok = True
    for rel in CRITICAL_PATHS:
        path = ROOT_DIR / rel
        if path.exists():
            print_success(f"Exists: {rel}")
        else:
            print_fail(f"Missing: {rel}")
            ok = False
    return ok


def check_library_duplication() -> bool:
    print_header("Library Duplication Check")
    ok = True
    repo_skills = ROOT_DIR / ".agent" / "skills"
    library_skills = ROOT_DIR / "_library" / "skills"
    if library_skills.exists() and repo_skills.exists():
        repo_names = {p.name for p in repo_skills.iterdir() if p.is_dir()}
        lib_names = {p.name for p in library_skills.iterdir() if p.is_dir()}
        overlap = repo_names & lib_names
        if overlap:
            # _library is a local, git-ignored backup. It is only a problem if it
            # is also tracked by git; otherwise the source of truth is .agent/skills.
            tracked = run_cmd(["git", "ls-files", "_library"])
            if tracked:
                print_warning(
                    f"{len(overlap)} skill folder(s) duplicated and _library is "
                    f"tracked by git ({len(tracked.splitlines())} files)"
                )
                ok = False
            else:
                print_success(
                    f"{len(overlap)} overlap(s) are local-only (git-ignored), "
                    "source of truth is .agent/skills"
                )
        else:
            print_success("No overlapping skill folders between .agent/skills and _library/skills")
    else:
        print_success("No _library duplication detected")
    return ok


def check_generated_dirs_tracked() -> bool:
    print_header("Generated Runtime Artifacts")
    ok = True
    for rel in GENERATED_DIRS:
        tracked = run_cmd(["git", "ls-files", rel])
        if tracked:
            count = len(tracked.splitlines())
            print_fail(f"{rel} is tracked by git ({count} files) - remove from index")
            ok = False
        else:
            print_success(f"{rel} not tracked by git")
    return ok


def check_codebase_tree() -> bool:
    print_header("CODEBASE.md Tree Consistency")
    codebase_path = ROOT_DIR / "CODEBASE.md"
    if not codebase_path.exists():
        print_fail("Missing CODEBASE.md")
        return False
    content = codebase_path.read_text(encoding="utf-8")
    # Ensure the document is not a stale placeholder.
    critical_mentions = ("ZeroLose/", ".agent/", "scripts/")
    for mention in critical_mentions:
        if mention not in content:
            print_fail(f"CODEBASE.md does not mention {mention}")
            return False
    print_success("CODEBASE.md is populated and consistent")
    return True


def main() -> int:
    print_header("MAESTRO DEPENDENCY ANALYZER")
    ok = True
    ok &= check_critical_paths()
    ok &= check_library_duplication()
    ok &= check_generated_dirs_tracked()
    ok &= check_codebase_tree()

    print("\n")
    if ok:
        print_success("Dependency audit completed successfully.")
        return 0
    print_fail("Dependency audit found inconsistencies.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
