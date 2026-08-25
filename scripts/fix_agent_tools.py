#!/usr/bin/env python3
"""Validate the .agent/agents/*.md frontmatter without mutating it.

The original rewrote agent frontmatter with fragile `.replace()` calls, which
risked corrupting valid YAML. This version is a read-only validation helper: it
reports which agent files are missing `name`, `description`, or `mode` so a
developer can fix them explicitly.

Usage:
    python3 scripts/fix_agent_tools.py [--dump-broken]
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parent.parent / ".agent" / "agents"


def parse_frontmatter(path: Path) -> tuple[dict[str, str], str]:
    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("---"):
        return {}, ""
    parts = raw.split("---", 2)
    if len(parts) < 3:
        return {}, ""
    frontmatter = parts[1]
    meta: dict[str, str] = {}
    for line in frontmatter.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        meta[key.strip().lower()] = value.strip().strip('"').strip("'")
    return meta, parts[2]


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate agent frontmatter (read-only).")
    parser.add_argument(
        "--dump-broken",
        action="store_true",
        help="Print the full frontmatter of broken files (for debugging).",
    )
    args = parser.parse_args()

    required = ("name", "description", "mode")
    broken: list[Path] = []
    total = 0

    for agent_file in sorted(AGENT_DIR.glob("*.md")):
        total += 1
        meta, _ = parse_frontmatter(agent_file)
        missing = [field for field in required if field not in meta]
        if missing:
            broken.append(agent_file)
            print(f"[BROKEN] {agent_file.name}: missing {', '.join(missing)}")
            if args.dump_broken:
                print("  frontmatter starts with:")
                for line in agent_file.read_text(encoding="utf-8").splitlines()[:8]:
                    print(f"    {line}")

    if not broken:
        print(f"OK: {total} agent files have valid name/description/mode frontmatter.")
        return 0
    print(f"Found {len(broken)} broken agent file(s) out of {total}. No files were modified.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
