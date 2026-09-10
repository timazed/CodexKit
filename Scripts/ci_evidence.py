#!/usr/bin/env python3
"""Read exact-commit verification evidence. Cached builds are never test evidence."""
import json
import os
import re
import urllib.parse
import urllib.request

WORKFLOW = "ci.yml"
REQUIRED_JOBS = frozenset({
    "SDK (current)", "SDK (minimum)", "SDK (optimized)", "Demo (iOS)", "Demo (macOS)",
    "Build iOS 17 verifier", "Demo (iOS 17)", "Verification gate v1",
})


class EvidenceError(RuntimeError):
    pass


class GitHub:
    def __init__(self, repository, token=None):
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
            raise EvidenceError("Invalid repository name")
        self.repository = repository
        self.base = "https://api.github.com/repos/" + repository
        self.token = token or os.environ.get("GH_TOKEN")

    def get(self, route):
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.base + route, headers=headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    def dispatch_ci(self, tag):
        if not self.token:
            raise EvidenceError("A repository Actions token is required to start verification")
        request = urllib.request.Request(self.base + "/actions/workflows/ci.yml/dispatches",
            data=json.dumps({"ref": tag, "inputs": {"extended": False}}).encode(),
            headers={"Accept": "application/vnd.github+json", "Authorization": "Bearer " + self.token,
                     "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status != 204:
                raise EvidenceError("GitHub did not acknowledge verification dispatch")

    def pages(self, route, field):
        separator = "&" if "?" in route else "?"
        for page in range(1, 11):
            data = self.get(f"{route}{separator}per_page=100&page={page}")
            values = data[field]
            yield from values
            if len(values) < 100:
                return
        raise EvidenceError("Verification evidence exceeds the pagination bound")


def trusted_run(run, repository, sha, workflow_id, exclude_run_id=None):
    return (str(run.get("id")) != str(exclude_run_id)
            and run.get("head_sha") == sha
            and run.get("workflow_id") == workflow_id
            and run.get("path") == ".github/workflows/ci.yml"
            and run.get("event") in {"push", "workflow_dispatch", "schedule"}
            and (run.get("head_repository") or {}).get("full_name") == repository
            and (run.get("repository") or {}).get("full_name") == repository)


def complete_jobs(jobs, sha):
    """All mandatory jobs must actually run; reuse-only runs cannot certify themselves."""
    by_name = {}
    for job in jobs:
        by_name.setdefault(job.get("name"), []).append(job)
    for name in REQUIRED_JOBS:
        matches = by_name.get(name, [])
        if len(matches) != 1:
            return False
        job = matches[0]
        if job.get("head_sha") != sha or job.get("status") != "completed" or job.get("conclusion") != "success":
            return False
    # Extended jobs are conditional, but any attempted failure invalidates the run.
    return all(job.get("status") == "completed" and job.get("conclusion") in {"success", "skipped"}
               for job in jobs)


def find_evidence(api, sha, exclude_run_id=None):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise EvidenceError("Verification requires a full commit SHA")
    workflow = api.get("/actions/workflows/" + WORKFLOW)
    route = "/actions/workflows/" + str(workflow["id"]) + "/runs?" + urllib.parse.urlencode({"head_sha": sha})
    runs = sorted(api.pages(route, "workflow_runs"), key=lambda run: run["id"], reverse=True)
    pending = False
    for run in runs:
        if not trusted_run(run, api.repository, sha, workflow["id"], exclude_run_id):
            continue
        if run.get("status") != "completed":
            pending = True
            continue
        if run.get("conclusion") != "success":
            # Do not fall back to an older pass after a later failure/cancellation.
            raise EvidenceError("The latest completed verification did not pass: " + str(run["id"]))
        jobs = list(api.pages(f"/actions/runs/{run['id']}/jobs?filter=latest", "jobs"))
        if complete_jobs(jobs, sha):
            return run, pending
        # A successful reuse-only workflow has skipped mandatory jobs. Find its original proof.
    return None, pending
