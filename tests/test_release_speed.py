"""Faster releases: one Verify pass per commit, targeted test retries, fast-forward
landing, and preparation that overlaps Verify. No network, git remote or Xcode."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
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
shard = load("herdr_ci_unittest_shard", "scripts/ci-unittest-shard.py")
local_verify = load("herdr_local_verify", "scripts/local-verify.py")
policy = sys.modules["verification_policy"]
SHA = "b" * 40
REAL_LOCAL_STATUS = release.local_mac_status


def verify_runs(*runs):
    return json.dumps([{"headSha": SHA, **run} for run in runs])


class PreparationOverlapsVerifyTests(unittest.TestCase):
    def setUp(self):
        local = patch.object(release, "local_mac_status", return_value="success")
        self.local = local.start()
        self.addCleanup(local.stop)

    def test_preparation_starts_while_verify_runs_but_never_after_it_failed(self):
        for status, conclusion in (("queued", ""), ("in_progress", ""), ("completed", "success")):
            for local in ("none", "pending", "success"):
                self.local.return_value = local
                with patch.object(release, "gh", return_value=verify_runs({"status": status, "conclusion": conclusion})):
                    release.require_ci_not_failed(SHA)
        for local in ("failure", "error"):
            self.local.return_value = local
            with patch.object(release, "gh", return_value=verify_runs({"status": "in_progress", "conclusion": ""})):
                with self.assertRaises(release.ReleaseError):
                    release.require_ci_not_failed(SHA)
        self.local.return_value = "success"
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
            for local in ("none", "pending", "failure", "error"):
                self.local.return_value = local
                with self.subTest(local=local), self.assertRaises(release.ReleaseError):
                    release.require_green_ci(SHA)

    def test_the_local_mac_status_is_read_from_the_exact_commit(self):
        statuses = {"statuses": [{"context": "other", "state": "success"},
                                 {"context": "Mac tests (local)", "state": "failure"}]}
        with patch.object(release, "api", return_value=statuses) as api:
            self.assertEqual(REAL_LOCAL_STATUS(SHA), "failure")
        api.assert_called_once_with(f"commits/{SHA}/status")
        with patch.object(release, "api", return_value={"statuses": []}):
            self.assertEqual(REAL_LOCAL_STATUS(SHA), "none")

    def test_only_the_push_run_counts_because_the_pull_request_run_skips_tests(self):
        runs = verify_runs({"status": "completed", "conclusion": "success", "event": "pull_request"},
                           {"status": "in_progress", "conclusion": "", "event": "push"})
        with patch.object(release, "gh", return_value=runs) as gh:
            with self.assertRaises(release.ReleaseError):
                release.require_green_ci(SHA)
            release.wait_for_ci(SHA, 0)
        self.assertIn(("--event", "push"), list(zip(gh.call_args.args, gh.call_args.args[1:])))
        with patch.object(release, "gh", return_value=verify_runs({"status": "completed", "conclusion": "success", "event": "pull_request"})):
            with self.assertRaises(release.ReleaseError):
                release.require_ci_not_failed(SHA)

    def test_waiting_for_verify_stops_when_it_finishes_or_the_time_is_up(self):
        self.local.return_value = "pending"
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

    def test_waiting_also_covers_the_local_mac_tests(self):
        green = verify_runs({"status": "completed", "conclusion": "success"})
        locals_ = iter(["none", "pending", "success"])
        naps = []
        with patch.object(release, "gh", return_value=green), \
                patch.object(release, "local_mac_status", side_effect=lambda source: next(locals_)):
            release.wait_for_ci(SHA, 5, sleep=naps.append, clock=lambda: 0)
        self.assertEqual(naps, [30, 30])
        with patch.object(release, "gh", return_value=verify_runs({"status": "in_progress", "conclusion": ""})), \
                patch.object(release, "local_mac_status", return_value="failure"):
            naps.clear()
            release.wait_for_ci(SHA, 5, sleep=naps.append, clock=lambda: 0)
        self.assertEqual(naps, [], "a local failure ends the wait at once")

    def test_publish_accepts_a_wait_and_prepare_uses_the_overlapping_gate(self):
        parsed = []
        with patch.object(release, "publish", side_effect=parsed.append):
            self.assertEqual(release.main(["publish", "prepared.json", "--wait-for-ci", "40"]), 0)
        self.assertEqual(parsed[0].wait_for_ci, 40)
        source = (ROOT / "scripts/release-macos.py").read_text()
        self.assertIn("source = source_revision(); require_ci_not_failed(source)", source)


class VerifyPlanTests(unittest.TestCase):
    """Verify's plan, from synthetic runs and pull requests over a real temporary repository."""
    ENV = {"GITHUB_API_URL": "https://api.github.invalid", "GITHUB_REPOSITORY": "owner/synthetic",
           "WORKFLOW_FILE": "verify.yml", "GITHUB_RUN_ID": "7", "GITHUB_EVENT_NAME": "push", "HEAD_REPOSITORY": ""}

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name)
        self.run_git("init", "-q", "-b", "main")
        self.base = self.commit({"app.py": "print(1)\n"})
        self.docs = self.commit({"docs/guide.md": "# Guide\n", "release/macos.json": "{}\n", "NOTES.md": "x\n"})
        self.code = self.commit({"app.py": "print(2)\n"})
        self.runs: dict[str, list[dict]] = {}
        self.pulls: dict[str, list[dict]] = {}
        self.naps: list[float] = []

    def run_git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                               *arguments], capture_output=True, text=True)

    def commit(self, files):
        for name, text in files.items():
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / name).write_text(text)
        self.run_git("add", "-A")
        self.run_git("commit", "-q", "-m", "synthetic")
        return self.run_git("rev-parse", "HEAD").stdout.strip()

    def fetch(self, url):
        if "/actions/workflows/" in url:
            sha = url.split("head_sha=")[1].split("&")[0]
            answers = self.runs.get(sha, [])
            # A list of answers plays out one poll at a time.
            return {"workflow_runs": answers.pop(0) if answers and isinstance(answers[0], list) else answers}
        if url.endswith("/pulls"):
            return self.pulls.get(url.split("/commits/")[1].split("/")[0], [])
        if "/git/commits/" in url:
            return {"tree": {"sha": self.run_git("rev-parse", url.rsplit("/", 1)[1] + "^{tree}").stdout.strip()}}
        raise AssertionError(url)

    @staticmethod
    def passed(sha, **extra):
        return {"id": 3, "head_sha": sha, "event": "push", "status": "completed", "conclusion": "success",
                "html_url": "https://runs.invalid/3", **extra}

    def plan(self, sha, **env):
        return ci_plan.plan({**self.ENV, "GITHUB_SHA": sha, **env}, fetch=self.fetch, run_git=self.run_git,
                            sleep=self.naps.append, clock=lambda: len(self.naps) * ci_plan.POLL_SECONDS)

    def test_a_same_repository_pull_request_leaves_everything_to_its_push_run(self):
        env = {"GITHUB_EVENT_NAME": "pull_request", "HEAD_REPOSITORY": "owner/synthetic"}
        self.assertEqual({k: v for k, v in self.plan(self.code, **env).items() if k != "reason"},
                         {"tests": False, "privacy": False})
        fork = self.plan(self.code, GITHUB_EVENT_NAME="pull_request", HEAD_REPOSITORY="someone/fork")
        self.assertEqual((fork["tests"], fork["privacy"]), (True, True))

    def test_a_commit_that_already_passed_on_a_push_is_not_checked_again(self):
        self.runs[self.code] = [self.passed(self.code)]
        result = self.plan(self.code)
        self.assertEqual((result["tests"], result["privacy"]), (False, False))
        self.assertIn("https://runs.invalid/3", result["reason"])
        # This run itself, a pull request run, or another commit never counts.
        for other in ({"id": 7}, {"event": "pull_request"}, {"head_sha": "c" * 40}):
            self.runs[self.code] = [self.passed(self.code, **other)]
            self.assertTrue(self.plan(self.code)["privacy"])

    def test_docs_and_release_metadata_reuse_the_parents_tests_but_are_still_scanned(self):
        self.runs[self.base] = [self.passed(self.base)]
        result = self.plan(self.docs)
        self.assertEqual((result["tests"], result["privacy"]), (False, True))
        self.assertIn("only docs or release metadata changed", result["reason"])
        self.runs[self.base] = [self.passed(self.base, conclusion="failure")]
        self.assertTrue(self.plan(self.docs)["tests"], "an untested parent is no evidence")
        self.runs[self.docs] = [self.passed(self.docs)]
        self.assertTrue(self.plan(self.code)["tests"], "a code change always runs the tests")

    def test_a_parent_still_being_checked_is_waited_for(self):
        running = self.passed(self.base, status="in_progress", conclusion=None)
        self.runs[self.base] = [[running], [running], [self.passed(self.base)]]
        self.assertFalse(self.plan(self.docs)["tests"])
        self.assertEqual(self.naps, [ci_plan.POLL_SECONDS] * 2)
        self.naps.clear()
        self.runs[self.base] = [[running], [self.passed(self.base, conclusion="failure")]]
        self.assertTrue(self.plan(self.docs)["tests"])
        self.naps.clear()
        self.runs[self.base] = [running]  # never finishes: the wait is bounded
        self.assertTrue(self.plan(self.docs)["tests"])
        self.assertEqual(len(self.naps), ci_plan.PARENT_WAIT_SECONDS // ci_plan.POLL_SECONDS)

    def test_a_squash_merge_of_a_passed_head_with_the_same_tree_is_not_tested_again(self):
        head = self.code
        self.run_git("reset", "-q", "--hard", self.docs)
        squash = self.run_git("commit-tree", head + "^{tree}", "-p", self.docs, "-m", "squash").stdout.strip()
        self.pulls[squash] = [{"merge_commit_sha": squash, "merged_at": "2026-01-01T00:00:00Z", "head": {"sha": head}}]
        self.runs[head] = [self.passed(head)]
        result = self.plan(squash)
        self.assertEqual((result["tests"], result["privacy"]), (False, True))
        self.assertIn(f"same code as {head[:12]}", result["reason"])
        other = self.run_git("commit-tree", self.base + "^{tree}", "-p", self.docs, "-m", "different").stdout.strip()
        self.pulls[other] = [{"merge_commit_sha": other, "merged_at": "2026-01-01T00:00:00Z", "head": {"sha": head}}]
        self.assertTrue(self.plan(other)["tests"], "a different tree is different code")
        self.pulls[squash][0]["merged_at"] = None
        self.assertTrue(self.plan(squash)["tests"], "only a merged pull request counts")

    def test_merges_and_lookup_failures_always_run_the_tests(self):
        self.run_git("checkout", "-q", "-b", "side", self.base)
        side = self.commit({"docs/other.md": "# Other\n"})
        self.run_git("checkout", "-q", "main")
        self.run_git("merge", "-q", "--no-ff", "-m", "merge", side)
        merge = self.run_git("rev-parse", "HEAD").stdout.strip()
        self.runs[self.code] = [self.passed(self.code)]
        self.assertTrue(self.plan(merge)["tests"])

        def broken(url):
            if "/pulls" in url:
                raise OSError("synthetic outage")
            return self.fetch(url)
        result = ci_plan.plan({**self.ENV, "GITHUB_SHA": self.docs}, fetch=broken, run_git=self.run_git)
        self.assertEqual((result["tests"], result["privacy"]), (True, True))


class PolicyTests(unittest.TestCase):
    def test_only_files_no_build_or_test_reads_count_as_untested(self):
        self.assertTrue(policy.untested_only(["docs/a.md", "design/x/index.html", "release/notes/macos-1.md",
                                               "release/macos.json", "README.md"]))
        for path in ("herdr_harness/server.py", "pi-semantic-bridge/agent-docs/overview.md", "release/other.json",
                     "tests/test_x.py", "herdr-harness-mac/App.swift", ".github/workflows/verify.yml"):
            with self.subTest(path=path):
                self.assertFalse(policy.untested_only(["docs/a.md", path]))
        self.assertFalse(policy.untested_only([]), "an empty change proves nothing")

    def test_ios_paths_cover_everything_the_ios_app_builds_from(self):
        for path in ("herdr-harness-ios/App.swift", "HerdrFirstMateShared/Skim.swift", "HerdrFirstMateSharedTests/T.swift"):
            self.assertTrue(policy.IOS_PATHS.match(path))
        self.assertFalse(policy.IOS_PATHS.match("herdr-harness-mac/App.swift"))


class FakeStatuses:
    """GitHub as local-verify.py sees it: commit statuses, merged pull requests and trees."""

    def __init__(self, repo_git):
        self.states: dict[str, str] = {}
        self.posts: list[tuple[str, str, str]] = []
        self.pulls: dict[str, list[str]] = {}
        self.unknown: set[str] = set()
        self._git = repo_git

    def state(self, sha):
        if sha in self.unknown:
            raise local_verify.VerifyError("gh api failed: No commit found")
        return self.states.get(sha, "none")

    def post(self, sha, state, description):
        self.posts.append((sha, state, description))
        self.states[sha] = state

    def pull_heads(self, sha):
        return self.pulls.get(sha, [])

    def tree(self, sha):
        return self._git("rev-parse", sha + "^{tree}").stdout.strip()


class LocalVerifyTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.base = self.commit({"app.py": "print(1)\n"})
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.docs = self.commit({"docs/guide.md": "# Guide\n"})
        self.ios = self.commit({"herdr-harness-ios/App.swift": "// app\n"})
        self.github = FakeStatuses(self.git)
        self.tested: list[tuple[str, bool]] = []
        self.outcome = (True, "Mac tests (iOS unchanged) passed in 5m 00s", {"log": "log", "excerpt": ""})
        for name, value in (("repo_git", self.git), ("CACHE", Path(directory.name) / "cache"), ("test", self.fake_test)):
            patcher = patch.object(local_verify, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                               *arguments], capture_output=True, text=True)

    def commit(self, files):
        for name, text in files.items():
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / name).write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "synthetic")
        return self.git("rev-parse", "HEAD").stdout.strip()

    def fake_test(self, sha, ios):
        self.tested.append((sha, ios))
        if isinstance(self.outcome, BaseException):
            raise self.outcome
        return self.outcome

    def test_a_new_commit_is_tested_and_its_result_posted(self):
        result = local_verify.verify(self.docs, github=self.github)
        self.assertTrue(result["ok"])
        self.assertEqual(self.tested, [(self.docs, False)])
        self.assertEqual([post[1] for post in self.github.posts], ["pending", "success"])
        self.assertEqual(self.github.posts[-1][2], "Mac tests (iOS unchanged) passed in 5m 00s")

    def test_a_failure_is_posted_with_an_excerpt_for_the_caller(self):
        self.outcome = (False, "Mac tests (iOS unchanged) failed in 7m 00s", {"log": "log", "excerpt": "✘ Test boom"})
        result = local_verify.verify(self.base, github=self.github)
        self.assertEqual((result["ok"], result["state"], result["excerpt"]), (False, "failure", "✘ Test boom"))
        self.assertEqual(self.github.states[self.base], "failure")

    def test_code_that_already_passed_is_not_tested_again(self):
        self.github.states[self.base] = "success"
        result = local_verify.verify(self.docs, github=self.github)
        self.assertEqual((result["ok"], self.tested), (True, []))
        self.assertEqual(self.github.posts[-1][:2], (self.docs, "success"))
        self.assertIn("only docs or release metadata changed", self.github.posts[-1][2])
        self.github.posts.clear()
        self.assertTrue(local_verify.verify(self.docs, github=self.github)["ok"])
        self.assertEqual(self.github.posts, [], "an existing success is left as it is")
        local_verify.verify(self.docs, force=True, github=self.github)
        self.assertEqual(self.tested, [(self.docs, False)], "--force always tests")

    def test_a_failed_or_changed_commit_is_tested_again(self):
        self.github.states[self.base] = "failure"
        local_verify.verify(self.docs, github=self.github)
        self.assertEqual(self.tested, [(self.docs, False)])

    def test_an_interrupted_run_never_stays_pending(self):
        for error, description in ((OSError("synthetic"), "Could not run the tests"),
                                   (KeyboardInterrupt(), "Stopped before finishing")):
            self.outcome = error
            with self.subTest(error=error), self.assertRaises(type(error)):
                local_verify.verify(self.base, github=self.github)
            self.assertEqual(self.github.posts[-1], (self.base, "error", description))

    def test_an_unpushed_commit_is_refused_unless_nothing_is_posted(self):
        self.github.unknown.add(self.base)
        with self.assertRaisesRegex(local_verify.VerifyError, "push it first"):
            local_verify.verify(self.base, github=self.github)
        self.assertEqual(self.tested, [])
        self.assertTrue(local_verify.verify(self.base, post=False, force=True, github=self.github)["ok"])
        self.assertEqual(self.github.posts, [])

    def test_ios_runs_only_when_the_branch_changed_what_the_ios_app_builds_from(self):
        self.assertFalse(local_verify.ios_required(self.docs, "auto", self.git))
        self.assertTrue(local_verify.ios_required(self.ios, "auto", self.git))
        self.git("update-ref", "refs/remotes/origin/main", self.ios)
        self.assertFalse(local_verify.ios_required(self.docs, "auto", self.git), "a commit on main is judged by its own change")
        self.assertTrue(local_verify.ios_required(self.ios, "auto", self.git))
        self.assertTrue(local_verify.ios_required(self.docs, "always", self.git))
        self.assertFalse(local_verify.ios_required(self.ios, "never", self.git))

    def test_the_failure_excerpt_hides_local_paths(self):
        log = self.repo / "run.log"
        source = self.repo / "checkout"
        log.write_text(f"compiling\n{source}/App.swift:3: error: boom\n{Path.home()}/x ✘ Test broken\nfinished\n")
        text = local_verify.excerpt(log, source)
        self.assertIn("<checkout>/App.swift:3: error: boom", text)
        self.assertIn("~/x ✘ Test broken", text)
        self.assertNotIn(str(Path.home()), text)

    def test_the_public_description_names_no_machine_or_path(self):
        source = (ROOT / "scripts/local-verify.py").read_text()
        self.assertIn('description[:140]', source)
        self.assertIn('"Running on a Mac"', source)


