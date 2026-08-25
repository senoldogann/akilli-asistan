#!/usr/bin/env python3
"""Prune stale agent-runtime/generated caches.

The original targeted `.loki/` and `.agent/memory/`, neither of which exists in
this repository. This version is a safe, dry-run-by-default cleanup that targets
the actual generated runtime dirs (`data/.ccm-generations`, stale `archive/`)
and never deletes source or config.

Safety:
  - Defaults to --dry-run, so nothing is removed unless explicitly requested.
  - Only removes files older than a threshold and only inside generated dirs.
"""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Generated runtime directories. These are not source; they can be regenerated.
RUNTIME_DIRS = [
    ROOT / "data" / ".ccm-generations",
]

# Age thresholds (seconds). Default keeps recent artifacts.
DEFAULT_MAX_AGE_SECONDS = 7 * 24 * 3600


def _file_age_seconds(path: Path) -> float:
    try:
        return time.time() - path.stat().st_mtime
    except OSError:
        return float("inf")


def prune_dir(root: Path, max_age_seconds: int, dry_run: bool, verbose: bool) -> int:
    if not root.is_dir():
        if verbose:
            print(f"  Skip: {root} (missing)")
        return 0

    removed = 0
    for item in root.rglob("*"):
        if not item.is_file():
            continue
        age = _file_age_seconds(item)
        if age > max_age_seconds:
            if verbose:
                print(f"  {'[would remove]' if dry_run else '[removing]'} {item}")
            if not dry_run:
                try:
                    item.unlink()
                except OSError as exc:
                    print(f"  [error] {item}: {exc}")
            removed += 1

    return removed


def main() -> int:
    parser = argparse.ArgumentParser(description="Prune stale generated runtime caches.")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be removed (default).")
    parser.add_argument("--apply", action="store_true", help="Actually remove files.")
    parser.add_argument("--max-age-days", type=int, default=7, help="Max age in days (default: 7).")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if not args.apply:
        print("DRY RUN - No files will be modified. Use --apply to actually remove files.")
    dry_run = not args.apply
    max_age_seconds = args.max_age_days * 24 * 3600

    print("Memory Pruning Report")
    print("=" * 40)
    processed = 0
    for runtime_dir in RUNTIME_DIRS:
        processed += prune_dir(runtime_dir, max_age_seconds, dry_run, args.verbose)
    print("=" * 40)
    print(f"Stale generated files processed: {processed}")
    if dry_run:
        print("\nRun with --apply to remove them.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
