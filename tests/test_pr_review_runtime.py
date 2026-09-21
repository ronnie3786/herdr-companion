"""Focused behavior checks for the PR-review runtime's public surface."""
from __future__ import annotations

import json
import shlex
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from herdr_harness.pr_review_runtime import PRReviewRuntime
from herdr_harness.pr_review_store import PRReviewError, PRReviewStore


class _Result:
    def __init__(self, stdout: str = "", returncode: int = 0, stderr: str = "") -> None:
        self.stdout = stdout
        self.returncode = returncode
        self.stderr = stderr


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[list[str], dict]] = []
        self.on_call = None

    def __call__(self, argv, **kwargs):
        self.calls.append((list(argv), kwargs))
        self.assert_safe_environment(kwargs["env"])
        if self.on_call:
            result = self.on_call(argv, kwargs)
            if result is not None:
                return result
        if argv[:3] == ["gh", "pr", "view"]:
            return _Result(json.dumps({"number": 42, "url": "https://github.com/example-owner/garden/pull/42", "state": "OPEN", "title": "Garden update", "body": "Synthetic body", "author": {"login": "example-author"}, "baseRefName": "main", "headRefName": "feature", "headRefOid": "head", "baseRefOid": "base", "isDraft": False, "additions": 4, "deletions": 1, "changedFiles": 1, "files": [], "id": "PR_node"}))
        if argv[:3] == ["gh", "api", "graphql"]:
            self._assert_graphql_fields(argv)
            return _Result(json.dumps({
                "data": {
                    "repository": {
                        "pullRequest": {
                            "files": {
                                "nodes": [{"path": "Sources/Garden.swift", "viewerViewedState": "VIEWED"}],
                                "pageInfo": {"hasNextPage": False, "endCursor": None},
                            }
                        }
                    }
                }
            }))
        if "merge-base" in argv:
            return _Result("base\n")
        if "diff" in argv:
            return _Result("diff --git a/Sources/Garden.swift b/Sources/Garden.swift\n--- a/Sources/Garden.swift\n+++ b/Sources/Garden.swift\n@@ -1 +1 @@\n-old\n+new\n")
        if "show" in argv:
            return _Result("one\ntwo\nthree\n")
        return _Result()

    @staticmethod
    def _assert_graphql_fields(argv):
        fields = dict(zip(argv[4::2], argv[5::2]))
        assert "variables" not in " ".join(argv)
        assert fields.get("-f") is not None or "-f" in argv
        if "number=" in " ".join(argv):
            assert ["-f", "owner=example-owner", "-f", "repo=garden", "-F", "number=42"] == argv[5:11]
        else:
            assert argv[-4:] == ["-f", "pullRequestId=PR_node", "-f", "path=Sources/Garden.swift"]

    @staticmethod
    def assert_safe_environment(environment):
        assert not any(key.startswith("HERDR_") for key in environment)


class FakeService:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.changed: list[str] = []
        self._quick_session_lock = threading.RLock()

    def refresh_snapshot(self, **_kwargs):
        return {"workspaces": [{"workspace_id": "workspace", "label": "PR Reviews"}], "tabs": [], "panes": []}

    @staticmethod
    def _quick_exact_workspace(snapshot, _label):
        return snapshot["workspaces"][0]

    @staticmethod
    def _quick_created_tab_ids(_response, **_kwargs):
        return "tab", "anchor"

    @staticmethod
    def _quick_new_identifier(response, key, **_kwargs):
        return response.get(key)

    @staticmethod
    def _quick_split_pane_id(response, **_kwargs):
        return response.get("split_pane_id")

    def invoke(self, method, params):
        self.calls.append((method, params))
        if method == "tab.create":
            return {"result": {"tab_id": "tab", "pane_id": "anchor"}}
        return {"result": {}}

    def pr_review_changed(self, review_id):
        self.changed.append(review_id)


