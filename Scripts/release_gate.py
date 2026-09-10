#!/usr/bin/env python3
"""Publish only commits with successful, complete, same-repository CI evidence."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import time

from ci_evidence import EvidenceError, GitHub, find_evidence


def release_commit(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?", tag):
        raise EvidenceError("Invalid release tag")
    sha = subprocess.check_output(["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"], text=True).strip()
    subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], check=True)
    return sha


def release_notes(tag, changelog):
    marker = "## [" + tag.removeprefix("v") + "]"
    lines = changelog.splitlines()
    matches = [i for i, line in enumerate(lines) if line == marker or line.startswith(marker + " - ")]
    if len(matches) != 1:
        raise EvidenceError("Release needs exactly one matching changelog entry")
    start = matches[0] + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    notes = "\n".join(lines[start:end]).strip()
    if not notes:
        raise EvidenceError("Empty release notes")
    return notes + "\n"


def require_evidence(api, sha, wait_seconds=0, start_verification=None):
    deadline = time.monotonic() + wait_seconds
    dispatched = False
    while True:
        proof, pending = find_evidence(api, sha)
        if proof:
            return proof
        remaining = deadline - time.monotonic()
        if not pending and not dispatched and start_verification and remaining > 0:
            start_verification()
            dispatched = True
            print("Started one verification run for the tagged commit.", flush=True)
        if (not pending and not dispatched) or remaining <= 0:
            raise EvidenceError("No complete passing CI for the exact tagged commit. Run CI, then retry publication; no tests were skipped or assumed successful.")
        print("Waiting for existing verification of the tagged commit.", flush=True)
        time.sleep(min(15, remaining))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--wait-seconds", type=int, default=480)
    args = parser.parse_args()
    if not 0 <= args.wait_seconds <= 480:
        parser.error("--wait-seconds must be between 0 and 480")
    sha = release_commit(args.tag)
    changelog = subprocess.check_output(["git", "show", f"{sha}:CHANGELOG.md"], text=True)
    notes = release_notes(args.tag, changelog)
    api = GitHub(os.environ["GITHUB_REPOSITORY"])
    proof = require_evidence(api, sha, args.wait_seconds, lambda: api.dispatch_ci(args.tag))
    # Pin the object identity again before handing publication to the next job.
    if release_commit(args.tag) != sha:
        raise EvidenceError("Release tag changed during verification")
    Path(os.environ["RUNNER_TEMP"], "release-notes.md").write_text(notes)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"sha={sha}\nevidence_url={proof['html_url']}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"Release `{args.tag}` → `{sha}`. Reusing [complete verification]({proof['html_url']}); no rebuild.\n")
    print(f"Verified {args.tag} at {sha}: {proof['html_url']}")


if __name__ == "__main__":
    main()
