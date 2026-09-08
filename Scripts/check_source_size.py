#!/usr/bin/env python3
"""Enforce AGENTS.md's physical-line limit for repository-owned production code."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 600


def main():
    paths = subprocess.check_output([
        "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
        "Sources", "DemoApp/AssistantRuntimeDemoApp", "Scripts",
    ], cwd=ROOT).decode().split("\0")
    count = 0
    failures = []
    for name in sorted(set(paths)):
        path = ROOT / name
        if path.suffix not in {".swift", ".py", ".sh", ".m", ".h"} or not path.is_file():
            continue
        count += 1
        lines = len(path.read_bytes().splitlines())
        if lines > LIMIT:
            failures.append(f"{name}: {lines} physical lines (maximum {LIMIT})")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Source-size check passed: {count} production files, maximum {LIMIT} physical lines.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
