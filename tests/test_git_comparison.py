"""Behavioral comparisons against synthetic repositories, with no remote calls."""
import copy
import json
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness import assistant
from herdr_harness.agent_runs import AgentRunManager, AgentRunError
from herdr_harness.git_comparison import first_parent_history, resolve_comparison
from herdr_harness.git_inspection import capture_source, inspect, manifest
from herdr_harness.local_tools import LocalTools
from herdr_harness.pr_review_diff import parse_unified_diff
from herdr_harness.pr_review_guide import validate_explanation
from herdr_harness.pr_review_runtime import PRReviewRuntime
from herdr_harness.pr_review_store import PRReviewStore, PRReviewError
from herdr_harness.service import HerdrService
from herdr_harness.workspace_tools import WorkspaceToolError
from tests.test_agent_runs import write_fake_pi, wait_for_status
from tests.test_pr_review_runtime import FakeService


class GitComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repository"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Synthetic Developer")
        self.git("config", "user.email", "developer@example.test")
        (self.repo / "original.txt").write_text("first\nsecond\nthird\nfourth\n")
        (self.repo / "removed.txt").write_text("remove me\n")
        self.base = self.commit("Baseline")
        self.git("checkout", "-qb", "feature")
        (self.repo / "original.txt").write_text("first\nchanged\nthird\nfourth\n")
        (self.repo / "temporary.txt").write_text("temporary evidence\n")
        self.first = self.commit("First feature step")
        self.git("mv", "original.txt", "renamed.txt")
        self.second = self.commit("Rename step")
        (self.repo / "removed.txt").unlink()
        (self.repo / "temporary.txt").unlink()
        (self.repo / "renamed.txt").write_text("first\nlatest\nthird\nfourth\n")
        self.head = self.commit("Finish step")
        self.git("checkout", "-qb", "other", self.base)
        (self.repo / "outside.txt").write_text("not in feature history\n")
        self.other = self.commit("Another branch")
        self.git("checkout", "-q", "feature")
        self.tools = LocalTools(environ={})

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.DEVNULL, text=True).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def compare(self, selection=None, **kwargs):
        return self.tools.git_compare(self.repo, selection, expected_root=str(self.repo), **kwargs)

    def review(self):
        store = PRReviewStore(self.root / "reviews.db")
        self.addCleanup(store.close)
        runtime = PRReviewRuntime(FakeService(), store, environ={}, runtime_root=self.root / "runtime", runner=subprocess.run)
        row = store.create_review({"request_id": "create", "url": "https://github.com/example/garden/pull/1", "host": "github.com", "owner": "example", "repo": "garden", "number": 1})
        row = store.update_review(row["id"], status="ready", base_sha=self.base, head_sha=self.head, merge_base_sha=self.base, base_ref="main", checkout_path=str(self.repo))
        full = self.compare()
        store.upsert_files(row["id"], full["files"])
        directory = runtime._revision_directory(row["id"], self.base, self.head, self.base)
        directory.mkdir(parents=True)
        (directory / "diff.json").write_text(json.dumps({"files": full["files"], "truncated": False}))
        return runtime, store, row

    def test_default_target_and_ordered_endpoint_semantics(self):
        whole = self.compare()
        self.assertEqual(whole["baseline_sha"], self.base)
        self.assertEqual(whole["baseline_label"], "main")
        self.assertEqual([c["sha"] for c in whole["commits"]], [self.first, self.second, self.head])
        clicked = self.compare({"mode": "commit", "start_commit": self.second})
        self.assertEqual(clicked["comparison"]["before_sha"], self.base)
        self.assertEqual(clicked["comparison"]["after_sha"], self.second)
        self.assertEqual(clicked["comparison"]["commit_shas"], [self.first, self.second])
        selected = self.compare({"mode": "range", "start_commit": self.first, "end_commit": self.second})
        self.assertEqual(selected["comparison"]["before_sha"], self.first)
        self.assertEqual(selected["comparison"]["commit_shas"], [self.second])
        self.assertEqual(selected["files"][0]["status"], "renamed")
        self.assertEqual(selected["files"][0]["old_path"], "original.txt")
        self.assertEqual(selected["files"][0]["path"], "renamed.txt")
        self.assertIn("rename from original.txt", selected["files"][0]["patch"])

    def test_reversed_foreign_short_and_expression_revisions_are_rejected(self):
        invalid = [
            {"mode": "range", "start_commit": self.head, "end_commit": self.first},
            {"mode": "commit", "start_commit": self.other},
            {"mode": "commit", "start_commit": self.first[:8]},
            {"mode": "commit", "start_commit": "HEAD~1"},
            {"mode": "all", "end_commit": self.head},
        ]
        for selection in invalid:
            with self.subTest(selection=selection), self.assertRaises(WorkspaceToolError): self.compare(selection)
        with self.assertRaises(WorkspaceToolError):
            self.tools.git_compare(self.repo, expected_root=str(self.root))
        with self.assertRaises(WorkspaceToolError): self.compare(file="../outside")

    def test_selected_files_include_transient_paths_absent_from_final_pr(self):
        runtime, _, row = self.review()
        result = runtime.diff(row["id"], comparison={"mode": "commit", "start_commit": self.first}, base_sha=self.base, head_sha=self.head)
        self.assertIn("temporary.txt", [f["path"] for f in result["files"]])
        self.assertEqual(result["base_sha"], self.base)
        self.assertEqual(result["head_sha"], self.head)
        self.assertEqual(result["comparison"]["after_sha"], self.first)
        deleted = runtime.diff(row["id"], comparison={"mode": "range", "start_commit": self.second, "end_commit": self.head})
        self.assertTrue(any(f["path"] == "temporary.txt" and f["status"] == "deleted" for f in deleted["files"]))
        before = runtime.file_text(row["id"], "renamed.txt", "before", 1, 4, comparison={"mode": "range", "start_commit": self.first, "end_commit": self.second})
        self.assertIn("changed", before["text"])
        with self.assertRaises(PRReviewError) as caught:
            runtime.diff(row["id"], comparison={"mode": "all"}, head_sha=self.first)
        self.assertEqual(caught.exception.code, "stale_review_revision")
        with self.assertRaises(PRReviewError): runtime.diff(row["id"], comparison={"mode": "working-tree"})

    def test_working_tree_includes_index_unstaged_and_untracked_and_is_pinned(self):
        (self.repo / "renamed.txt").write_text("staged change\n")
        self.git("add", "renamed.txt")
        (self.repo / "renamed.txt").write_text("actual working content\n")
        (self.repo / "new.txt").write_text("new untracked content\n")
        response = self.compare({"mode": "working-tree", "start_commit": self.head})
        self.assertIn("actual working content", response["diff"])
        self.assertNotIn("staged change", response["diff"])
        self.assertIn("new untracked content", response["diff"])
        source = capture_source(self.repo, "working-tree", self.root / "snapshots", identity=response["comparison"]["id"])
        scope = manifest(self.repo, response, working_tree=source)
        (self.repo / "new.txt").write_text("later untracked content\n")
        self.assertNotEqual(response["comparison"]["id"], self.compare({"mode": "working-tree", "start_commit": self.head})["comparison"]["id"])
        self.assertIn("new untracked content", inspect(scope, {"action": "file", "path": "new.txt"})["text"])

    def test_guide_context_and_code_targets_use_selected_comparison(self):
        runtime, _, row = self.review()
        request = {"request_id": "selected", "base_sha": self.base, "head_sha": self.head, "kind": "answer", "question": "Why this temporary file?", "path": "temporary.txt", "comparison": {"mode": "commit", "start_commit": self.first}, "viewer_state": {"path": "temporary.txt", "diff_style": "split"}}
        packet = runtime.guide.context.create(row["id"], request)
        self.assertEqual(packet["comparison"]["after_sha"], self.first)
        self.assertEqual(packet["viewer_state"], request["viewer_state"])
        snapshot = runtime.guide.context.load(row["id"], packet["id"])
        explanation = {"chapters": [{"segments": [{"path": "temporary.txt", "side": "after", "start_line": 1, "end_line": 1, "spoken_text": "The temporary evidence is visible."}]}]}
        segment = validate_explanation(explanation, snapshot, "answer")["chapters"][0]["segments"][0]
        self.assertEqual(segment["path"], "temporary.txt")
        current = runtime.guide.context.create(row["id"], {**request, "request_id": "current", "path": "renamed.txt", "comparison": {"mode": "all"}})
        current_snapshot = runtime.guide.context.load(row["id"], current["id"])
        self.assertNotIn("path", validate_explanation(explanation, current_snapshot, "answer")["chapters"][0]["segments"][0])

    def test_on_demand_inspection_includes_earlier_and_later_captured_commits_only(self):
        response = self.compare({"mode": "commit", "start_commit": self.first})
        scope = manifest(self.repo, response)
        self.assertIn("changed", inspect(scope, {"action": "file", "path": "original.txt"})["text"])
        self.assertIn("latest", inspect(scope, {"action": "file", "revision": self.head, "path": "renamed.txt"})["text"])
        self.assertEqual(len(inspect(scope, {"action": "history"})["commits"]), 3)
        with self.assertRaises(ValueError): inspect(scope, {"action": "file", "revision": self.other, "path": "outside.txt"})
        with self.assertRaises(ValueError): inspect(scope, {"action": "file", "path": "../outside"})
        with self.assertRaises(ValueError): inspect(scope, {"action": "file", "path": "original.txt", "start": True})

    def test_git_question_profile_is_scoped_read_only_and_rejects_changed_comparison(self):
        capture = self.root / "capture.json"
        manager = AgentRunManager(environ={"HERDR_HARNESS_AGENT_PI_BIN": str(write_fake_pi(self.root)), "FAKE_AGENT_CAPTURE": str(capture)}, runs_root=self.root / "agent-runs", herdr_socket_path="/tmp/synthetic.sock", herdr_session="synthetic")
        self.addCleanup(manager.stop)
        service = object.__new__(HerdrService)
        service._lock = threading.RLock()
        service._agent_runs = manager
        service.local_tools = self.tools
        service._first_mate_git_context = lambda feature, workspace: ({}, self.repo)
        service._first_mate_git_baseline = lambda feature, workspace, comparison=None: None
        selected = {"mode": "commit", "start_commit": self.first}
        response = self.compare(selected)
        request = {"prompt": "Why this change?", "mode": "ask", "profile": "git-question-v1", "clientRequestId": "11111111-1111-1111-1111-111111111111", "scope": {"firstMateFeatureId": "feature", "workspaceId": "project", "expectedRootPath": str(self.repo), "comparison": selected, "comparisonId": response["comparison"]["id"]}, "context": {"version": 1, "snapshotId": "view", "capturedAt": "2026-01-01T00:00:00Z", "source": {"feature": "git.diff", "instanceId": "file"}, "items": []}}
        started = service.start_contextual_question(request)["run"]
        wait_for_status(manager, started["id"], {"completed"})
        recorded = json.loads(capture.read_text())
        self.assertEqual(recorded["argv"][recorded["argv"].index("--tools") + 1], "git_inspect")
        self.assertIn("--extension", recorded["argv"])
        self.assertNotIn("herdr-companion-awareness", recorded["argv"][recorded["argv"].index("--append-system-prompt") + 1])
        private = manager._read(started["id"])
        self.assertEqual(private["gitInspection"]["comparison"]["after_sha"], self.first)
        self.assertIn("changed", inspect(private["gitInspection"], {"action": "file", "path": "original.txt"})["text"])
        self.assertEqual(Path(private["gitInspection"]["captured_source"]).parent, manager._run_dir(started["id"]))
        self.git("branch", "-f", "main", self.head)
        self.assertEqual(service.start_contextual_question(request)["run"]["id"], started["id"])
        self.git("branch", "-f", "main", self.base)
        newer = copy.deepcopy(request)
        newer.update(clientRequestId="22222222-2222-2222-2222-222222222222", continueFromRunId=started["id"])
        newer["scope"]["comparison"] = {"mode": "all"}
        newer["scope"]["comparisonId"] = self.compare()["comparison"]["id"]
        with self.assertRaises(AgentRunError) as caught: service.start_contextual_question(newer)
        self.assertEqual(caught.exception.code, "assistant_scope_changed")

    def test_truncated_patch_retains_later_files_and_invalidates_on_omitted_edit(self):
        (self.repo / "a-large.txt").write_text("large changed line\n" * 5000)
        (self.repo / "z-small.txt").write_text("version A\n")
        first = self.compare({"mode": "working-tree"})
        self.assertTrue(first["truncated"])
        single = self.compare({"mode": "working-tree"}, file="z-small.txt")
        self.assertEqual(first["comparison"]["id"], single["comparison"]["id"])
        self.assertIn("version A", single["diff"])
        self.assertFalse(single["truncated"])
        self.assertIn("z-small.txt", [item["path"] for item in first["files"]])
        source = capture_source(self.repo, "working-tree", self.root / "snapshots", identity=first["comparison"]["id"])
        (self.repo / "z-small.txt").write_text("version B\n")
        second = self.compare({"mode": "working-tree"})
        self.assertNotEqual(first["comparison"]["id"], second["comparison"]["id"])
        another = capture_source(self.repo, "working-tree", self.root / "snapshots", identity=first["comparison"]["id"])
        self.assertNotEqual(source, another)
        self.assertEqual((another / "z-small.txt").read_text(), "version B\n")
        scope = manifest(self.repo, first, working_tree=source)
        discovered = inspect(scope, {"action": "files"})
        self.assertIn("z-small.txt", [item["path"] for item in discovered["files"]])
        self.assertTrue(inspect(scope, {"action": "diff", "path": "z-small.txt"})["truncated"])
        self.assertEqual(inspect(scope, {"action": "file", "path": "z-small.txt"})["text"], "version A\n")

    def test_merged_workflow_commit_is_authorized_without_sibling_contamination(self):
        self.git("checkout", "-qb", "side", self.first)
        (self.repo / "side.txt").write_text("side work\n")
        side = self.commit("Side work")
        self.git("checkout", "-q", "feature")
        self.git("merge", "--no-ff", "-m", "Merge side", "side")
        merge = self.git("rev-parse", "HEAD")
        selected = self.compare({"mode": "commit", "start_commit": side})
        self.assertEqual(selected["comparison"]["after_sha"], side)
        self.assertIn(side, selected["comparison"]["commit_shas"])
        self.assertNotIn(self.second, selected["comparison"]["commit_shas"])
        remaining = self.compare({"mode": "working-tree", "start_commit": side})
        self.assertIn(self.second, remaining["comparison"]["commit_shas"])
        self.assertIn(merge, remaining["comparison"]["commit_shas"])
        with self.assertRaises(WorkspaceToolError):
            self.compare({"mode": "range", "start_commit": self.second, "end_commit": side})

    def first_mate_service(self, visits, assignment=None):
        service = object.__new__(HerdrService)
        service._lock = threading.RLock()
        service._first_mate_store = SimpleNamespace(snapshot=lambda feature: {"visits": visits}, get_assignment=lambda workspace: assignment or {})
        service._first_mate_git_context = lambda feature, workspace: ({}, self.repo)
        service.local_tools = self.tools
        return service

    def test_captured_target_baseline_includes_work_before_first_visit_and_survives_target_advance(self):
        record = {"workspace_id": "project", "start_sha": self.second,
                  "comparison_baseline_sha": self.base, "comparison_baseline_label": "main"}
        service = self.first_mate_service([{"id": "v1", "created_at": "2026-01-01", "git_baselines": [record]}])
        self.git("branch", "-f", "main", self.head)
        response = service.first_mate_git_compare("feature", "project", comparison={"mode": "commit", "start_commit": self.first}, file=None, expected_root=str(self.repo))
        self.assertEqual(response["comparison"]["before_sha"], self.base)
        self.assertEqual(response["comparison"]["after_sha"], self.first)
        self.assertEqual(response["baseline_label"], "main")
        self.assertEqual([c["sha"] for c in response["commits"]], [self.first, self.second, self.head])

    def test_legacy_step_baseline_refuses_to_guess_original_target(self):
        service = self.first_mate_service([{"id": "v1", "git_baselines": [{"workspace_id": "project", "start_sha": self.second}]}])
        with self.assertRaises(WorkspaceToolError) as error:
            service._first_mate_git_baseline("feature", "project")
        self.assertEqual(error.exception.code, "git_baseline_unavailable")

    def test_live_feature_review_tracks_current_target_instead_of_original_workflow_baseline(self):
        record = {"workspace_id": "project", "start_sha": self.base,
                  "comparison_baseline_sha": self.base, "comparison_baseline_label": "main"}
        service = self.first_mate_service([{"id": "v1", "git_baselines": [record]}])
        self.git("branch", "-f", "main", self.first)
        for selection in (None, {"mode": "all"}, {"mode": "working-tree"}):
            with self.subTest(selection=selection):
                result = service.first_mate_git_compare("feature", "project", comparison=selection,
                                                       file=None, expected_root=str(self.repo))
                self.assertEqual(result["baseline_sha"], self.first)
                self.assertNotIn(self.first, result["comparison"]["commit_shas"])
                self.assertIn(self.second, result["comparison"]["commit_shas"])

    def test_existing_feature_without_capture_uses_current_target(self):
        service = self.first_mate_service([], {"feature_id": "feature", "metadata": {"base_revision": self.second}})
        for workspace in ("project", "existing-assignment"):
            response = service.first_mate_git_compare("feature", workspace, comparison={"mode": "all"}, file=None, expected_root=str(self.repo))
            self.assertEqual(response["baseline_sha"], self.base)
            self.assertIn(self.first, response["comparison"]["commit_shas"])

    def test_working_capture_refuses_incomplete_file_enumeration(self):
        from herdr_harness.git_inspection import working_paths
        with patch("herdr_harness.git_inspection.workspace_tools._git", return_value=("original.txt\0", True)):
            for operation in (lambda: working_paths(self.repo), lambda: capture_source(self.repo, "working-tree", self.root / "snapshots")):
                with self.assertRaises(WorkspaceToolError) as error:
                    operation()
                self.assertEqual(error.exception.code, "git_source_too_large")

    def test_git_quoted_filenames_preserve_exact_paths(self):
        name = 'snow-☃\ttab.txt'
        (self.repo / name).write_text("hello\n")
        added = self.commit("Unusual filename")
        result = self.compare({"mode": "range", "start_commit": self.head, "end_commit": added})
        self.assertEqual(result["files"][0]["path"], name)
        self.assertEqual(result["files"][0]["hunks"][0]["lines"][0]["text"], "hello")

    def test_snapshot_digest_does_not_follow_symlinked_parent(self):
        from herdr_harness.git_inspection import source_digest
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("outside source")
        (self.repo / "linked").symlink_to(outside, target_is_directory=True)
        empty = self.root / "empty"
        empty.mkdir()
        self.assertEqual(source_digest(self.repo, ["linked/secret.txt"]), source_digest(empty, ["linked/secret.txt"]))

    def test_http_comparison_contract_retains_auth_and_rejects_stale_queries(self):
        from http.server import ThreadingHTTPServer
        from urllib.parse import urlencode
        from urllib.request import Request, urlopen
        from urllib.error import HTTPError
        from herdr_harness.server import make_handler
        runtime, store, row = self.review()
        service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": "synthetic-token", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest"}, pr_review_store=store, pr_review=runtime)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def get(suffix, token="synthetic-token"):
            request = Request(f"http://127.0.0.1:{server.server_port}/api/v1/pr-reviews/{row['id']}/" + suffix, headers={"Authorization": "Bearer " + token})
            try: response = urlopen(request)
            except HTTPError as error: response = error
            with response: return response.status, json.loads(response.read())
        try:
            self.assertEqual(get("commits", "synthetic-ingest")[0], 401)
            status, history = get("commits?" + urlencode({"base_sha": self.base, "head_sha": self.head}))
            self.assertEqual(status, 200)
            self.assertEqual(history["baseline_sha"], self.base)
            status, diff = get("diff?" + urlencode({"mode": "commit", "start_commit": self.first, "path": "temporary.txt", "base_sha": self.base, "head_sha": self.head}))
            self.assertEqual(status, 200)
            self.assertEqual(diff["comparison"]["after_sha"], self.first)
            self.assertEqual(diff["files"][0]["path"], "temporary.txt")
            self.assertEqual(get("diff?mode=all&mode=commit")[0], 400)
            self.assertEqual(get("commits?head_sha=" + self.first)[0], 409)
            status, file = get("file?" + urlencode({"mode": "commit", "start_commit": self.first, "path": "temporary.txt", "side": "after"}))
            self.assertEqual(status, 200)
            self.assertEqual(file["text"], "temporary evidence\n")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__": unittest.main()
