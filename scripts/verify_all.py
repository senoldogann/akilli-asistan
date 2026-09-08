#!/usr/bin/env python3
"""Repository-wide verification gate.

This script intentionally verifies only the real product/runtime surfaces that
remain in the repository. Legacy multi-provider adapter trees are forbidden.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXAMPILOT = ROOT / "ExamPilot"
ZEROLOSE_PROJECT = ROOT / "ZeroLose" / "ZeroLose.xcodeproj"

FORBIDDEN_PATHS = (
    ".agent",
    ".codex",
    ".claude",
    ".opencode",
    "CLAUDE.md",
    "opencode.json",
    "CODEBASE.md",
    "OPERATIONS.md",
    "USAGE_GUIDE.md",
    "scan_results.json",
    "scripts/sync_agents.py",
    "scripts/provider_config_validator.py",
    "scripts/generate_skill_index.py",
    "scripts/fix_agent_tools.py",
    "scripts/prune_memory.py",
    "scripts/skill.sh",
    "scripts/codex-fast.sh",
    "scripts/codex-research.sh",
    "scripts/codex-review.sh",
    "scripts/codex-safe.sh",
)


def fail(message: str) -> int:
    print(f"[FAIL] {message}", file=sys.stderr)
    return 1


def run(command: list[str], *, cwd: Path) -> bool:
    printable = " ".join(command)
    print(f"\n[RUN] ({cwd.relative_to(ROOT) if cwd != ROOT else '.'}) {printable}")
    completed = subprocess.run(command, cwd=cwd)
    if completed.returncode != 0:
        print(f"[FAIL] exit={completed.returncode}: {printable}", file=sys.stderr)
        return False
    print(f"[OK] {printable}")
    return True


def run_expect_output(
    command: list[str],
    *,
    cwd: Path,
    expected: str,
) -> bool:
    printable = " ".join(command)
    print(f"\n[RUN] ({cwd.relative_to(ROOT) if cwd != ROOT else '.'}) {printable}")
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = completed.stdout or ""
    if output:
        print(output, end="" if output.endswith("\n") else "\n")
    if completed.returncode != 0:
        print(f"[FAIL] exit={completed.returncode}: {printable}", file=sys.stderr)
        return False
    if expected not in output:
        print(
            f"[FAIL] expected output token not found: {expected!r}",
            file=sys.stderr,
        )
        return False
    print(f"[OK] {printable} contains {expected!r}")
    return True


def verify_layout() -> bool:
    ok = True
    for relative in FORBIDDEN_PATHS:
        path = ROOT / relative
        if path.exists() or path.is_symlink():
            print(f"[FAIL] legacy path still exists: {relative}", file=sys.stderr)
            ok = False

    required = (
        ROOT / "README.md",
        ROOT / "AGENTS.md",
        EXAMPILOT / "Package.swift",
        ROOT / ".github" / "workflows" / "exampilot.yml",
    )
    for path in required:
        if not path.exists():
            print(f"[FAIL] required path missing: {path.relative_to(ROOT)}", file=sys.stderr)
            ok = False

    readme = ROOT / "README.md"
    if readme.exists():
        content = readme.read_text(encoding="utf-8", errors="replace").strip()
        if len(content) < 500 or content.lower() == "placeholder":
            print("[FAIL] README.md is incomplete", file=sys.stderr)
            ok = False

    return ok


def verify_exampilot() -> bool:
    if not EXAMPILOT.is_dir():
        return False
    if shutil.which("swift") is None:
        print("[FAIL] swift is required to verify ExamPilot", file=sys.stderr)
        return False

    release_binary = EXAMPILOT / ".build" / "release" / "exampilot"
    return (
        run(["swift", "test"], cwd=EXAMPILOT)
        and run(["swift", "build", "-c", "release"], cwd=EXAMPILOT)
        and run_expect_output(
            [str(release_binary), "--help"],
            cwd=EXAMPILOT,
            expected="--verbose",
        )
    )


def verify_zerolose() -> bool:
    if not ZEROLOSE_PROJECT.exists():
        print("[INFO] ZeroLose project not present; skipping Xcode build")
        return True
    if shutil.which("xcodebuild") is None:
        print("[INFO] xcodebuild unavailable; skipping ZeroLose build")
        return True

    derived_data = ROOT / "ZeroLose" / "build" / "VerificationDerivedData"
    return run(
        [
            "xcodebuild",
            "-project",
            str(ZEROLOSE_PROJECT),
            "-scheme",
            "ZeroLose",
            "-configuration",
            "Debug",
            "-destination",
            "generic/platform=macOS",
            "-derivedDataPath",
            str(derived_data),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=ROOT,
    )


def main() -> int:
    print("Akıllı Asistan repository verification")

    if not verify_layout():
        return fail("repository layout verification failed")

    if not verify_exampilot():
        return fail("ExamPilot verification failed")

    if not verify_zerolose():
        return fail("ZeroLose build verification failed")

    print("\n[OK] repository verification completed successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
