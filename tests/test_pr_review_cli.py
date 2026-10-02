import io
import json
import tempfile
import unittest
import urllib.error
from pathlib import Path

from scripts import herdr_pr_review_cli as cli


class Reply:
    def __init__(self, request, value, *, raw=False):
        self.request = request
        self.value = value
        self.raw = raw
        self.read_once = False
        self.headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def geturl(self):
        return self.request.full_url

    def read(self, _maximum):
        if self.read_once:
            return b""
        self.read_once = True
        return self.value if self.raw else json.dumps(self.value).encode()


class PRReviewCLITests(unittest.TestCase):
    environ = {
        "HERDR_HARNESS_API_TOKEN": "synthetic-token",
        "HERDR_HARNESS_URL": "https://host.example.test",
    }

    def run_cli(self, argv, replies=None, stdin="", environ=None):
        self.requests = []
        self.launches = []
        queue = list(replies or [{"ok": True, "review": {"id": "prr_sample"}}])

        def opener(request, **_kwargs):
            self.requests.append(request)
            reply = queue.pop(0)
            if isinstance(reply, Exception):
                raise reply
            if isinstance(reply, bytes):
                return Reply(request, reply, raw=True)
            return Reply(request, reply)

        output, error = io.StringIO(), io.StringIO()
        code = cli.main(
            argv,
            environ=environ or self.environ,
            stdin=io.StringIO(stdin),
            stdout=output,
            stderr=error,
            opener=opener,
            launch=lambda *args, **_kwargs: self.launches.append(args),
        )
        return code, json.loads(output.getvalue() or error.getvalue())

    def test_create_and_mark_preserve_request_payloads(self):
        code, _ = self.run_cli(["create", "--url", "https://github.com/example-owner/garden/pull/42", "--skill", "comprehensive-pr-review", "--request-id", "create-one"])
        self.assertEqual(code, 0)
        self.assertEqual(self.requests[0].full_url, "https://host.example.test/api/v1/pr-reviews")
        self.assertEqual(json.loads(self.requests[0].data), {
            "url": "https://github.com/example-owner/garden/pull/42",
            "skill_ids": ["comprehensive-pr-review"],
            "request_id": "create-one",
        })

        code, _ = self.run_cli(["mark", "prr_sample", "--skill", "comprehensive-pr-review", "--state", "not-run", "--request-id", "mark-one"])
        self.assertEqual(code, 0)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(json.loads(self.requests[0].data), {
            "state": "not_run", "note": "", "request_id": "mark-one",
        })

    def test_rankings_viewed_and_run_defaults(self):
        code, _ = self.run_cli(["set-rankings", "prr_sample", "--file", "-", "--request-id", "rank-one"], stdin='[{"path":"Sources/Garden.py","impact":"high"}]')
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.requests[0].data)["files"][0]["path"], "Sources/Garden.py")

        code, _ = self.run_cli(["viewed", "prr_sample", "--path", "a", "--path", "b", "--request-id", "view-one"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.requests[0].data), {
            "paths": ["a", "b"], "viewed": True, "sync_github": True, "request_id": "view-one",
        })
        code, _ = self.run_cli(["viewed", "prr_sample", "--path", "a", "--unviewed", "--no-github", "--request-id", "view-two"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.requests[0].data)["viewed"], False)
        self.assertFalse(json.loads(self.requests[0].data)["sync_github"])

        code, _ = self.run_cli(["finish-run", "--request-id", "finish-one"], environ={**self.environ, "HERDR_PR_REVIEW_ID": "prr_env", "HERDR_PR_REVIEW_RUN_ID": "prun_env"})
        self.assertEqual(code, 0)
        self.assertIn("/prr_env/runs/prun_env/finish", self.requests[0].full_url)

    def test_open_path_escaping_auth_failure_and_conflict(self):
        code, result = self.run_cli(["open", "prr_sample", "--print-url"])
        self.assertEqual(code, 0)
        self.assertEqual(self.requests[0].method, "GET")
        self.assertEqual(self.launches, [])
        self.assertNotIn("synthetic-token", result["url"])

        self.run_cli(["get", "../x"])
        self.assertIn("/..%2Fx", self.requests[0].full_url)

        code, _ = self.run_cli(["--base-url", "http://host.example.test", "get", "prr_sample"])
        self.assertEqual(code, 2)
        self.assertEqual(self.requests, [])

        error = urllib.error.HTTPError("https://host.example.test/api/v1/pr-reviews/prr_sample", 409, "Conflict", {}, io.BytesIO(b'{"error":{"code":"stale","message":"Conflict"}}'))
        code, _ = self.run_cli(["get", "prr_sample"], replies=[error])
        self.assertEqual(code, 4)

    def test_local_comments_preserve_markdown_and_require_observed_revision(self):
        markdown = "SwiftUI reviewer: question\n\n```swift\nlet value = 1\n```\n  "
        code, _ = self.run_cli(["comment", "prr_sample", "--body-file", "-", "--request-id", "comment-one"], stdin=markdown)
        self.assertEqual(code, 0)
        self.assertEqual(self.requests[0].full_url, "https://host.example.test/api/v1/pr-reviews/prr_sample/comments")
        self.assertEqual(json.loads(self.requests[0].data), {"body": markdown, "author": "agent", "request_id": "comment-one"})

        code, _ = self.run_cli(["comment", "prr_sample", "--body", "Question", "--path", "Sources/Garden.swift", "--side", "after", "--start", "3"])
        self.assertEqual(code, 2)
        self.assertEqual(self.requests, [])

        base, head = "a" * 40, "b" * 40
        code, _ = self.run_cli(["comment", "prr_sample", "--body", "Question", "--author", "human", "--path", "Sources/Garden.swift",
            "--side", "after", "--start", "3", "--base-sha", base, "--head-sha", head, "--mode", "commit", "--start-commit", head])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.requests[0].data)["anchor"], {
            "path": "Sources/Garden.swift", "side": "after", "start_line": 3, "end_line": 3,
            "base_sha": base, "head_sha": head, "comparison": {"mode": "commit", "start_commit": head}})
        self.assertEqual(json.loads(self.requests[0].data)["author"], "human")

    def test_comment_lifecycle_uses_versions_and_explicit_thread_identity(self):
        code, _ = self.run_cli(["comments", "prr_sample", "--state", "open", "--path", "Sources/Garden.swift"])
        self.assertEqual(code, 0)
        self.assertIn("/comments?state=open&path=Sources%2FGarden.swift", self.requests[0].full_url)
        code, _ = self.run_cli(["comments", "prr_sample", "--thread", "prct_one"])
        self.assertEqual(code, 0)
        self.assertTrue(self.requests[0].full_url.endswith("/comments/prct_one"))

        code, _ = self.run_cli(["reply", "--thread", "prct_one", "--body", "Answer", "--request-id", "reply-one"],
            environ={**self.environ, "HERDR_PR_REVIEW_ID": "prr_env"})
        self.assertEqual(code, 0)
        self.assertTrue(self.requests[0].full_url.endswith("/prr_env/comments/prct_one/replies"))
        self.assertEqual(json.loads(self.requests[0].data), {"body": "Answer", "author": "agent", "request_id": "reply-one"})
        for name, state in (("resolve", "resolved"), ("reopen", "open")):
            code, _ = self.run_cli([name, "prr_sample", "--thread", "prct_one", "--expected-version", "2", "--request-id", name])
            self.assertEqual(code, 0)
            self.assertTrue(self.requests[0].full_url.endswith("/comments/prct_one/state"))
            self.assertEqual(json.loads(self.requests[0].data), {"state": state, "author": "agent", "expected_version": 2, "request_id": name})
        code, _ = self.run_cli(["edit-comment", "prr_sample", "--thread", "prct_one", "--message", "prcm_one",
            "--expected-version", "3", "--author", "human", "--body", "Correction"])
        self.assertEqual(code, 0)
        self.assertEqual(self.requests[0].method, "PUT")
        self.assertTrue(self.requests[0].full_url.endswith("/comments/prct_one/messages/prcm_one"))

    def test_comment_failures_send_no_request_and_never_launch_github(self):
        for argv in (["comment", "prr_sample", "--body", " "],
                     ["comment", "prr_sample", "--body", "x" * 20001],
                     ["resolve", "prr_sample", "--thread", "prct_one", "--expected-version", "0"],
                     ["resolve", "prr_sample", "--thread", "prct_one"],
                     ["comments", "prr_sample", "--thread", "prct_one", "--state", "open"]):
            code, _ = self.run_cli(argv)
            self.assertEqual(code, 2)
            self.assertEqual(self.requests, [])
            self.assertEqual(self.launches, [])

    def test_diff_cli_exposes_pinned_comparisons_to_agents(self):
        base, head = "a" * 40, "b" * 40
        code, _ = self.run_cli(["diff", "prr_sample", "--mode", "range", "--start-commit", base, "--end-commit", head,
            "--base-sha", base, "--head-sha", head, "--path", "Sources/Garden.swift"])
        self.assertEqual(code, 0)
        self.assertIn("mode=range", self.requests[0].full_url)
        self.assertIn("base_sha=" + base, self.requests[0].full_url)
        code, _ = self.run_cli(["commits", "prr_sample", "--head-sha", head])
        self.assertEqual(code, 0)
        self.assertTrue(self.requests[0].full_url.endswith("/commits?head_sha=" + head))

    def test_document_download_and_state_command(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "findings.md"
            code, result = self.run_cli(["document", "prr_sample", "prdoc_sample", "--out", str(destination)], replies=[b"exact synthetic bytes"])
            self.assertEqual(code, 0)
            self.assertEqual(destination.read_bytes(), b"exact synthetic bytes")
            self.assertEqual(result["bytes"], len(b"exact synthetic bytes"))

            code, _ = self.run_cli(["add-document", "prr_sample", "--link", "https://example.test/reference", "--request-id", "link"])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(self.requests[0].data)["title"], "https://example.test/reference")

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "large-findings.md"
            large = b"x" * (33 * 1024 * 1024)
            code, result = self.run_cli(["document", "prr_sample", "prdoc_sample", "--out", str(destination)], replies=[large])
            self.assertEqual(code, 0)
            self.assertEqual(result["bytes"], len(large))
            self.assertEqual(destination.stat().st_size, len(large))

        replies = [
            {"ok": True, "clients": [{"clientId": "ui-sample", "online": True, "actions": [{"id": "pr-review.state", "enabled": True}]}]},
            {"ok": True, "command": {"id": "command-sample"}},
            {"ok": True, "command": {"status": "completed", "result": {"reviewId": "prr_sample"}, "error": None}},
        ]
        code, result = self.run_cli(["state", "--request-id", "state-one"], replies=replies)
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(json.loads(self.requests[1].data)["action"], "pr-review.state")


if __name__ == "__main__":
    unittest.main()