class ShardTests(unittest.TestCase):
    def test_every_module_runs_in_exactly_one_shard_with_balanced_time(self):
        modules = sorted((ROOT / "tests").glob("test*.py"))
        weights = shard.load_weights()
        self.assertTrue(weights, "the committed weights file loads")
        split = shard.shards(modules, 3, weights)
        names = [name for group in split for name in group]
        self.assertEqual(sorted(names), sorted(path.stem for path in modules))
        self.assertEqual(len(names), len(set(names)))
        cost = shard.estimates(modules, weights)
        totals = [sum(cost[name] for name in group) for group in split]
        self.assertLess(max(totals) - min(totals), max(cost.values()))

    def test_a_module_without_a_measurement_is_estimated_from_its_size(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for name, size in (("test_a", 100), ("test_b", 300), ("test_new", 200)):
                path = Path(directory) / f"{name}.py"
                path.write_text("x" * size)
                paths.append(path)
            cost = shard.estimates(paths, {"test_a": 1.0, "test_b": 3.0})
            self.assertAlmostEqual(cost["test_new"], 2.0)
            self.assertEqual(shard.shards(paths, 2, {"test_a": 1.0, "test_b": 3.0}), [["test_b"], ["test_a", "test_new"]])

    def test_the_workflow_runs_every_shard(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertIn("shard: [1, 2, 3]", workflow)
        self.assertIn("ci-unittest-shard.py ${{ matrix.shard }} 3", workflow)


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

    def fake(self, *, pr=None, behind=False, runs=None, local="success"):
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
            if arguments[:2] == ["gh", "api"] and arguments[2].endswith(f"/commits/{SHA}/status"):
                return json.dumps({"statuses": [{"context": "Mac tests (local)", "state": local}] if local else []})
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
            {"local": None}, {"local": "pending"}, {"local": "failure"},
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
