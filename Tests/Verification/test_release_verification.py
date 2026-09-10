import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
import ci_evidence as evidence
import ci_plan
import release_gate
import verify_macos_demo

SHA = "a" * 40
REPOSITORY = "owner/library"


def run(run_id=1, **overrides):
    return dict(id=run_id, head_sha=SHA, workflow_id=17, path=".github/workflows/ci.yml",
                event="push", head_repository=dict(full_name=REPOSITORY),
                repository=dict(full_name=REPOSITORY), status="completed", conclusion="success",
                html_url=f"https://github.com/{REPOSITORY}/actions/runs/{run_id}", **overrides)


def jobs():
    return [dict(name=name, head_sha=SHA, status="completed", conclusion="success")
            for name in sorted(evidence.REQUIRED_JOBS)]


class FixtureAPI:
    repository = REPOSITORY

    def __init__(self, runs=None, job_sets=None):
        self.runs = runs if runs is not None else [run()]
        self.job_sets = job_sets if job_sets is not None else {1: jobs()}
        self.routes = []

    def get(self, route):
        if route != "/actions/workflows/ci.yml":
            raise AssertionError(route)
        return {"id": 17}

    def pages(self, route, field):
        self.routes.append(route)
        if field == "workflow_runs":
            if "head_sha=" + SHA not in route:
                raise AssertionError("Unscoped workflow lookup")
            return iter(self.runs)
        if not route.endswith("/jobs?filter=latest"):
            raise AssertionError("Jobs must come from the latest run attempt")
        return iter(self.job_sets[int(route.split("/")[3])])


