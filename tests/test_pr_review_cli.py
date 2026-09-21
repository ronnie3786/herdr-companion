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
