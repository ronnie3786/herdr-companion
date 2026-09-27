"""Faster releases: one Verify pass per commit, targeted test retries, fast-forward
landing, and preparation that overlaps Verify. No network, git remote or Xcode."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("herdr_release_macos_speed", "scripts/release-macos.py")
ci_plan = load("herdr_ci_plan", "scripts/ci-plan.py")
ci_xcode = load("herdr_ci_xcode_test", "scripts/ci-xcode-test.py")
land_pr = load("herdr_land_pr", "scripts/land-pr.py")
SHA = "b" * 40


def verify_runs(*runs):
    return json.dumps([{"headSha": SHA, **run} for run in runs])


class PreparationOverlapsVerifyTests(unittest.TestCase):
    def test_preparation_starts_while_verify_runs_but_never_after_it_failed(self):
        for status, conclusion in (("queued", ""), ("in_progress", ""), ("completed", "success")):
            with patch.object(release, "gh", return_value=verify_runs({"status": status, "conclusion": conclusion})):
                release.require_ci_not_failed(SHA)
        for runs in (verify_runs({"status": "completed", "conclusion": "failure"}), "[]",
                     json.dumps([{"headSha": "c" * 40, "status": "completed", "conclusion": "success"}])):
            with patch.object(release, "gh", return_value=runs), self.assertRaises(release.ReleaseError):
                release.require_ci_not_failed(SHA)

    def test_publication_still_requires_the_latest_run_to_have_passed(self):
        with patch.object(release, "gh", return_value=verify_runs({"status": "in_progress", "conclusion": ""})):
            with self.assertRaises(release.ReleaseError):
                release.require_green_ci(SHA)
        with patch.object(release, "gh", return_value=verify_runs({"status": "completed", "conclusion": "success"})):
            release.require_green_ci(SHA)

    def test_waiting_for_verify_stops_when_it_finishes_or_the_time_is_up(self):
        answers = iter([verify_runs({"status": "in_progress", "conclusion": ""}),
                        verify_runs({"status": "completed", "conclusion": "failure"})])
        naps = []
        with patch.object(release, "gh", side_effect=lambda *args: next(answers)):
            release.wait_for_ci(SHA, 5, sleep=naps.append, clock=lambda: 0)
        self.assertEqual(naps, [30])
        now = iter(range(0, 10_000, 100))
        with patch.object(release, "gh", return_value=verify_runs({"status": "in_progress", "conclusion": ""})) as gh:
            release.wait_for_ci(SHA, 5, sleep=lambda seconds: None, clock=lambda: next(now))
        self.assertEqual(gh.call_count, 2)

    def test_publish_accepts_a_wait_and_prepare_uses_the_overlapping_gate(self):
        parsed = []
        with patch.object(release, "publish", side_effect=parsed.append):
            self.assertEqual(release.main(["publish", "prepared.json", "--wait-for-ci", "40"]), 0)
        self.assertEqual(parsed[0].wait_for_ci, 40)
        source = (ROOT / "scripts/release-macos.py").read_text()
        self.assertIn("source = source_revision(); require_ci_not_failed(source)", source)


class VerifyPlanTests(unittest.TestCase):
    ENV = {"GITHUB_API_URL": "https://api.github.invalid", "GITHUB_REPOSITORY": "owner/synthetic",
           "WORKFLOW_FILE": "verify.yml", "GITHUB_SHA": SHA, "GITHUB_RUN_ID": "7", "DEFAULT_BRANCH": "main",
           "BASE_REF": "", "BEFORE": "", "HEAD_REPOSITORY": ""}

    @staticmethod
    def git(changed: str = "", *, ok: bool = True):
        calls = []

        def run(*arguments):
            calls.append(arguments)
            output = changed if arguments[0] == "diff" else ""
            return subprocess.CompletedProcess(arguments, 0 if ok else 1, output, "")
        return run, calls

    @staticmethod
    def runs(*items):
        return lambda url: {"workflow_runs": list(items)}

    def test_a_same_repository_pull_request_leaves_verification_to_its_push_run(self):
        env = {**self.ENV, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_REF_NAME": "5/merge",
               "BASE_REF": "main", "HEAD_REPOSITORY": "owner/synthetic"}
        run, _ = self.git()
        self.assertFalse(ci_plan.plan(env, fetch=self.runs(), run_git=run)["run"])
        fork = {**env, "HEAD_REPOSITORY": "someone/fork"}
        run, calls = self.git("herdr-harness-ios/App.swift\n")
        result = ci_plan.plan(fork, fetch=self.runs(), run_git=run)
        self.assertEqual((result["run"], result["ios"]), (True, True))
        self.assertIn(("diff", "--name-only", "origin/main...HEAD"), calls)

    def test_a_commit_that_already_passed_on_a_push_is_not_tested_again(self):
        env = {**self.ENV, "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "main", "BEFORE": "a" * 40}
        run, _ = self.git()
        earlier = {"id": 3, "head_sha": SHA, "event": "push", "conclusion": "success", "html_url": "https://runs.invalid/3"}
        result = ci_plan.plan(env, fetch=self.runs(earlier), run_git=run)
        self.assertFalse(result["run"])
        self.assertIn("https://runs.invalid/3", result["reason"])
        # This run itself, a pull request run, or another commit never counts.
        for other in ({**earlier, "id": 7}, {**earlier, "event": "pull_request"}, {**earlier, "head_sha": "c" * 40}):
            self.assertTrue(ci_plan.plan(env, fetch=self.runs(other), run_git=run)["run"])

    def test_a_branch_push_decides_ios_from_the_whole_branch(self):
        env = {**self.ENV, "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "feature/x", "BEFORE": "a" * 40}
        run, calls = self.git("herdr-harness-mac/App.swift\nherdr_harness/server.py\n")
        result = ci_plan.plan(env, fetch=self.runs(), run_git=run)
        self.assertEqual((result["run"], result["ios"]), (True, False))
        self.assertIn(("diff", "--name-only", "origin/main...HEAD"), calls)
        run, _ = self.git("HerdrFirstMateShared/FirstMateSkim.swift\n")
        self.assertTrue(ci_plan.plan(env, fetch=self.runs(), run_git=run)["ios"])

    def test_the_default_branch_uses_its_pushed_range_and_fails_open(self):
        env = {**self.ENV, "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "main", "BEFORE": "a" * 40}
        run, calls = self.git("docs/overview.md\n")
        self.assertFalse(ci_plan.plan(env, fetch=self.runs(), run_git=run)["ios"])
        self.assertIn(("diff", "--name-only", "a" * 40 + "..HEAD"), calls)
        run, _ = self.git(ok=False)
        self.assertTrue(ci_plan.plan(env, fetch=self.runs(), run_git=run)["ios"])


def result_tree(*cases, suite_failed=None):
    """A synthetic `xcresulttool get test-results tests` document."""
    return {"testNodes": [{"nodeType": "Test Plan", "name": "plan", "result": "Failed", "children": [{
        "nodeType": "Unit test bundle", "name": "synthetic-tests", "result": "Failed", "children": [
            {"nodeType": "Test Suite", "name": "Suite", "result": suite_failed or "Passed",
             "children": [{"nodeType": "Test Case", "nodeIdentifier": identifier, "result": result,
                           "children": [{"nodeType": "Arguments", "name": ".a", "result": result}]}
                          for identifier, result in cases]}]}]}]}


class TargetedRetryTests(unittest.TestCase):
    def test_failed_cases_are_named_with_their_bundle(self):
        failed, complete = ci_xcode.failed_tests(result_tree(("Suite/flaky(route:)", "Failed"), ("Suite/fine()", "Passed")))
        self.assertEqual(failed, ["synthetic-tests/Suite/flaky(route:)"])
        self.assertTrue(complete)
        _, complete = ci_xcode.failed_tests(result_tree(("Suite/fine()", "Passed"), suite_failed="Failed"))
        self.assertFalse(complete)

    def run_main(self, results, statuses):
        calls = []

        def xcodebuild(arguments):
            calls.append(arguments)
            return statuses[len(calls) - 1]
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(ci_xcode, "xcodebuild", side_effect=xcodebuild), \
                patch.object(ci_xcode, "read_results", return_value=results):
            status = ci_xcode.main(["--result-dir", directory, "--", "-project", "Synthetic.xcodeproj",
                                    "-only-testing:synthetic-tests"])
        return status, calls

    def test_only_the_failed_tests_run_again(self):
        status, calls = self.run_main(result_tree(("Suite/flaky(route:)", "Failed")), [65, 0])
        self.assertEqual(status, 0)
        self.assertIn("test", calls[0])
        self.assertIn("-only-testing:synthetic-tests", calls[0])
        self.assertIn("test-without-building", calls[1])
        self.assertIn("-only-testing:synthetic-tests/Suite/flaky(route:)", calls[1])
        self.assertNotIn("-only-testing:synthetic-tests", calls[1])

    def test_breaks_crashes_and_build_failures_are_never_retried(self):
        many = result_tree(*[(f"Suite/t{index}()", "Failed") for index in range(ci_xcode.MAX_RETRIED + 1)])
        for results in (many, result_tree(("Suite/fine()", "Passed"), suite_failed="Failed"), None):
            status, calls = self.run_main(results, [65])
            self.assertEqual((status, len(calls)), (65, 1))
        status, calls = self.run_main(result_tree(("Suite/broken()", "Failed")), [65, 65])
        self.assertEqual((status, len(calls)), (65, 2))


class LandTests(unittest.TestCase):
    PR = {"state": "OPEN", "isDraft": False, "baseRefName": "main", "headRefName": "fix/x", "headRefOid": SHA,
          "isCrossRepository": False, "url": "https://github.invalid/pull/9"}

    def fake(self, *, pr=None, behind=False, runs=None):
        calls = []

        def run(arguments):
            calls.append(arguments)
            if arguments[:3] == ["gh", "pr", "view"] and "state" == arguments[-1]:
                return json.dumps({"state": "MERGED"})
            if arguments[:3] == ["gh", "pr", "view"]:
                return json.dumps(pr or self.PR)
            if arguments[:3] == ["gh", "repo", "view"]:
                return "main\n"
            if arguments[:2] == ["git", "rev-parse"]:
                return SHA + "\n"
            if arguments[:2] == ["git", "merge-base"] and behind:
                raise land_pr.LandError("not an ancestor")
            if arguments[:3] == ["gh", "run", "list"]:
                return verify_runs(*(runs or [{"status": "completed", "conclusion": "success", "url": "https://runs.invalid/1"}]))
            return ""
        return run, calls

    def test_a_verified_branch_fast_forwards_the_default_branch(self):
        run, calls = self.fake()
        result = land_pr.land(9, delete_branch=True, run=run, sleep=lambda seconds: None)
        self.assertEqual((result["landed"], result["state"]), (SHA, "MERGED"))
        self.assertIn(["git", "push", "--quiet", "origin", f"{SHA}:refs/heads/main"], calls)
        self.assertIn(["git", "push", "--quiet", "origin", "--delete", "fix/x"], calls)
        self.assertFalse(any("--force" in call or "-f" in call for call in calls))
        listed = next(call for call in calls if call[:3] == ["gh", "run", "list"])
        self.assertEqual(listed[listed.index("--event") + 1], "push")

    def test_nothing_lands_without_an_up_to_date_verified_ready_branch(self):
        cases = [
            {"behind": True},
            {"runs": [{"status": "in_progress", "conclusion": "", "url": "u"}]},
            {"runs": [{"status": "completed", "conclusion": "failure", "url": "u"}]},
            {"pr": {**self.PR, "isDraft": True}},
            {"pr": {**self.PR, "isCrossRepository": True}},
            {"pr": {**self.PR, "baseRefName": "release"}},
        ]
        for case in cases:
            run, calls = self.fake(**case)
            with self.subTest(case=case), self.assertRaises(land_pr.LandError):
                land_pr.land(9, run=run, sleep=lambda seconds: None)
            self.assertFalse(any(call[:2] == ["git", "push"] for call in calls))


if __name__ == "__main__":
    unittest.main()
