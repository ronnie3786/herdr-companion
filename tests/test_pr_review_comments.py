"""Local PR discussion keeps immutable anchors, receipts and durable history."""
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.git_comparison import comparison_identity
from herdr_harness.pr_review_diff import parse_unified_diff
from herdr_harness.pr_review_runtime import PRReviewRuntime
from herdr_harness.pr_review_store import PRReviewError, PRReviewStore
from herdr_harness.server import make_handler
from herdr_harness.workspace_tools import WorkspaceToolError


BASE, HEAD, MERGE = "a" * 40, "b" * 40, "c" * 40
PATCH = """diff --git a/Old.swift b/New.swift
similarity index 75%
rename from Old.swift
rename to New.swift
--- a/Old.swift
+++ b/New.swift
@@ -1,3 +1,4 @@
 shared
-old
+new
+inserted
 end
diff --git a/Removed.swift b/Removed.swift
deleted file mode 100644
--- a/Removed.swift
+++ /dev/null
@@ -1 +0,0 @@
-removed
"""


class CommentFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.database = Path(self.temp.name) / "reviews.sqlite3"
        self.store = PRReviewStore(self.database)
        self.addCleanup(lambda: self.store.close())
        self.changed = []
        self.service = SimpleNamespace(
            environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token"},
            pr_review_store=self.store, pr_review_changed=self.changed.append)
        self.runtime = PRReviewRuntime(self.service, self.store, environ={}, runtime_root=self.temp.name,
            runner=lambda *_args, **_kwargs: self.fail("A comment attempted to run an external command"))
        self.service.pr_review = self.runtime
        self.review_id = self.new_review(42)

    def new_review(self, number):
        review = self.store.create_review({"url": f"https://github.com/example-owner/garden/pull/{number}",
            "host": "github.com", "owner": "example-owner", "repo": "garden", "number": number, "request_id": str(number)})
        self.store.complete_preparation(review["id"], parse_unified_diff(PATCH), status="ready", base_sha=BASE, head_sha=HEAD, merge_base_sha=MERGE)
        directory = self.runtime._review_dir(review["id"])
        directory.mkdir(parents=True)
        (directory / "diff.json").write_text(json.dumps({"files": parse_unified_diff(PATCH), "truncated": False}))
        return review["id"]

    def payload(self, request_id="create-comment", **values):
        return {"body": "Python reviewer: verify this assumption.\n\n```python\ncheck()\n```\n", "author": "agent", "request_id": request_id, **values}

    def anchor(self, **values):
        return {"path": "New.swift", "side": "after", "start_line": 2, "end_line": 3, "base_sha": BASE, "head_sha": HEAD, **values}

    def create(self, **values):
        return self.runtime.create_comment_thread(self.review_id, self.payload(**values))