class ExactCommitEvidenceTests(unittest.TestCase):
    def test_accepts_complete_exact_commit_without_starting_tests(self):
        api = FixtureAPI()
        proof, pending = evidence.find_evidence(api, SHA)
        self.assertEqual(proof["id"], 1)
        self.assertFalse(pending)
        self.assertEqual(len(api.routes), 2)

    def test_every_mandatory_job_must_execute_successfully(self):
        for name in evidence.REQUIRED_JOBS:
            for invalid in ("missing", "failure", "skipped", "cancelled", "timed_out", "pending", "duplicate", "wrong_sha"):
                with self.subTest(job=name, invalid=invalid):
                    values = jobs()
                    selected = next(j for j in values if j["name"] == name)
                    if invalid == "missing":
                        values.remove(selected)
                    elif invalid == "duplicate":
                        values.append(copy.deepcopy(selected))
                    elif invalid == "wrong_sha":
                        selected["head_sha"] = "b" * 40
                    elif invalid == "pending":
                        selected["status"] = "in_progress"
                    else:
                        selected["conclusion"] = invalid
                    self.assertIsNone(evidence.find_evidence(FixtureAPI(job_sets={1: values}), SHA)[0])

    def test_fork_pr_wrong_workflow_and_other_commits_cannot_certify_release(self):
        changes = [dict(head_sha="b" * 40), dict(workflow_id=99), dict(path=".github/workflows/other.yml"),
                   dict(event="pull_request"), dict(event="pull_request_target"),
                   dict(head_repository=dict(full_name="fork/library")), dict(repository=dict(full_name="fork/library")),
                   dict(head_repository=None)]
        for change in changes:
            with self.subTest(change=change):
                candidate = {**run(), **change}
                self.assertIsNone(evidence.find_evidence(FixtureAPI([candidate]), SHA)[0])

    def test_failed_latest_run_cannot_fall_back_to_an_old_pass(self):
        for failure in ("failure", "cancelled", "timed_out", "skipped", None):
            with self.subTest(failure=failure), self.assertRaises(evidence.EvidenceError):
                evidence.find_evidence(FixtureAPI([run(), {**run(2), "conclusion": failure}]), SHA)

    def test_pending_same_commit_can_reuse_an_existing_complete_proof(self):
        proof, pending = evidence.find_evidence(FixtureAPI([run(), {**run(2), "status": "in_progress"}]), SHA)
        self.assertTrue(pending)
        self.assertEqual(proof["id"], 1)

    def test_current_run_does_not_certify_itself(self):
        self.assertEqual(evidence.find_evidence(FixtureAPI(), SHA, exclude_run_id="1"), (None, False))

    def test_reuse_only_run_must_resolve_to_an_original_full_run(self):
        skipped = [{**job, "conclusion": "skipped"} for job in jobs()]
        api = FixtureAPI([run(2), run()], {1: jobs(), 2: skipped})
        self.assertEqual(evidence.find_evidence(api, SHA)[0]["id"], 1)
        self.assertIsNone(evidence.find_evidence(FixtureAPI([run(2)], {2: skipped}), SHA)[0])

    def test_optional_extended_failure_invalidates_evidence(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            values = jobs() + [dict(name="Extended stress", status="completed", conclusion=conclusion)]
            self.assertFalse(evidence.complete_jobs(values, SHA))
        self.assertTrue(evidence.complete_jobs(jobs() + [dict(name="Extended stress", status="completed", conclusion="skipped")], SHA))

    def test_api_failure_fails_release_closed(self):
        with patch.object(FixtureAPI, "get", side_effect=OSError("offline")), self.assertRaises(OSError):
            release_gate.require_evidence(FixtureAPI(), SHA)

    def test_missing_proof_does_not_wait_or_replace_verification(self):
        with patch.object(release_gate.time, "sleep") as sleep, self.assertRaises(evidence.EvidenceError):
            release_gate.require_evidence(FixtureAPI([]), SHA, wait_seconds=480)
        sleep.assert_not_called()

    def test_pending_verification_waits_and_then_requires_a_real_pass(self):
        clock = [0]
        with patch.object(release_gate, "find_evidence", side_effect=[(None, True), (run(), False)]), \
             patch.object(release_gate.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(release_gate.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            self.assertEqual(release_gate.require_evidence(FixtureAPI(), SHA, 20)["id"], 1)
        self.assertEqual(clock[0], 15)

    def test_missing_verification_is_dispatched_only_once_then_requires_a_pass(self):
        clock = [0]
        with patch.object(release_gate, "find_evidence", side_effect=[(None, False), (None, False), (run(), False)]), \
             patch.object(release_gate.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(release_gate.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
             patch.object(evidence.GitHub, "dispatch_ci") as dispatch:
            self.assertEqual(release_gate.require_evidence(FixtureAPI(), SHA, 60, dispatch)["id"], 1)
            dispatch.assert_called_once_with()

    def test_failed_verification_is_not_automatically_retried(self):
        api = FixtureAPI([{**run(), "conclusion": "failure"}])
        with patch.object(evidence.GitHub, "dispatch_ci") as dispatch, self.assertRaises(evidence.EvidenceError):
            release_gate.require_evidence(api, SHA, 60, dispatch)
        dispatch.assert_not_called()

    def test_pending_timeout_never_becomes_a_pass(self):
        clock = [0]
        with patch.object(release_gate, "find_evidence", return_value=(None, True)), \
             patch.object(release_gate.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(release_gate.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
             self.assertRaises(evidence.EvidenceError):
            release_gate.require_evidence(FixtureAPI(), SHA, 20)
        self.assertEqual(clock[0], 20)

    def test_full_commit_identity_is_required(self):
        for sha in ("main", "a" * 7, "../main", SHA + "\n"):
            with self.subTest(sha=sha), self.assertRaises(evidence.EvidenceError):
                evidence.find_evidence(FixtureAPI(), sha)

    def test_pagination_reads_all_pages_and_is_bounded(self):
        api = evidence.GitHub(REPOSITORY)
        with patch.object(api, "get", side_effect=[{"jobs": [{}] * 100}, {"jobs": [{}]}]):
            self.assertEqual(len(list(api.pages("/jobs", "jobs"))), 101)
        with patch.object(api, "get", return_value={"jobs": [{}] * 100}), self.assertRaises(evidence.EvidenceError):
            list(api.pages("/jobs", "jobs"))


class VerificationPlanningTests(unittest.TestCase):
    def test_documentation_change_keeps_extended_work_optional(self):
        self.assertEqual(ci_plan.extended_checks(["docs/guide.md"]), dict(stress=False, full_demos=False))

    def test_relevant_changes_and_force_select_extended_work(self):
        self.assertTrue(ci_plan.extended_checks(["Sources/CodexKitRealm/Store.swift"])["stress"])
        self.assertTrue(ci_plan.extended_checks(["Tests/CodexKitTests/RuntimeConcurrencyStressTests.swift"])["stress"])
        self.assertTrue(ci_plan.extended_checks(["DemoApp/CodexKitMacDemo/Model.swift"])["full_demos"])
        self.assertEqual(ci_plan.extended_checks([".github/workflows/ci.yml"]), dict(stress=True, full_demos=True))
        self.assertEqual(ci_plan.extended_checks([], force=True), dict(stress=True, full_demos=True))

    def test_api_error_makes_ci_run_fresh_instead_of_skipping(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / "event.json"
            event.write_text("{}")
            environment = dict(GITHUB_SHA=SHA, GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME="push",
                               GITHUB_REPOSITORY=REPOSITORY, GITHUB_RUN_ID="2", GITHUB_OUTPUT=str(root / "output"),
                               GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, environment), patch.object(sys, "argv", ["ci_plan"]), \
                 patch.object(ci_plan, "find_evidence", side_effect=OSError()), \
                 patch.object(ci_plan, "changed_paths", return_value=["docs/guide.md"]):
                ci_plan.main()
            self.assertIn("verify=true", (root / "output").read_text())


class ReleaseNotesAndTagTests(unittest.TestCase):
    def test_only_the_matching_nonempty_changelog_entry_is_published(self):
        changelog = "# Changes\n## [Unreleased]\nLater\n## [2.0.0-alpha.31] - today\nActual notes\n## [2.0.0-alpha.30]\nOld\n"
        self.assertEqual(release_gate.release_notes("v2.0.0-alpha.31", changelog), "Actual notes\n")
        for invalid in ("## [Unreleased]\nLater", "## [2.0.0-alpha.31]\n", changelog + "## [2.0.0-alpha.31]\nDuplicate"):
            with self.assertRaises(evidence.EvidenceError):
                release_gate.release_notes("v2.0.0-alpha.31", invalid)

    def test_invalid_tag_never_reaches_git(self):
        with patch.object(release_gate.subprocess, "check_output") as git:
            for tag in ("main", "--help", "v1.2.3; touch bad", "v1.2.3\n"):
                with self.subTest(tag=tag), self.assertRaises(evidence.EvidenceError):
                    release_gate.release_commit(tag)
            git.assert_not_called()

    def test_tag_must_resolve_to_a_commit_reachable_from_main(self):
        with patch.object(release_gate.subprocess, "check_output", return_value=SHA + "\n") as resolve, \
             patch.object(release_gate.subprocess, "run") as ancestry:
            self.assertEqual(release_gate.release_commit("v2.0.0-alpha.31"), SHA)
            self.assertIn("refs/tags/v2.0.0-alpha.31^{commit}", resolve.call_args.args[0])
            ancestry.assert_called_once_with(["git", "merge-base", "--is-ancestor", SHA, "origin/main"], check=True)
        with patch.object(release_gate.subprocess, "check_output", return_value=SHA), \
             patch.object(release_gate.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "git")), \
             self.assertRaises(subprocess.CalledProcessError):
            release_gate.release_commit("v2.0.0-alpha.31")


class MacDemoReportTests(unittest.TestCase):
    def test_wrong_phase_mode_or_run_cannot_reuse_a_previous_report(self):
        valid = dict(runID="current", mode="smoke", phase="reopen", passed=True, checks=["cold receipt"])
        verify_macos_demo.validate_report(valid, "current", "smoke", "reopen")
        for change in (dict(runID="old"), dict(mode="full"), dict(phase="initial"), dict(passed=False), dict(checks=[])):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                verify_macos_demo.validate_report({**valid, **change}, "current", "smoke", "reopen")


if __name__ == "__main__":
    unittest.main()
