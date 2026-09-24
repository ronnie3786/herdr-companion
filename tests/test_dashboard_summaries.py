"""Dashboard summaries are small, cached, and explicit about stale data."""
import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.pr_review_runtime import PRReviewRuntime
from herdr_harness.pr_review_status import REVIEW_QUERY, viewer_review_summary
from herdr_harness.pr_review_store import PRReviewStore


def github_pull(state="APPROVED", *, head="head", reviewed="head", requested=False,
                request_date="2026-01-01T00:00:00Z", drafts=None, own=False):
    return {"headRefOid": head, "viewerDidAuthor": own,
            "viewerLatestReviewRequest": {"id": "request"} if requested else None,
            "reviews": {"nodes": [{"state": state, "submittedAt": "2026-01-02T00:00:00Z",
                                    "commit": {"oid": reviewed}}] if state else []},
            "pending": {"nodes": [{"comments": {"totalCount": drafts}}] if drafts is not None else []},
            "timelineItems": {"nodes": [{"createdAt": request_date, "requestedReviewer": {"login": "synthetic-reviewer"}}],
                              "pageInfo": {"hasPreviousPage": False}}}


class FirstMateDashboardTests(unittest.TestCase):
    def setUp(self):
        self.store = FirstMateStore(":memory:")
        self.addCleanup(self.store.close)
        self.feature = self.store.create_feature({"title": "Garden irrigation", "goal": "Design garden irrigation.",
            "cwd": "/tmp/synthetic-garden", "request_id": "create"})

    def test_list_projects_current_stage_counts_and_bounded_message_without_snapshots(self):
        message = self.store.claim_message(self.feature["id"], "coordinator")
        visit = self.store.start_visit(self.feature["id"], "plan", "Plan irrigation", "stage", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "A" * 2000)
        assignment = self.store.create_assignment(visit["id"], {"title": "Review watering design", "role": "reviewer", "prompt": "Review it", "request_id": "assign"})
        self.store.claim_assignment(assignment["id"], "worker")
        with patch.object(self.store, "snapshot", side_effect=AssertionError("Do not load transcripts")):
            summary = self.store.list_features()[0]["dashboard_summary"]
        self.assertEqual(summary["current_stage_title"], "Plan irrigation")
        self.assertEqual((summary["current_stage_index"], summary["stage_count"]), (1, 1))
        self.assertTrue(summary["stage_count_is_estimate"])
        self.assertEqual((summary["assignment_count"], summary["running_assignment_count"]), (1, 1))
        self.assertEqual(len(summary["latest_message"]), 1200)
        self.assertFalse(summary["needs_user"])
        self.assertIsNone(summary["needs_user_prompt"])

    def test_empty_and_future_status_do_not_fabricate_attention(self):
        summary = self.store.list_features()[0]["dashboard_summary"]
        self.assertEqual(summary["stage_count"], 0)
        self.assertIsNone(summary["current_stage_title"])
        self.assertIsNone(summary["latest_message"])
        self.store._db.execute("UPDATE fm_features SET status='future_status'")
        self.assertFalse(self.store.list_features()[0]["dashboard_summary"]["needs_user"])

    def test_human_gate_prompt_and_archive_scope(self):
        message = self.store.claim_message(self.feature["id"], "coordinator")
        visit = self.store.start_visit(self.feature["id"], "plan", "Planning", "stage", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Design is ready.")
        assignment = self.store.create_assignment(visit["id"], {"title": "Plan", "role": "planner", "prompt": "Plan", "request_id": "assign"})
        claimed = self.store.claim_assignment(assignment["id"], "worker")
        self.store.bind_session(assignment["id"], claimed["generation"], "worker", "synthetic-session", "/tmp/synthetic-session.jsonl", "run")
        self.store.request_human_gate(assignment["id"], claimed["generation"], "synthetic-session", "Choose drip or sprinkler irrigation.", "gate")
        summary = self.store.list_features()[0]["dashboard_summary"]
        self.assertTrue(summary["needs_user"])
        self.assertEqual(summary["needs_user_prompt"], "Choose drip or sprinkler irrigation.")
        self.assertEqual(summary["running_assignment_count"], 0)
        self.store.set_archived(self.feature["id"], True, {"request_id": "archive"})
        self.assertEqual(self.store.list_features(), [])
        self.assertEqual(self.store.list_features("archived")[0]["dashboard_summary"], summary)


class ViewerReviewProjectionTests(unittest.TestCase):
    def test_submitted_states_and_never_reviewed(self):
        for github, expected in (("APPROVED", "approved"), ("CHANGES_REQUESTED", "changes_requested"),
                                 ("COMMENTED", "commented"), ("DISMISSED", "not_reviewed"), (None, "not_reviewed")):
            with self.subTest(github=github):
                result = viewer_review_summary(github_pull(github), "synthetic-reviewer")
                self.assertEqual(result["state"], expected)
                self.assertFalse(result["needs_user"])

    def test_pending_drafts_take_priority_and_own_pr_does_not_need_viewer(self):
        result = viewer_review_summary(github_pull(head="new", drafts=3), "synthetic-reviewer")
        self.assertEqual(result["state"], "pending")
        self.assertEqual(result["pending_comment_count"], 3)
        self.assertTrue(result["needs_user"])
        own = viewer_review_summary(github_pull(drafts=0, own=True), "synthetic-reviewer")
        self.assertTrue(own["is_own_pr"])
        self.assertFalse(own["needs_user"])

    def test_new_commits_or_new_requests_after_review_need_attention(self):
        for pull in (github_pull(head="new"), github_pull(requested=True, request_date="2026-01-03T00:00:00Z"),
                     github_pull(requested=True, request_date="2026-01-02T00:00:00.100Z")):
            result = viewer_review_summary(pull, "synthetic-reviewer")
            self.assertEqual(result["state"], "re_review_requested")
            self.assertTrue(result["needs_user"])
        self.assertEqual(viewer_review_summary(github_pull(requested=True), "synthetic-reviewer")["state"], "approved")
        self.assertEqual(viewer_review_summary(github_pull(None, requested=True), "synthetic-reviewer")["state"], "not_reviewed")
        other = github_pull(requested=True, request_date="2026-01-03T00:00:00Z")
        other["timelineItems"]["nodes"][0]["requestedReviewer"]["login"] = "someone-else"
        self.assertEqual(viewer_review_summary(other, "synthetic-reviewer")["state"], "approved")

    def test_missing_or_truncated_ambiguous_data_is_not_fresh_not_reviewed(self):
        with self.assertRaises((KeyError, ValueError)):
            viewer_review_summary({}, "synthetic-reviewer")
        pull = github_pull(requested=True)
        pull["timelineItems"] = {"nodes": [], "pageInfo": {"hasPreviousPage": True}}
        with self.assertRaises(ValueError):
            viewer_review_summary(pull, "synthetic-reviewer")
        self.assertIn("author:$viewer", REVIEW_QUERY)


class PRDashboardCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = PRReviewStore(Path(self.temp.name) / "review.sqlite3")
        self.addCleanup(self.store.close)
        self.review = self.store.create_review({"url": "https://github.com/example-owner/garden/pull/42", "host": "github.com",
            "owner": "example-owner", "repo": "garden", "number": 42, "request_id": "create"})
        self.calls = []
        self.failed = False
        self.bad_data = False
        self.changed = []
        self.runtime = PRReviewRuntime(SimpleNamespace(pr_review_changed=self.changed.append), self.store,
            environ={"HERDR_HARNESS_API_TOKEN": "synthetic-not-forwarded"}, runtime_root=self.temp.name, runner=self.run_command)

    def run_command(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        self.assertLessEqual(kwargs["timeout"], 15)
        self.assertNotIn("HERDR_HARNESS_API_TOKEN", kwargs["env"])
        if self.failed:
            return SimpleNamespace(returncode=1, stdout="", stderr="private-path-and-token")
        data = {"viewer": {"login": "synthetic-reviewer"}} if "query { viewer { login } }" in " ".join(argv) else {"repository": {"pullRequest": github_pull()}}
        if self.bad_data and "repository" in data:
            data = {"repository": {"pullRequest": {}}}
        return SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({"data": data}))

    def test_cached_status_retains_freshness_on_error_and_list_has_no_network(self):
        self.assertEqual(self.store.list_reviews()[0]["viewer_review"]["state"], "unknown")
        original = self.store.get_review(self.review["id"])
        self.runtime._refresh_review_statuses([self.review])
        summary = self.store.list_reviews()[0]["viewer_review"]
        self.assertEqual(summary["state"], "approved")
        self.assertIsNotNone(summary["updated_at"])
        self.assertEqual(len(self.calls), 2)
        self.failed = True
        self.runtime._refresh_review_statuses([self.review])
        stale = self.store.list_reviews()[0]["viewer_review"]
        self.assertEqual(stale["state"], "approved")
        self.assertEqual(stale["updated_at"], summary["updated_at"])
        self.assertIsNotNone(stale["error"])
        self.assertNotIn("private-path-and-token", json.dumps(stale))
        refreshed = self.store.get_review(self.review["id"])
        self.assertEqual(original["revision"], refreshed["revision"])
        self.assertEqual(original["updated_at"], refreshed["updated_at"])
        self.assertEqual(len(self.calls), 3)

    def test_invalid_github_data_preserves_unknown_and_records_failed_attempt(self):
        self.bad_data = True
        self.runtime._refresh_review_statuses([self.review])
        summary = self.store.list_reviews()[0]["viewer_review"]
        self.assertEqual(summary["state"], "unknown")
        self.assertIsNone(summary["updated_at"])
        self.assertIsNotNone(summary["checked_at"])
        self.assertIsNotNone(summary["error"])

    def test_refresh_coalesces_in_flight_requests_and_obeys_interval(self):
        entered, release = threading.Event(), threading.Event()
        def worker(_reviews):
            entered.set()
            release.wait(3)
        with patch.object(self.runtime, "_refresh_review_statuses", side_effect=worker) as work:
            try:
                self.assertTrue(self.runtime.schedule_review_status_refresh(force=True))
                self.assertTrue(entered.wait(2))
                self.assertTrue(self.runtime.schedule_review_status_refresh(force=True))
                self.assertEqual(work.call_count, 1)
            finally:
                release.set()
                self.runtime._review_status_thread.join(3)
            self.assertFalse(self.runtime.schedule_review_status_refresh())
            self.assertEqual(work.call_count, 1)

    def test_skill_summary_uses_latest_run_and_does_not_load_snapshots(self):
        self.store.update_review(self.review["id"], status="ready")
        first = self.store.create_run(self.review["id"], "ios-review-remote-pr", "first")
        self.store.update_run(self.review["id"], first["id"], state="finished", finished_at="2026-01-01T00:00:00Z")
        second = self.store.create_run(self.review["id"], "ios-review-remote-pr", "second")
        with patch.object(self.store, "snapshot", side_effect=AssertionError("Do not load snapshots")):
            skills = self.store.list_reviews()[0]["skill_runs"]
        self.assertEqual(len(skills), 1)
        self.assertEqual(skills[0]["state"], second["state"])
        self.assertEqual(skills[0]["title"], second["skill_title"])