class PRReviewCommentsTests(CommentFixture):
    def test_general_comments_replies_edits_and_lifecycle_survive_restart(self):
        thread = self.create()
        self.assertIsNone(thread["anchor"])
        self.assertEqual(thread["messages"][0]["author"], "agent")
        self.assertEqual(thread["messages"][0]["body"], self.payload()["body"])
        reply = self.payload("reply", body="Human question\n  exact whitespace  ", author="human")
        replied = self.store.reply_comment_thread(self.review_id, thread["id"], reply)
        self.assertEqual(replied["version"], 2)
        self.assertEqual(self.store.reply_comment_thread(self.review_id, thread["id"], reply), replied)
        resolved = self.store.set_comment_state(self.review_id, thread["id"], {
            "state": "resolved", "author": "human", "expected_version": 2, "request_id": "resolve"})
        self.store.update_review(self.review_id, head_sha="d" * 40)
        reopened = self.store.set_comment_state(self.review_id, thread["id"], {
            "state": "open", "author": "agent", "expected_version": resolved["version"], "request_id": "reopen"})
        edited = self.store.edit_comment_message(self.review_id, thread["id"], thread["messages"][0]["id"], {
            "body": "Corrected finding", "author": "human", "expected_version": reopened["version"], "request_id": "edit"})
        self.assertEqual(edited["messages"][0]["author"], "agent")
        self.assertEqual(edited["history"][-1]["author"], "human")
        self.assertEqual(edited["history"][-1]["previous_body"], self.payload()["body"])
        self.assertEqual([event["action"] for event in edited["history"]], ["created", "replied", "resolved", "reopened", "edited"])
        self.assertEqual(edited["history"][-2]["head_sha"], "d" * 40)
        self.assertFalse(edited["outdated"])
        self.store.archive(self.review_id, "archive")
        self.store.close()
        self.store = PRReviewStore(self.database)
        self.assertEqual(self.store.comment_thread(self.review_id, thread["id"]), edited)
        self.assertEqual(self.database.stat().st_mode & 0o777, 0o600)

    def test_inline_anchor_has_server_excerpt_and_remains_open_across_revision_change(self):
        thread = self.create(anchor=self.anchor())
        anchor = thread["anchor"]
        self.assertEqual(anchor["code_excerpt"], "+new\n+inserted")
        self.assertEqual(anchor["comparison"]["before_sha"], MERGE)
        self.assertEqual(anchor["spans"], [{"side": "after", "start": 2, "end": 3}])
        self.assertFalse(thread["outdated"])
        self.store.complete_preparation(self.review_id, [], base_sha="e" * 40, head_sha="d" * 40)
        current = self.store.comment_thread(self.review_id, thread["id"])
        self.assertTrue(current["outdated"])
        self.assertEqual(current["state"], "open")
        self.assertEqual(current["anchor"], anchor)
        self.assertEqual(self.store.comment_threads(self.review_id, path="New.swift", state="open"), [current])
        self.assertEqual(self.store.comment_threads(self.review_id, state="resolved"), [])
        # Lost-response retries recover the original record even after a push.
        self.assertEqual(self.create(anchor=self.anchor()), thread)
        self.assertEqual(len(self.store.comment_threads(self.review_id)), 1)

    def test_mixed_spans_and_deleted_side_use_exact_diff_rows(self):
        anchor = {"path": "New.swift", "base_sha": BASE, "head_sha": HEAD,
            "spans": [{"side": "before", "start": 1, "end": 2}, {"side": "after", "start": 1, "end": 3}]}
        thread = self.create(anchor=anchor)
        self.assertEqual(thread["anchor"]["code_excerpt"], " shared\n-old\n+new\n+inserted")
        self.assertEqual(thread["anchor"]["side"], "before")
        deleted = self.create(request_id="deleted", anchor=self.anchor(path="Removed.swift", side="before", start_line=1, end_line=1))
        self.assertEqual(deleted["anchor"]["code_excerpt"], "-removed")
        with self.assertRaises(PRReviewError):
            self.create(request_id="wrong-side", anchor=self.anchor(path="Removed.swift", start_line=1, end_line=1))

    def test_comparison_selection_and_identity_are_saved(self):
        selection = {"mode": "range", "start_commit": MERGE, "end_commit": HEAD}
        resolved = comparison_identity("range", MERGE, HEAD, [HEAD])
        with patch.object(self.runtime, "diff", return_value={"files": parse_unified_diff(PATCH), "comparison": resolved}) as diff:
            thread = self.create(anchor=self.anchor(comparison=selection))
        diff.assert_called_once_with(self.review_id, "New.swift", comparison=selection, base_sha=BASE, head_sha=HEAD)
        self.assertEqual(thread["anchor"]["comparison"], resolved)
        self.assertEqual(thread["anchor"]["comparison_selection"], selection)

    def test_invalid_fields_ranges_missing_lines_and_stale_revision_are_rejected(self):
        anchors = [self.anchor(path="../secret"), self.anchor(path="Old.swift"), self.anchor(path="unknown.swift"),
            self.anchor(base_sha="main"), self.anchor(head_sha=None), self.anchor(start_line=True), self.anchor(start_line=0),
            self.anchor(start_line=4, end_line=2), self.anchor(end_line=999), self.anchor(side="both"),
            self.anchor(code_excerpt="forged"), self.anchor(spans=[]), {"spans": [{"side": "after", "start": 2, "end": 2}]},
            self.anchor(start_line=10, end_line=11), self.anchor(comparison={"mode": "all", "extra": True}),
            self.anchor(comparison={"mode": []}), self.anchor(comparison={"mode": {}})]
        for index, anchor in enumerate(anchors):
            with self.subTest(anchor=anchor), self.assertRaises((PRReviewError, WorkspaceToolError)) as raised:
                self.create(request_id=f"invalid-{index}", anchor=anchor)
            self.assertEqual(raised.exception.status, 400)
        for index, value in enumerate((None, "", "   ", 9, "x" * 20001, "a\x00b")):
            with self.subTest(body=value), self.assertRaises(PRReviewError):
                self.create(request_id=f"invalid-body-{index}", body=value)
        for author in (None, "other", {}, []):
            with self.subTest(author=author), self.assertRaises(PRReviewError):
                self.create(author=author)
        with self.assertRaises(PRReviewError) as raised:
            self.create(anchor=self.anchor(head_sha="d" * 40))
        self.assertEqual(raised.exception.code, "stale_review_revision")
        self.assertEqual(self.store.comment_threads(self.review_id), [])

    def test_refresh_between_anchor_validation_and_commit_is_rejected(self):
        original = self.runtime._comment_anchor
        def advance(review_id, anchor):
            result = original(review_id, anchor)
            self.store.update_review(review_id, head_sha="d" * 40)
            return result
        with patch.object(self.runtime, "_comment_anchor", side_effect=advance), self.assertRaises(PRReviewError) as raised:
            self.create(anchor=self.anchor())
        self.assertEqual(raised.exception.code, "stale_review_revision")
        self.assertEqual(self.store.comment_threads(self.review_id), [])

    def test_receipt_conflicts_scope_isolation_and_stale_updates(self):
        thread = self.create()
        with self.assertRaises(PRReviewError) as conflict:
            self.create(body="different")
        self.assertEqual(conflict.exception.code, "idempotency_conflict")
        other = self.new_review(43)
        for action in (lambda: self.store.comment_thread(other, thread["id"]),
                       lambda: self.store.reply_comment_thread(other, thread["id"], self.payload("cross-review"))):
            with self.assertRaises(PRReviewError) as absent:
                action()
            self.assertEqual(absent.exception.status, 404)
        self.store.reply_comment_thread(self.review_id, thread["id"], self.payload("reply"))
        stale = {"author": "human", "expected_version": 1, "request_id": "stale"}
        with self.assertRaises(PRReviewError) as raised:
            self.store.set_comment_state(self.review_id, thread["id"], {**stale, "state": "resolved"})
        self.assertEqual(raised.exception.code, "stale_comment_version")
        with self.assertRaises(PRReviewError) as raised:
            self.store.edit_comment_message(self.review_id, thread["id"], thread["messages"][0]["id"], {**stale, "body": "stale edit"})
        self.assertEqual(raised.exception.code, "stale_comment_version")
        self.assertEqual(self.store.comment_thread(self.review_id, thread["id"])["state"], "open")

    def test_concurrent_replies_are_preserved_and_resolve_checks_version(self):
        thread = self.create()
        with ThreadPoolExecutor(max_workers=4) as workers:
            results = list(workers.map(lambda number: self.store.reply_comment_thread(
                self.review_id, thread["id"], self.payload(f"reply-{number}", body=f"Question {number}")), range(10)))
        self.assertEqual(len(results), 10)
        current = self.store.comment_thread(self.review_id, thread["id"])
        self.assertEqual(len(current["messages"]), 11)
        self.assertEqual(current["version"], 11)
        self.assertEqual(len(current["history"]), 11)