class SplitService(FakeService):
    def __init__(self, *, split_result=None) -> None:
        super().__init__()
        self.split_result = {"pane_id": "new-pane"} if split_result is None else split_result

    def refresh_snapshot(self, **_kwargs):
        return {
            "workspaces": [{"workspace_id": "workspace", "label": "PR Reviews"}],
            "tabs": [{"tab_id": "tab"}],
            "panes": [{"pane_id": "anchor"}],
        }

    def invoke(self, method, params):
        self.calls.append((method, params))
        if method == "pane.split":
            return {"result": self.split_result}
        if method == "agent.start":
            return {"result": {}}
        return super().invoke(method, params)


class FakeProcess:
    def __init__(self, returncode=None):
        self.returncode = returncode

    def poll(self):
        return self.returncode


class LaunchService(FakeService):
    """Native-service fake for exercising the agent launch fallbacks."""

    def __init__(self, *, agent_error=False, split_error=False, on_agent_start=None):
        super().__init__()
        self.agent_error = agent_error
        self.split_error = split_error
        self.on_agent_start = on_agent_start
        self.pane_text = ""

    def refresh_snapshot(self, **_kwargs):
        return {
            "workspaces": [{"workspace_id": "workspace", "label": "PR Reviews"}],
            "tabs": [{"tab_id": "tab"}],
            "panes": [{"pane_id": "anchor"}],
        }

    def invoke(self, method, params):
        self.calls.append((method, params))
        if method == "pane.split":
            if self.split_error:
                raise RuntimeError("synthetic split failure")
            return {"result": {"pane_id": "new-pane"}}
        if method == "agent.start":
            if self.on_agent_start:
                self.on_agent_start()
            if self.agent_error:
                raise RuntimeError("synthetic agent failure")
            return {"result": {}}
        if method == "pane.send_input":
            return {"result": {}}
        return {"result": {}}

    def read_pane(self, _pane_id, *, lines):
        return {"output": {"text": self.pane_text}}


class PRReviewRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.store = PRReviewStore(Path(self.temp.name) / "store.sqlite3")
        self.runner = FakeRunner()
        self.service = FakeService()
        self.runtime = PRReviewRuntime(self.service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false"}, runtime_root=self.temp.name, runner=self.runner)
        self.addCleanup(self.store.close)
        self.addCleanup(self.temp.cleanup)
        # Shell, ranking, and preparation workers publish their run state
        # before their final store writes, so a test can return while a daemon
        # thread still touches this store. Join runtime workers before cleanup
        # closes the shared connection.
        self.addCleanup(self.join_runtime_workers)

    def join_runtime_workers(self) -> None:
        for thread in list(threading.enumerate()):
            if isinstance(getattr(getattr(thread, "_target", None), "__self__", None), PRReviewRuntime):
                thread.join(timeout=5)

    def _review(self):
        return self.store.create_review({"url": "https://github.com/example-owner/garden/pull/42", "host": "github.com", "owner": "example-owner", "repo": "garden", "number": 42, "request_id": "create"})

    def _ready_review(self, **values):
        review = self._review()
        worktree = Path(self.temp.name) / "worktree"
        worktree.mkdir(exist_ok=True)
        defaults = {"checkout_path": str(worktree), "status": "ready"}
        defaults.update(values)
        self.store.update_review(review["id"], **defaults)
        return self.store.get_review(review["id"], True), worktree

    def _until(self, predicate, timeout=2.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        self.fail("condition did not become true before timeout")

    def _event_types(self, review_id):
        return [event["type"] for event in self.store.events(review_id)["events"]]

    def test_prepare_records_files_workspace_and_viewed_state(self):
        review = self._review()
        self.runtime.prepare(review["id"])
        prepared = self.store.get_review(review["id"], True)
        self.assertEqual(prepared["status"], "ready")
        self.assertEqual(prepared["tab_id"], "tab")
        self.assertEqual(self.store.files(review["id"])[0]["path"], "Sources/Garden.swift")
        self.assertTrue(self.store.files(review["id"])[0]["viewed"])
        self.assertIn("tab.create", [name for name, _ in self.service.calls])
        fetches = [argv for argv, _ in self.runner.calls if argv[:5] == ["git", "-C", str(self.runtime.checkout_root / "repos" / "example-owner__garden"), "fetch", "--quiet"]]
        self.assertEqual(fetches[1], ["git", "-C", str(self.runtime.checkout_root / "repos" / "example-owner__garden"), "fetch", "--quiet", "origin", "pull/42/head:refs/herdr-pr/42"])

    def test_file_text_clamps_window(self):
        review = self._review()
        self.store.update_review(review["id"], checkout_path=self.temp.name, head_sha="head", base_sha="base")
        text = self.runtime.file_text(review["id"], "Sources/Garden.swift", "after", 2, 99)
        self.assertEqual(text["start_line"], 2)
        self.assertEqual(text["end_line"], 3)
        self.assertEqual(text["total_lines"], 3)

    def test_findings_extracts_only_matching_blocks(self):
        review = self._review()
        document = self.runtime._save_document(review["id"], "findings.md", b"Ignore this.\n\nSources/Garden.swift needs a test.\n\nOther text.", "text/markdown", "Findings", "user", "upload")
        findings = self.runtime.findings_for_path(review["id"], "Sources/Garden.swift")
        self.assertIn("needs a test", findings["text"])
        self.assertEqual(findings["document_ids"], [document["id"]])

    def test_findings_skips_documents_larger_than_four_megabytes(self):
        review = self._review()
        self.runtime._save_document(review["id"], "large.md", b"Sources/Garden.swift\n" + b"x" * (4 * 1024 * 1024), "text/markdown", "Large", "user", "large")
        self.assertEqual(self.runtime.findings_for_path(review["id"], "Sources/Garden.swift"), {"path": "Sources/Garden.swift", "text": "", "document_ids": []})

    def test_create_review_prepares_once_for_replays(self):
        calls = []
        started = threading.Event()
        release = threading.Event()
        self.runtime.prepare = lambda review_id: (calls.append(review_id), started.set(), release.wait(1))
        first = self.runtime.create_review("https://github.com/example-owner/garden/pull/42", "create-once")
        self.assertTrue(started.wait(1))
        replay = self.runtime.create_review("https://github.com/example-owner/garden/pull/42", "create-replay")
        release.set()
        self._until(lambda: not self.runtime._preparing_reviews)
        self.assertEqual(first["id"], replay["id"])
        self.assertEqual(calls, [first["id"]])

    def test_start_run_replay_launches_once(self):
        review, _ = self._ready_review(workspace_id="workspace", tab_id="tab", anchor_pane_id="anchor")
        service = LaunchService()
        runtime = PRReviewRuntime(service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false"}, runtime_root=self.temp.name, runner=self.runner)
        first = runtime.start_run(review["id"], "comprehensive-pr-review", "same-run")
        replay = runtime.start_run(review["id"], "comprehensive-pr-review", "same-run")
        self.assertEqual(first["id"], replay["id"])
        self.assertEqual([name for name, _ in service.calls].count("pane.split"), 1)

    def test_existing_run_split_uses_native_contract_and_falls_back_when_unrecoverable(self):
        review = self._review()
        self.store.update_review(
            review["id"],
            checkout_path=self.temp.name,
            status="ready",
            workspace_id="workspace",
            tab_id="tab",
            anchor_pane_id="anchor",
        )
        service = SplitService()
        runtime = PRReviewRuntime(
            service,
            self.store,
            environ={"HERDR_PR_REVIEW_AUTO_RANK": "false"},
            runtime_root=self.temp.name,
            runner=self.runner,
            popen=lambda *_args, **_kwargs: FakeProcess(),
        )
        run = runtime.start_run(review["id"], "comprehensive-pr-review", "split-ok")
        split = next(params for method, params in service.calls if method == "pane.split")
        self.assertEqual(split, {
            "target_pane_id": "anchor",
            "direction": "right",
            "cwd": self.temp.name,
            "focus": False,
            "env": {
                "HERDR_PR_REVIEW_ID": review["id"],
                "HERDR_PR_REVIEW_URL": review["url"],
                "HERDR_PR_REVIEW_RUN_ID": run["id"],
            },
        })
        self.assertNotIn("pane_id", split)

        failed_service = SplitService(split_result={})
        fallback_runtime = PRReviewRuntime(
            failed_service,
            self.store,
            environ={"HERDR_PR_REVIEW_AUTO_RANK": "false"},
            runtime_root=self.temp.name,
            runner=self.runner,
            popen=lambda *_args, **_kwargs: FakeProcess(),
        )
        fallback = fallback_runtime.start_run(review["id"], "comprehensive-pr-review", "split-fallback")
        stored = self.store.run(review["id"], fallback["id"])
        self.assertEqual(stored["launch"], "shell")
        self.assertTrue(stored["error"])
        fallback_runtime._processes[fallback["id"]][1].close()

    def test_prepare_failure_marks_review_failed_and_notifies_service(self):
        review = self._review()

        def fail_view(argv, _kwargs):
            if argv[:3] == ["gh", "pr", "view"]:
                return _Result(returncode=1, stderr="synthetic GitHub failure")
            return None

        self.runner.on_call = fail_view
        self.runtime.prepare(review["id"])
        stored = self.store.get_review(review["id"], True)
        self.assertEqual(stored["status"], "failed")
        self.assertLessEqual(len(stored["error"]), 300)
        self.assertIn("review.failed", self._event_types(review["id"]))
        self.assertIn(review["id"], self.service.changed)

    def test_agent_launch_persists_placement_before_start_and_uses_clean_split_environment(self):
        review, worktree = self._ready_review(workspace_id="workspace", tab_id="tab", anchor_pane_id="anchor")
        observed = {}

        def capture_persisted_run():
            run = next(run for run in self.store.runs_for_review(review["id"]) if run["state"] == "running")
            observed.update({key: run[key] for key in ("workspace_id", "tab_id", "pane_id", "started_at")})

        service = LaunchService(on_agent_start=capture_persisted_run)
        runtime = PRReviewRuntime(service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false", "HERDR_HARNESS_API_TOKEN": "synthetic-control-token"}, runtime_root=self.temp.name, runner=self.runner)
        run = runtime.start_run(review["id"], "comprehensive-pr-review", "agent-success")
        split = next(params for method, params in service.calls if method == "pane.split")
        self.assertEqual(split["target_pane_id"], "anchor")
        self.assertEqual(split["direction"], "right")
        self.assertEqual(split["cwd"], str(worktree))
        self.assertFalse(split["focus"])
        self.assertEqual(split["env"]["HERDR_PR_REVIEW_RUN_ID"], run["id"])
        self.assertFalse(any(key.startswith("HERDR_HARNESS_") for key in split["env"]))
        self.assertEqual(observed["workspace_id"], "workspace")
        self.assertEqual(observed["tab_id"], "tab")
        self.assertEqual(observed["pane_id"], "new-pane")
        self.assertTrue(observed["started_at"])
        self.assertEqual(self.store.run(review["id"], run["id"])["launch"], "agent")
        self.assertLess([name for name, _ in service.calls].index("pane.split"), [name for name, _ in service.calls].index("agent.start"))
        self.assertIn("run.started", self._event_types(review["id"]))

    def test_agent_start_failure_sends_shell_quoted_input(self):
        review, _ = self._ready_review(workspace_id="workspace", tab_id="tab", anchor_pane_id="anchor")
        service = LaunchService(agent_error=True)
        runtime = PRReviewRuntime(service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false", "HERDR_PR_REVIEW_RUNNER": "synthetic runner"}, runtime_root=self.temp.name, runner=self.runner)
        run = runtime.start_run(review["id"], "comprehensive-pr-review", "input-fallback")
        sent = next(params for method, params in service.calls if method == "pane.send_input")
        self.assertEqual(sent["text"], "synthetic runner " + shlex.quote("/comprehensive-pr-review 42"))
        self.assertEqual(sent["keys"], ["enter"])
        self.assertEqual(self.store.run(review["id"], run["id"])["launch"], "input")

    def test_split_failure_uses_local_popen_and_records_popen_error(self):
        review, worktree = self._ready_review(workspace_id="workspace", tab_id="tab", anchor_pane_id="anchor")
        service = LaunchService(split_error=True)
        popen_calls = []

        def popen(argv, **kwargs):
            popen_calls.append((argv, kwargs))
            return FakeProcess()

        runtime = PRReviewRuntime(service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false", "HERDR_PR_REVIEW_RUNNER": "synthetic-runner"}, runtime_root=self.temp.name, runner=self.runner, popen=popen)
        run = runtime.start_run(review["id"], "comprehensive-pr-review", "shell-fallback")
        self.assertEqual(popen_calls[0][0], ["synthetic-runner", "-p", "/comprehensive-pr-review 42"])
        self.assertEqual(popen_calls[0][1]["cwd"], str(worktree))
        self.assertEqual(self.store.run(review["id"], run["id"])["launch"], "shell")
        runtime._processes[run["id"]][1].close()

        def fail_popen(*_args, **_kwargs):
            raise OSError("synthetic popen failure")

        failed_runtime = PRReviewRuntime(LaunchService(split_error=True), self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false"}, runtime_root=self.temp.name, runner=self.runner, popen=fail_popen)
        failed = failed_runtime.start_run(review["id"], "comprehensive-pr-review", "popen-failure")
        stored = self.store.run(review["id"], failed["id"])
        self.assertEqual(stored["state"], "failed")
        self.assertIn("synthetic popen failure", stored["error"])
        self.assertTrue((Path(self.temp.name) / "reviews" / review["id"] / "runs" / failed["id"] / "output.log").exists())

    def test_shell_skill_uses_split_argv_and_syncs_viewed_afterward(self):
        review, worktree = self._ready_review()
        self.store.upsert_files(review["id"], [{"path": "Sources/Garden.swift"}])
        run = self.runtime.start_run(review["id"], "mark-generated-and-test-viewed-in-pull-request", "utility")
        self._until(lambda: self.store.run(review["id"], run["id"])["state"] in {"finished", "failed"})
        utility = next(call for call in self.runner.calls if call[0][:2] == ["gh", "autoview"])
        self.assertEqual(utility[0], shlex.split("gh autoview https://github.com/example-owner/garden/pull/42 --apply"))
        self.assertEqual(utility[1]["cwd"], str(worktree))
        self.assertEqual(self.store.run(review["id"], run["id"])["state"], "finished")
        self.assertTrue(any(argv[:3] == ["gh", "api", "graphql"] for argv, _ in self.runner.calls))
        self.runner.on_call = lambda argv, _kwargs: _Result(returncode=1, stderr="synthetic utility failure") if argv[:2] == ["gh", "autoview"] else None
        failed = self.runtime.start_run(review["id"], "mark-generated-and-test-viewed-in-pull-request", "utility-failed")
        self._until(lambda: self.store.run(review["id"], failed["id"])["state"] in {"finished", "failed"})
        self.assertEqual(self.store.run(review["id"], failed["id"])["state"], "failed")

    def test_reconcile_registers_only_new_untracked_matching_outputs_once(self):
        review, worktree = self._ready_review()
        run = self.store.create_run(review["id"], "comprehensive-pr-review", "output-run")
        self.store.update_run(review["id"], run["id"], state="running", launch="agent", output_snapshot_json="[]")
        (worktree / "review.md").write_text("synthetic review", encoding="utf-8")
        (worktree / "ignored.txt").write_text("ignore", encoding="utf-8")
        (worktree / "node_modules").mkdir()
        (worktree / "node_modules" / "ignored.md").write_text("ignore", encoding="utf-8")
        (worktree / "tracked.md").write_text("tracked", encoding="utf-8")

        def git_tracking(argv, _kwargs):
            if "--error-unmatch" in argv:
                return _Result(returncode=0 if argv[-1] == "tracked.md" else 1)
            return None

        self.runner.on_call = git_tracking
        self.assertTrue(self.runtime._register_output_documents(review["id"], run["id"]))
        self.assertFalse(self.runtime._register_output_documents(review["id"], run["id"]))
        documents = self.store.documents(review["id"])
        self.assertEqual(len(documents), 1)
        self.assertEqual(documents[0]["origin"], "skill")
        self.assertEqual(documents[0]["run_id"], run["id"])
        self.assertEqual(documents[0]["origin_path"], "review.md")
        (worktree / "duplicate.md").write_text("synthetic review", encoding="utf-8")
        self.assertFalse(self.runtime._register_output_documents(review["id"], run["id"]))
        stored = list((Path(self.temp.name) / "reviews" / review["id"] / "documents").iterdir())
        self.assertEqual(len(stored), 1)

    def test_reconcile_ends_or_finishes_agent_and_shell_runs(self):
        review, _ = self._ready_review()
        old = (datetime.now(timezone.utc) - timedelta(seconds=61)).isoformat().replace("+00:00", "Z")
        missing = self.store.create_run(review["id"], "comprehensive-pr-review", "missing-pane")
        done = self.store.create_run(review["id"], "comprehensive-pr-review", "done-pane")
        ok = self.store.create_run(review["id"], "comprehensive-pr-review", "shell-ok")
        bad = self.store.create_run(review["id"], "comprehensive-pr-review", "shell-bad")
        self.store.update_run(review["id"], missing["id"], state="running", launch="agent", pane_id="gone", started_at=old)
        self.store.update_run(review["id"], done["id"], state="running", launch="agent", pane_id="done", started_at=old)
        self.store.update_run(review["id"], ok["id"], state="running", launch="shell")
        self.store.update_run(review["id"], bad["id"], state="running", launch="shell")
        logs = []
        for run in (ok, bad):
            log = Path(self.temp.name) / "reviews" / review["id"] / "runs" / run["id"] / "output.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            logs.append(log.open("w", encoding="utf-8"))
        self.runtime._processes = {ok["id"]: (FakeProcess(0), logs[0]), bad["id"]: (FakeProcess(1), logs[1])}
        self.service.refresh_snapshot = lambda **_kwargs: {"panes": [{"pane_id": "done", "agent_status": "done"}]}
        self.runtime.reconcile()
        self.assertEqual(self.store.run(review["id"], missing["id"])["state"], "ended")
        self.assertEqual(self.store.run(review["id"], missing["id"])["note"], "Pane closed before the run reported an outcome")
        self.assertEqual(self.store.run(review["id"], done["id"])["state"], "finished")
        self.assertEqual(self.store.run(review["id"], ok["id"])["state"], "finished")
        self.assertEqual(self.store.run(review["id"], bad["id"])["state"], "failed")

    def test_rank_review_uses_pi_stdin_and_validates_paths(self):
        review, _ = self._ready_review(title="Garden update", body="Synthetic body")
        self.store.upsert_files(review["id"], [{"path": "Sources/Garden.swift", "status": "modified", "additions": 2, "deletions": 1}])
        pi = Path(self.temp.name) / "synthetic-pi"
        pi.write_text("", encoding="utf-8")
        pi.chmod(0o700)
        pi_bin = str(pi.resolve())

        def pi_result(argv, _kwargs):
            if argv[0] == pi_bin:
                return _Result('{"type":"message_start"}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"leading prose {\\"files\\":[{\\"path\\":\\"Sources/Garden.swift\\",\\"impact\\":\\"high\\",\\"reason\\":\\"storage change\\"}],\\"guided\\":[{\\"path\\":\\"Sources/Garden.swift\\",\\"reason\\":\\"read first\\"}]} trailing"}]}}\n')
            return None

        self.runner.on_call = pi_result
        runtime = PRReviewRuntime(self.service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false", "HERDR_PR_REVIEW_PI_BIN": pi_bin}, runtime_root=self.temp.name, runner=self.runner)
        runtime.rank_review(review["id"], "rank-good")
        self._until(lambda: self.store.get_review(review["id"], True)["ranking_state"] != "running")
        file = self.store.files(review["id"])[0]
        self.assertEqual(self.store.get_review(review["id"], True)["ranking_state"], "done", self.store.get_review(review["id"], True)["ranking_error"])
        self.assertEqual((file["impact"], file["impact_reason"], file["guided_order"], file["guided_reason"]), ("high", "storage change", 1, "read first"))
        self.assertEqual(self.store.get_review(review["id"], True)["ranking_state"], "done")
        self.assertTrue((Path(self.temp.name) / "reviews" / review["id"] / "ranking.json").is_file())
        call = next((argv, kwargs) for argv, kwargs in self.runner.calls if argv[0] == pi_bin)
        self.assertEqual(call[0][1:5], ["-p", "--mode", "json", "--no-session"])
        self.assertIn("--no-tools", call[0])
        self.assertIn("input", call[1])
        self.assertNotIn(call[1]["input"], call[0])

        self.runner.on_call = lambda argv, _kwargs: _Result('{"files":[{"path":"Unknown.swift","impact":"low"}],"guided":[]}') if argv[0] == pi_bin else None
        runtime.rank_review(review["id"], "rank-bad")
        self._until(lambda: self.store.get_review(review["id"], True)["ranking_state"] != "running")
        failed = self.store.get_review(review["id"], True)
        self.assertEqual(failed["ranking_state"], "failed")
        self.assertTrue(failed["ranking_error"])

    def test_set_viewed_sync_options_and_failure_event(self):
        review, _ = self._ready_review()
        self.store.upsert_files(review["id"], [{"path": "Sources/Garden.swift"}])
        review_dir = Path(self.temp.name) / "reviews" / review["id"]
        review_dir.mkdir(parents=True, exist_ok=True)
        (review_dir / "pr.json").write_text(json.dumps({"id": "PR_node"}), encoding="utf-8")
        syncing = PRReviewRuntime(self.service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false", "HERDR_PR_REVIEW_SYNC_VIEWED": "true"}, runtime_root=self.temp.name, runner=self.runner)
        syncing.set_viewed(review["id"], ["Sources/Garden.swift"], True, True, "push")
        graphql = [argv for argv, _ in self.runner.calls if argv[:3] == ["gh", "api", "graphql"]]
        self.assertEqual(len(graphql), 1)
        self.assertEqual(graphql[0][-4:], ["-f", "pullRequestId=PR_node", "-f", "path=Sources/Garden.swift"])
        self.runner.calls.clear()
        syncing.set_viewed(review["id"], ["Sources/Garden.swift"], False, False, "no-push")
        disabled = PRReviewRuntime(self.service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false", "HERDR_PR_REVIEW_SYNC_VIEWED": "false"}, runtime_root=self.temp.name, runner=self.runner)
        disabled.set_viewed(review["id"], ["Sources/Garden.swift"], True, True, "disabled")
        self.assertFalse(any(argv[:3] == ["gh", "api", "graphql"] for argv, _ in self.runner.calls))
        self.runner.on_call = lambda argv, _kwargs: _Result(returncode=1, stderr="synthetic mutation failure") if argv[:3] == ["gh", "api", "graphql"] else None
        syncing.set_viewed(review["id"], ["Sources/Garden.swift"], True, True, "failed-push")
        self.assertIn("github.viewed_push_failed", self._event_types(review["id"]))

    def test_document_validation_and_safe_opening(self):
        review, _ = self._ready_review()
        existing = Path(self.temp.name) / "note.md"
        existing.write_text("note", encoding="utf-8")
        disallowed = Path(self.temp.name) / "bad.exe"
        disallowed.write_text("not a document", encoding="utf-8")
        for path in ("relative.md", str(Path(self.temp.name) / "bad.exe"), str(Path(self.temp.name) / "missing.md")):
            with self.subTest(path=path), self.assertRaises(PRReviewError) as raised:
                self.runtime.add_document_path(review["id"], path, "Document", "user", f"path-{path}")
            self.assertEqual(raised.exception.code, "invalid_request")
        with self.assertRaises(PRReviewError) as raised:
            self.runtime.add_document_link(review["id"], "file:///tmp/note.md", "Link", "user", "bad-link")
        self.assertEqual(raised.exception.code, "invalid_request")
        link = self.runtime.add_document_link(review["id"], "https://example.invalid/note", "Link", "user", "link")
        with self.assertRaises(PRReviewError) as raised:
            self.runtime.open_document(review["id"], link["id"]).__enter__()
        self.assertEqual(raised.exception.code, "document_not_downloadable")
        document = self.runtime.add_document_path(review["id"], str(existing), "Note", "user", "path-ok")
        self.store._db.execute("UPDATE prr_documents SET stored_path=? WHERE id=?", (str(existing), document["id"]))
        with self.assertRaises(PRReviewError) as raised:
            self.runtime.open_document(review["id"], document["id"]).__enter__()
        self.assertEqual(raised.exception.code, "document_not_downloadable")

    def test_document_path_uses_streaming_copy_and_run_mutations_are_idempotent(self):
        review, _ = self._ready_review()
        source = Path(self.temp.name) / "large-note.md"
        source.write_bytes(b"synthetic\n" * (1024 * 700))
        document = self.runtime.add_document_path(review["id"], str(source), "", "user", "large-path")
        self.assertEqual(document["byte_size"], source.stat().st_size)
        self.assertNotEqual(self.store.document(review["id"], document["id"], include_storage=True)["stored_path"], str(source))
        run = self.store.create_run(review["id"], "comprehensive-pr-review", "finish-source")
        self.store.update_run(review["id"], run["id"], state="running")
        finished = self.runtime.finish_run(review["id"], run["id"], "finished", "", "finish-once")
        self.assertEqual(finished, self.runtime.finish_run(review["id"], run["id"], "finished", "", "finish-once"))

    def test_rank_and_refresh_replays_are_idempotent(self):
        review, _ = self._ready_review()
        workers = []
        self.runtime._rank_worker = lambda review_id, request_id: workers.append((review_id, request_id))
        self.assertEqual(self.runtime.rank_review(review["id"], "rank-once"), self.runtime.rank_review(review["id"], "rank-once"))
        self.runtime.rank_review(review["id"], "rank-concurrent")
        self._until(lambda: workers)
        self.assertEqual(len(workers), 1)
        self.assertEqual(self.runtime.rank_review(review["id"], "rank-concurrent")["ranking_state"], "running")
        prepares = []
        self.runtime.prepare = lambda review_id, refresh=False: prepares.append((review_id, refresh))
        self.runtime.refresh_review(review["id"], "refresh-once")
        self.runtime.refresh_review(review["id"], "refresh-once")
        self._until(lambda: prepares)
        self.assertEqual(prepares, [(review["id"], True)])

    def test_run_decodes_non_utf8_subprocess_output(self):
        self.runner.on_call = lambda _argv, _kwargs: _Result(b"\xff", stderr=b"\xfe")
        self.assertEqual(self.runtime._run(["git", "status"]).stdout, "�")

    def test_run_output_reads_pane_or_log_tail(self):
        review, _ = self._ready_review()
        pane_run = self.store.create_run(review["id"], "comprehensive-pr-review", "pane-output")
        log_run = self.store.create_run(review["id"], "comprehensive-pr-review", "log-output")
        self.store.update_run(review["id"], pane_run["id"], pane_id="new-pane")
        service = LaunchService()
        service.pane_text = "first\nsecond\nthird"
        runtime = PRReviewRuntime(service, self.store, environ={"HERDR_PR_REVIEW_AUTO_RANK": "false"}, runtime_root=self.temp.name, runner=self.runner)
        self.assertEqual(runtime.run_output(review["id"], pane_run["id"], 2), {"run_id": pane_run["id"], "lines": ["second", "third"], "source": "pane"})
        log = Path(self.temp.name) / "reviews" / review["id"] / "runs" / log_run["id"] / "output.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("one\ntwo\nthree\n", encoding="utf-8")
        self.assertEqual(runtime.run_output(review["id"], log_run["id"], 2), {"run_id": log_run["id"], "lines": ["two", "three"], "source": "log"})


if __name__ == "__main__":
    unittest.main()
