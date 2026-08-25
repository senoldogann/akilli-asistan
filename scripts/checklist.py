#!/usr/bin/env python3
"""Structural health check for the Maestro harness.

This verifies the repo contract, not just file presence. It also reports
warnings for common hygiene problems (empty PLANDRA, missing metadata) so the
harness stays genuinely usable rather than merely "green".
"""

import os
import sys
from pathlib import Path

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from common_utils import print_header, print_success, print_fail, print_warning, print_info

ROOT_DIR = Path(os.getcwd())

REQUIRED_FILES = [
    "CODEBASE.md",
    "AGENTS.md",
    ".agent/ARCHITECTURE.md",
    ".agent/rules/GEMINI.md",
    ".agent/rules/00-ARCHITECT-MANIFESTO.md",
    ".agent/rules/01-safety-and-persistence.md",
    ".agent/rules/05-self-reflection.md",
    ".agent/rules/10-parallel-execution.md",
    ".agent/rules/20-observability.md",
    ".agent/rules/30-error-handling.md",
    ".agent/rules/40-api-design.md",
    ".agent/rules/50-security-and-testing.md",
    ".agent/rules/100-tech-stack.md",
]

REQUIRED_DIRS = [
    "docs",
    ".agent/agents",
    ".agent/skills",
    ".agent/workflows",
    "scripts",
]

REQUIRED_PROVIDER_FILES = [
    "opencode.json",
    ".codex/config.toml",
    ".claude/settings.json",
    ".agent/SYSTEM.md",
]


def check_structure() -> bool:
    print_header("Structural Integrity Check")
    all_passed = True

    for d in REQUIRED_DIRS:
        if (ROOT_DIR / d).is_dir():
            print_success(f"Directory found: {d}")
        else:
            print_fail(f"Missing directory: {d}")
            all_passed = False

    for f in REQUIRED_FILES:
        if (ROOT_DIR / f).exists():
            print_success(f"File found: {f}")
        else:
            print_fail(f"Missing file: {f}")
            all_passed = False

    for f in REQUIRED_PROVIDER_FILES:
        if (ROOT_DIR / f).exists():
            print_success(f"Provider file found: {f}")
        else:
            print_fail(f"Missing provider file: {f}")
            all_passed = False

    return all_passed


def check_provider_symlinks() -> bool:
    print_header("Provider Symlink Contract")
    ok = True
    expected = {
        "CLAUDE.md": "AGENTS.md",
        ".claude/agents": "../.agent/agents",
        ".claude/skills": "../.agent/skills",
        ".claude/commands": "../.agent/workflows",
        ".opencode/agents": "../.agent/agents",
        ".opencode/skills": "../.agent/skills",
    }
    for link, target in expected.items():
        path = ROOT_DIR / link
        if not path.is_symlink():
            print_fail(f"Missing symlink: {link}")
            ok = False
        elif os.readlink(path) != target:
            print_fail(f"Symlink drift: {link} -> {os.readlink(path)}")
            ok = False
        else:
            print_success(f"Symlink OK: {link} -> {target}")
    return ok


def check_documentation_consistency() -> bool:
    print_header("Documentation Consistency Check")
    passed = True
    arch_path = ROOT_DIR / ".agent" / "ARCHITECTURE.md"
    if arch_path.exists():
        content = arch_path.read_text(encoding="utf-8")
        if "CODEBASE.md" not in content:
            print_warning("ARCHITECTURE.md does not reference CODEBASE.md (soft fail)")
            passed = False
        else:
            print_success("ARCHITECTURE.md references CODEBASE.md")
    else:
        print_fail("Missing .agent/ARCHITECTURE.md")
        passed = False
    return passed


def check_plan_exists() -> None:
    plan_path = ROOT_DIR / "docs" / "PLAN.md"
    if plan_path.exists():
        content = plan_path.read_text(encoding="utf-8")
        # A template-only plan file is a readiness warning, not a blocker.
        if "Owner" in content and "[Agent Name]" in content:
            print_warning("docs/PLAN.md is still a template (not an active task)")
        else:
            print_success("docs/PLAN.md exists")
    else:
        print_warning("No active plan found at docs/PLAN.md (Recommended for active tasks)")


def check_skill_metadata() -> bool:
    print_header("Skill Metadata Sanity")
    skills_root = ROOT_DIR / ".agent" / "skills"
    if not skills_root.is_dir():
        print_fail("Missing .agent/skills")
        return False
    total = 0
    missing_desc = 0
    for child in skills_root.iterdir():
        skill_md = child / "SKILL.md"
        if not skill_md.is_file():
            continue
        total += 1
        content = skill_md.read_text(encoding="utf-8", errors="ignore")
        if "description:" not in content:
            missing_desc += 1
    print_info(f"Skills scanned: {total}, missing description: {missing_desc}")
    if missing_desc:
        print_warning(f"{missing_desc} skill(s) are missing a description field")
    return missing_desc == 0


def main() -> int:
    print_header("MAESTRO SYSTEM CHECKLIST")

    struct_ok = check_structure()
    symlink_ok = check_provider_symlinks()
    doc_ok = check_documentation_consistency()
    check_plan_exists()
    skill_ok = check_skill_metadata()

    print("\n")
    if struct_ok and symlink_ok and doc_ok and skill_ok:
        print_success("SYSTEM HEALTHY - Ready for designation")
        return 0
    print_fail("SYSTEM ISSUES DETECTED - Please fix missing components")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