class PRReviewCommentsHTTPTests(CommentFixture):
    def setUp(self):
        super().setUp()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.path = f"/api/v1/pr-reviews/{self.review_id}/comments"

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path, body=None, *, token="synthetic-main-token", method=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=headers)
        try:
            response = urllib.request.urlopen(request)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def test_auth_capability_full_lifecycle_and_no_github_calls(self):
        for token in (None, "synthetic-ingest-token", "wrong"):
            self.assertEqual(self.request(self.path, token=token)[0], 401)
            self.assertEqual(self.request(self.path, self.payload(), token=token, method="POST")[0], 401)
        for path in ("/api/v1", "/api/v1/pr-reviews/capabilities"):
            self.assertIn("pr-review-comments-v1", self.request(path)[1]["capabilities"])
        status, body = self.request(self.path, self.payload(anchor=self.anchor()), method="POST")
        self.assertEqual(status, 201)
        thread = body["thread"]
        path = self.path + "/" + thread["id"]
        self.assertEqual(self.request(path)[1]["thread"], thread)
        self.assertEqual(self.request(self.path + "?state=open&path=New.swift")[1]["threads"], [thread])
        status, body = self.request(path + "/replies", self.payload("reply", author="human"), method="POST")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["thread"]["messages"]), 2)
        status, resolved = self.request(path + "/state", {"state": "resolved", "author": "human", "expected_version": 2, "request_id": "resolve"}, method="POST")
        self.assertEqual(status, 200)
        self.assertEqual(resolved["thread"]["state"], "resolved")
        status, conflict = self.request(path + "/state", {"state": "open", "author": "agent", "expected_version": 2, "request_id": "stale"}, method="POST")
        self.assertEqual(status, 409)
        self.assertEqual(conflict["error"]["code"], "stale_comment_version")
        status, edited = self.request(path + "/messages/" + thread["messages"][0]["id"], {
            "body": "Updated finding", "author": "agent", "expected_version": 3, "request_id": "edit"}, method="PUT")
        self.assertEqual(status, 200)
        self.assertEqual(edited["thread"]["messages"][0]["body"], "Updated finding")
        self.assertEqual(len(self.changed), 4)

    def test_validation_does_not_create_partial_records(self):
        for body in ({}, self.payload(extra=True), self.payload(anchor=self.anchor(code_excerpt="fake")), self.payload(author="robot")):
            self.assertEqual(self.request(self.path, body, method="POST")[0], 400)
        for query in ("?state=unknown", "?state=open&state=resolved", "?extra=x"):
            self.assertEqual(self.request(self.path + query)[0], 400)
        self.assertEqual(self.request(self.path)[1]["threads"], [])
        self.assertEqual(self.request(self.path + "/missing")[0], 404)


if __name__ == "__main__":
    unittest.main()
