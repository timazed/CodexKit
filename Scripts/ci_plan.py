#!/usr/bin/env python3
"""Choose fresh verification or reuse, and select relevant extended workloads."""
import argparse
import fnmatch
import json
import os
from pathlib import Path
import subprocess

from ci_evidence import EvidenceError, GitHub, find_evidence


def extended_checks(paths, force=False):
    stress = ("Sources/CodexKitSQLite/*", "Sources/CodexKitRealm/*", "Sources/CodexKit/Persistence/*",
              "Sources/CodexKit/Runtime/*Storage*", "Sources/CodexKit/Runtime/*Store*",
              "Sources/CodexKit/Runtime/*Persistence*", "Sources/CodexKit/Runtime/*Execution*",
              "Sources/CodexKit/Memory/*", "Sources/CodexKit/Concurrency/*",
              "Sources/CodexKit/Runtime/*History*", "Sources/CodexKit/Runtime/*Compaction*",
              "Tests/CodexKitTests/*Stress*", "Tests/CodexKitTests/*Performance*",
              "Tests/CodexKitTests/*Benchmark*", "Tests/CodexKitTests/*Cancellation*",
              "Package.*", ".github/*", "Scripts/*")
    demos = ("DemoApp/*", "Sources/CodexKit/Auth/*", "Sources/CodexKitUI/*",
             "Sources/CodexKit/Runtime/*Recovery*", "Sources/CodexKit/Runtime/*Session*",
             "Sources/CodexKit/Runtime/*Authentication*",
             "Package.*", ".github/*", "Scripts/*")
    matches = lambda patterns: force or any(fnmatch.fnmatch(path, pattern) for path in paths for pattern in patterns)
    return {"stress": matches(stress), "full_demos": matches(demos)}


def changed_paths(event, sha):
    base = event.get("pull_request", {}).get("base", {}).get("sha") or event.get("before")
    if not base or set(base) == {"0"}:
        base = subprocess.check_output(["git", "merge-base", "HEAD", "origin/main"], text=True).strip()
        if base == sha:
            base = subprocess.check_output(["git", "rev-parse", sha + "^"], text=True).strip()
    output = subprocess.check_output(["git", "diff", "--name-only", base, sha], text=True)
    return output.splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    options = parser.parse_args()
    sha = os.environ["GITHUB_SHA"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    scheduled = os.environ["GITHUB_EVENT_NAME"] == "schedule"
    force = options.force or scheduled or event.get("inputs", {}).get("extended") in (True, "true")
    proof = None
    if not force and os.environ["GITHUB_EVENT_NAME"] != "pull_request":
        try:
            proof, _ = find_evidence(GitHub(os.environ["GITHUB_REPOSITORY"]), sha, os.environ["GITHUB_RUN_ID"])
        except (EvidenceError, OSError, ValueError, KeyError) as error:
            # Missing/unreadable proof can only cause fresh tests, never a pass.
            print(f"No reusable verification ({type(error).__name__}); running fresh checks.")
    try:
        checks = extended_checks(changed_paths(event, sha), force)
    except subprocess.CalledProcessError:
        checks = extended_checks([], force=True)
    result = {"verify": proof is None, **checks, "evidence_url": proof["html_url"] if proof else ""}
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in result.items():
            output.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")
    print(json.dumps(result))
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"Commit `{sha}`: " + (f"reusing [verified CI]({proof['html_url']}).\n" if proof else "running fresh verification.\n"))


if __name__ == "__main__":
    main()
