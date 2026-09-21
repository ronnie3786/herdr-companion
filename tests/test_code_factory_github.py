"""argv construction, status folding and error mapping of the ``gh`` wrapper (fake runner only)."""
from __future__ import annotations

import http.client
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.github import GitHubClient

REPO = "owner/repo"


class FakeRunner:
    """Records every ``gh`` invocation and replies from a scripted queue."""

    def __init__(self):
        self.calls: list[dict] = []
        self.replies: list[SimpleNamespace] = []
        self.on_call = None

    def reply(self, stdout="", returncode=0, stderr=""):
        self.replies.append(SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr))
        return self

    def reply_json(self, payload):
        return self.reply(json.dumps(payload))

    def __call__(self, argv, **kwargs):
        self.calls.append({"argv": list(argv), **kwargs})
        if self.on_call is not None:
            self.on_call(argv, kwargs)
        if self.replies:
            return self.replies.pop(0)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    @property
    def argv(self) -> list[list[str]]:
        return [call["argv"] for call in self.calls]


class FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class GitHubClientTestCase(unittest.TestCase):
    def setUp(self):
        self.runner = FakeRunner()
        self.sleeps: list[float] = []
        self.environ = {
            "PATH": "/usr/bin", "HOME": "/home/your-username", "OLLAMA_API_KEY": "provider-secret",
            "HERDR_HARNESS_API_TOKEN": "control-secret", "HERDR_STATE_DIR": "/home/your-username/state",
            "HERDR_CODE_FACTORY_DASHBOARD_TOKEN": "dash-secret",
        }
        self.client = GitHubClient(REPO, runner=self.runner, environ=self.environ, timeout=45, sleep=self.sleeps.append)


class ArgvTests(GitHubClientTestCase):
    def test_repository_validation(self):
        with self.assertRaises(CodeFactoryError) as caught:
            GitHubClient("not-a-repo", runner=self.runner, environ=self.environ)
        self.assertEqual(caught.exception.code, "invalid_settings")

    def test_environment_strips_herdr_but_keeps_provider_keys(self):
        self.runner.reply_json([])
        self.client.list_issues("herdr-autofix")
        env = self.runner.calls[0]["env"]
        self.assertFalse([key for key in env if key.startswith("HERDR_")])
        self.assertEqual(env["OLLAMA_API_KEY"], "provider-secret")
        self.assertEqual(self.runner.calls[0]["timeout"], 45)
        self.assertTrue(self.runner.calls[0]["capture_output"])
        self.assertTrue(self.runner.calls[0]["text"])
        self.assertEqual(self.runner.calls[0]["errors"], "replace", "non-UTF-8 output never raises UnicodeDecodeError")

    def test_list_issues(self):
        self.runner.reply_json([{"number": 12, "title": "Crash"}, {"bogus": True}, "junk"])
        issues = self.client.list_issues("herdr-autofix")
        self.assertEqual(issues, [{"number": 12, "title": "Crash"}])
        self.assertEqual(self.runner.argv[0], [
            "gh", "issue", "list", "--repo", REPO, "--label", "herdr-autofix", "--state", "open", "--limit", "100",
            "--json", "number,title,body,author,labels,url,createdAt,updatedAt",
        ])
        with self.assertRaises(CodeFactoryError):
            self.client.list_issues("bad,label")

    def test_get_issue(self):
        self.runner.reply_json({"number": 12, "state": "OPEN"})
        self.assertEqual(self.client.get_issue(12)["state"], "OPEN")
        self.assertEqual(self.runner.argv[0], [
            "gh", "issue", "view", "12", "--repo", REPO,
            "--json", "number,title,body,author,labels,url,createdAt,updatedAt,state",
        ])
        self.runner.reply("[]")
        with self.assertRaises(CodeFactoryError):
            self.client.get_issue(12)
        with self.assertRaises(CodeFactoryError):
            self.client.get_issue(0)

    def test_labels(self):
        self.client.add_labels(12, "released", "herdr-autofix")
        self.client.remove_labels(12, "herdr-autofix")
        self.client.add_labels(12)
        self.assertEqual(self.runner.argv, [
            ["gh", "issue", "edit", "12", "--repo", REPO, "--add-label", "released", "--add-label", "herdr-autofix"],
            ["gh", "issue", "edit", "12", "--repo", REPO, "--remove-label", "herdr-autofix"],
        ])

    def test_comment_uses_body_file(self):
        seen: dict = {}

        def capture(argv, kwargs):
            path = Path(argv[argv.index("--body-file") + 1])
            seen["body"] = path.read_text(encoding="utf-8")

        self.runner.on_call = capture
        self.client.comment_issue(12, "Picked up.\n\nProgress: http://example.invalid/")
        argv = self.runner.argv[0]
        self.assertEqual(argv[:6], ["gh", "issue", "comment", "12", "--repo", REPO])
        self.assertEqual(argv[6], "--body-file")
        self.assertEqual(seen["body"], "Picked up.\n\nProgress: http://example.invalid/")
        self.assertFalse(Path(argv[7]).exists(), "temporary body file is removed after the call")
        with self.assertRaises(CodeFactoryError):
            self.client.comment_issue(12, "   ")

    def test_close_issue(self):
        self.client.close_issue(12)
        self.client.close_issue(13, comment="Released in macos-v1")
        self.assertEqual(self.runner.argv, [
            ["gh", "issue", "close", "12", "--repo", REPO, "--reason", "completed"],
            ["gh", "issue", "close", "13", "--repo", REPO, "--reason", "completed", "--comment", "Released in macos-v1"],
        ])

    def test_create_pull_request(self):
        seen: dict = {}

        def capture(argv, kwargs):
            if "--body-file" in argv:
                seen["body"] = Path(argv[argv.index("--body-file") + 1]).read_text(encoding="utf-8")

        self.runner.on_call = capture
        self.runner.reply("https://github.com/owner/repo/pull/34\n")
        self.runner.reply_json({"number": 34, "url": "https://github.com/owner/repo/pull/34"})
        result = self.client.create_pull_request("codefactory/issue-12", "main", "Fix crash", "Refs #12\n\nBody")
        self.assertEqual(result, {"number": 34, "url": "https://github.com/owner/repo/pull/34"})
        create, view = self.runner.argv
        self.assertEqual(create[:12], [
            "gh", "pr", "create", "--repo", REPO, "--head", "codefactory/issue-12", "--base", "main",
            "--title", "Fix crash", "--body-file",
        ])
        self.assertEqual(seen["body"], "Refs #12\n\nBody")
        self.assertEqual(view, ["gh", "pr", "view", "codefactory/issue-12", "--repo", REPO, "--json", "number,url"])
        self.assertGreaterEqual(self.runner.calls[0]["timeout"], 120)

    def test_find_pull_request_prefers_open(self):
        self.runner.reply_json([
            {"number": 30, "url": "u30", "state": "CLOSED", "headRefOid": "aaa"},
            {"number": 31, "url": "u31", "state": "OPEN", "headRefOid": "bbb"},
        ])
        found = self.client.find_pull_request("codefactory/issue-12")
        self.assertEqual(found, {"number": 31, "url": "u31", "state": "OPEN", "headRefOid": "bbb"})
        self.assertEqual(self.runner.argv[0], [
            "gh", "pr", "list", "--repo", REPO, "--head", "codefactory/issue-12", "--state", "all",
            "--json", "number,url,state,headRefOid",
        ])
        self.runner.reply_json([])
        self.assertIsNone(self.client.find_pull_request("codefactory/issue-13"))

    def test_pull_request_and_diff(self):
        self.runner.reply_json({"number": 34, "state": "MERGED", "mergeCommit": {"oid": "deadbeef"}})
        self.assertEqual(self.client.pull_request(34)["mergeCommit"]["oid"], "deadbeef")
        self.assertEqual(self.runner.argv[0], [
            "gh", "pr", "view", "34", "--repo", REPO,
            "--json", "number,url,state,headRefOid,mergedAt,mergeCommit,baseRefName,headRefName,title",
        ])
        self.runner.reply("x" * (400 * 1024 + 10))
        diff = self.client.pull_request_diff(34)
        self.assertEqual(self.runner.argv[1], ["gh", "pr", "diff", "34", "--repo", REPO])
        self.assertTrue(diff.endswith("[diff truncated at 400 KiB]\n"))
        self.assertLessEqual(len(diff), 400 * 1024 + 40)

    def test_merge_pull_request(self):
        self.runner.reply_json({"number": 34, "title": "Fix crash in HUD", "state": "OPEN"})
        self.runner.reply("")
        self.runner.reply_json({"number": 34, "state": "MERGED", "mergeCommit": {"oid": "deadbeef"}, "url": "u"})
        merged = self.client.merge_pull_request(34)
        self.assertEqual(merged["mergeSha"], "deadbeef")
        self.assertEqual(self.runner.argv[1], [
            "gh", "pr", "merge", "34", "--repo", REPO, "--squash", "--delete-branch", "--subject", "Fix crash in HUD",
        ])
        self.assertEqual([argv[1:3] for argv in self.runner.argv], [["pr", "view"], ["pr", "merge"], ["pr", "view"]])
        self.runner.reply_json({"number": 35, "title": "ignored", "state": "OPEN"})
        self.runner.reply("")
        self.runner.reply_json({"number": 35, "state": "MERGED", "mergeCommit": None})
        merged = self.client.merge_pull_request(35, subject="Custom subject")
        self.assertEqual(merged["mergeSha"], "")
        self.assertEqual(self.runner.argv[4][-1], "Custom subject")
        self.runner.reply_json({"number": 36, "title": "t", "state": "OPEN"})
        self.runner.reply("")
        self.runner.reply_json({"number": 36, "state": "MERGED", "mergeCommit": {"oid": "cafe"}})
        merged = self.client.merge_pull_request(36, subject="Subject", body="Refs #12\n\nSummary.", head_sha="a" * 40)
        self.assertEqual(merged["mergeSha"], "cafe")
        self.assertEqual(self.runner.argv[7][-6:], [
            "--subject", "Subject", "--body", "Refs #12\n\nSummary.", "--match-head-commit", "a" * 40,
        ], "the merge is pinned to the reviewed head and carries an explicit body")
        with self.assertRaises(CodeFactoryError):
            self.runner.reply_json({"number": 37, "title": "t", "state": "OPEN"})
            self.client.merge_pull_request(37, head_sha="not-a-sha")

    def test_merge_pull_request_is_idempotent_when_already_merged(self):
        self.runner.reply_json({"number": 34, "state": "MERGED", "mergeCommit": {"oid": "deadbeef"}, "url": "u"})
        merged = self.client.merge_pull_request(34, subject="Fix crash")
        self.assertEqual(merged["mergeSha"], "deadbeef")
        self.assertEqual(self.runner.argv, [[
            "gh", "pr", "view", "34", "--repo", REPO, "--json",
            "number,url,state,headRefOid,mergedAt,mergeCommit,baseRefName,headRefName,title",
        ]], "a pull request that already landed is never merged again")

    def test_merge_pull_request_raises_when_the_pull_request_stays_unmerged(self):
        self.runner.reply_json({"number": 34, "state": "OPEN", "title": "Fix crash"})
        self.runner.reply("")
        self.runner.reply_json({"number": 34, "state": "OPEN", "mergeCommit": None})
        with self.assertRaises(CodeFactoryError) as caught:
            self.client.merge_pull_request(34, subject="Fix crash")
        self.assertEqual(caught.exception.code, "github_failed")
        self.assertIn("did not merge", str(caught.exception))
        self.assertEqual(len(self.runner.calls), 3)

    def test_login_and_ensure_label(self):
        self.runner.reply("your-username\n")
        self.assertEqual(self.client.login(), "your-username")
        self.assertEqual(self.runner.argv[0], ["gh", "api", "user", "--jq", ".login"])
        self.client.ensure_label("herdr-autofix", "AAA6F4", "Code Factory may implement this")
        self.assertEqual(self.runner.argv[1], [
            "gh", "label", "create", "herdr-autofix", "--repo", REPO, "--color", "AAA6F4",
            "--description", "Code Factory may implement this", "--force",
        ])
        with self.assertRaises(CodeFactoryError):
            self.client.ensure_label("x", "blue", "desc")
        self.runner.reply("")
        with self.assertRaises(CodeFactoryError):
            self.client.login()


class VerifyStatusTests(GitHubClientTestCase):
    def test_matrix(self):
        cases = [
            ([], "none"),
            ([{"status": "completed", "conclusion": "success"}], "success"),
            ([{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "success"}], "success"),
            ([{"status": "completed", "conclusion": "failure"}], "failure"),
            ([{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "cancelled"}], "failure"),
            ([{"status": "in_progress", "conclusion": None}], "pending"),
            ([{"status": "queued"}, {"status": "completed", "conclusion": "success"}], "pending"),
            ([{"status": "in_progress"}, {"status": "completed", "conclusion": "failure"}], "failure"),
        ]
        for runs, expected in cases:
            with self.subTest(runs=runs):
                self.assertEqual(GitHubClient.classify_runs(runs), expected)

    def test_verify_status_argv(self):
        self.runner.reply_json([{"status": "completed", "conclusion": "success", "databaseId": 1}])
        self.assertEqual(self.client.verify_status("ABCDEF1234"), "success")
        self.assertEqual(self.runner.argv[0], [
            "gh", "run", "list", "--repo", REPO, "--commit", "abcdef1234", "--workflow", "Verify",
            "--json", "status,conclusion,databaseId,url", "--limit", "20",
        ])
        with self.assertRaises(CodeFactoryError):
            self.client.verify_status("not a sha")

    def test_list_runs_and_rerun_failed(self):
        runs = [{"status": "completed", "conclusion": "failure", "databaseId": 77, "url": "https://example.invalid/run/77"}]
        self.runner.reply_json(runs)
        self.assertEqual(self.client.list_runs("abcdef1234"), runs)
        self.assertEqual(self.runner.argv[0], [
            "gh", "run", "list", "--repo", REPO, "--commit", "abcdef1234", "--workflow", "Verify",
            "--json", "status,conclusion,databaseId,url", "--limit", "20",
        ])
        self.client.rerun_failed(77)
        self.assertEqual(self.runner.argv[1], ["gh", "run", "rerun", "77", "--repo", REPO, "--failed"])
        for value in (0, -1, True, "77"):
            with self.subTest(value=value), self.assertRaises(CodeFactoryError) as caught:
                self.client.rerun_failed(value)
            self.assertEqual(caught.exception.code, "invalid_request")

    def test_failed_run_log(self):
        self.runner.reply_json([
            {"status": "completed", "conclusion": "success", "databaseId": 1},
            {"status": "completed", "conclusion": "failure", "databaseId": 2},
        ])
        self.runner.reply("line\n" * 2000)
        log = self.client.failed_run_log("abcdef1234")
        self.assertEqual(self.runner.argv[1], ["gh", "run", "view", "2", "--repo", REPO, "--log-failed"])
        self.assertEqual(len(log), 4000)
        self.runner.reply_json([{"status": "completed", "conclusion": "success", "databaseId": 3}])
        self.assertEqual(self.client.failed_run_log("abcdef1234"), "")


class ReviewTests(GitHubClientTestCase):
    def test_post_review_payload(self):
        self.runner.reply_json({"id": 1})
        comments = [
            {"path": "herdr_harness/x.py", "line": 12, "body": "Rename"},
            {"path": "/abs/path", "line": 1, "body": "ignored"},
            {"path": "ok.py", "line": 0, "body": "ignored"},
            {"path": "ok.py", "line": 3, "body": ""},
        ]
        self.client.post_review(34, "### Astra review (round 1): request_changes", comments)
        call = self.runner.calls[0]
        self.assertEqual(call["argv"], ["gh", "api", f"repos/{REPO}/pulls/34/reviews", "--method", "POST", "--input", "-"])
        payload = json.loads(call["input"])
        self.assertEqual(payload["event"], "COMMENT")
        self.assertEqual(payload["comments"], [{"path": "herdr_harness/x.py", "line": 12, "side": "RIGHT", "body": "Rename"}])

    def test_post_review_folds_comments_after_422(self):
        self.runner.reply("", returncode=1, stderr="gh: Validation Failed (HTTP 422)")
        self.runner.reply_json({"id": 2})
        result = self.client.post_review(34, "Summary", [{"path": "a.py", "line": 4, "body": "Fix it"}])
        self.assertEqual(result, {"id": 2})
        self.assertEqual(len(self.runner.calls), 2)
        retry = json.loads(self.runner.calls[1]["input"])
        self.assertEqual(retry["comments"], [])
        self.assertIn("Summary", retry["body"])
        self.assertIn("`a.py:4` — Fix it", retry["body"])

    def test_post_review_folds_comments_when_422_is_beyond_the_trimmed_stderr(self):
        rejected = "Pull request review thread line must be part of the diff\n" * 6
        stderr = "gh: Unprocessable Entity (HTTP 422)\n" + rejected
        self.assertGreater(len(stderr), 300, "the status line lies outside the 300-character message tail")
        self.runner.reply("", returncode=1, stderr=stderr)
        self.runner.reply_json({"id": 3})
        result = self.client.post_review(34, "Summary", [{"path": "a.py", "line": 4, "body": "Fix it"}])
        self.assertEqual(result, {"id": 3})
        self.assertEqual(len(self.runner.calls), 2)
        retry = json.loads(self.runner.calls[1]["input"])
        self.assertEqual(retry["comments"], [])
        self.assertIn("`a.py:4` — Fix it", retry["body"])
        self.assertEqual(self.sleeps, [], "the review POST is never retried as a transient failure")

    def test_post_review_other_failures_do_not_retry(self):
        self.runner.reply("", returncode=1, stderr="gh: Not Found (HTTP 404)")
        with self.assertRaises(CodeFactoryError) as caught:
            self.client.post_review(34, "Summary", [{"path": "a.py", "line": 4, "body": "Fix it"}])
        self.assertEqual(caught.exception.code, "github_failed")
        self.assertEqual(len(self.runner.calls), 1)


class DownloadTests(GitHubClientTestCase):
    def test_host_refusal(self):
        for url in (
            "https://example.invalid/file.png",
            "http://github.com/owner/repo/releases/download/issue-attachments/x.png",
            "https://github.com/other/repo/releases/download/issue-attachments/x.png",
            "https://github.com/owner/repo/releases/download/",
            "https://github.com/user-attachments/../x",
            "https://user:pw@github.com/user-attachments/assets/x",
            "https://github.com.example.invalid/user-attachments/assets/x",
        ):
            with self.subTest(url=url):
                self.assertFalse(self.client.allowed_download(url))
                with tempfile.TemporaryDirectory() as temp, self.assertRaises(CodeFactoryError) as caught:
                    self.client.download(url, Path(temp) / "x")
                self.assertEqual(caught.exception.code, "download_failed")
        self.assertTrue(self.client.allowed_download("https://github.com/owner/repo/releases/download/issue-attachments/isr_1-x.png"))
        self.assertTrue(self.client.allowed_download("https://github.com/user-attachments/assets/abc"))

    def test_download_success_and_cap(self):
        requests: list = []

        def fake_urlopen(request, timeout=None):
            requests.append((request.full_url, timeout))
            if "big" in request.full_url:
                return FakeResponse(b"x" * (20 * 1024 * 1024 + 1))
            return FakeResponse(b"png-bytes")

        client = GitHubClient(REPO, runner=self.runner, environ=self.environ, urlopen=fake_urlopen, timeout=30)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "attachments" / "shot.png"
            written = client.download("https://github.com/owner/repo/releases/download/issue-attachments/shot.png", target)
            self.assertEqual(written, target)
            self.assertEqual(target.read_bytes(), b"png-bytes")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(requests[0][1], 30)
            big = Path(temp) / "big.bin"
            with self.assertRaises(CodeFactoryError) as caught:
                client.download("https://github.com/user-attachments/assets/big", big)
            self.assertEqual(caught.exception.code, "download_failed")
            self.assertFalse(big.exists())
        self.assertEqual(self.runner.calls, [], "downloads never shell out to gh")

    def test_download_wraps_http_client_errors(self):
        class TruncatedResponse(FakeResponse):
            def read(self, size=-1):
                raise http.client.IncompleteRead(b"abc")

        client = GitHubClient(REPO, runner=self.runner, environ=self.environ, timeout=30,
                              urlopen=lambda request, timeout=None: TruncatedResponse(b""))
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "shot.png"
            with self.assertRaises(CodeFactoryError) as caught:
                client.download("https://github.com/user-attachments/assets/shot", target)
            self.assertEqual(caught.exception.code, "download_failed")
            self.assertIn("download failed", str(caught.exception))
            self.assertFalse(target.exists(), "the partial file is removed")


class ErrorMappingTests(GitHubClientTestCase):
    def test_non_zero_exit_maps_to_github_failed_with_trimmed_stderr(self):
        self.runner.reply("", returncode=1, stderr="E" * 1000 + " tail")
        with self.assertRaises(CodeFactoryError) as caught:
            self.client.get_issue(12)
        self.assertEqual(caught.exception.code, "github_failed")
        message = str(caught.exception)
        self.assertLess(len(message), 400)
        self.assertTrue(message.endswith(" tail"))
        self.assertNotIn("provider-secret", message)
        self.assertNotIn("control-secret", message)
        self.assertEqual(len(self.runner.calls), 1, "a non-transient failure is not retried")
        self.assertEqual(self.sleeps, [])

    def test_read_only_calls_retry_transient_failures(self):
        self.runner.reply("", returncode=1, stderr="gh: API rate limit exceeded for user ID 1 (HTTP 403)")
        self.runner.reply("", returncode=1, stderr="gh: Bad Gateway (HTTP 502)")
        self.runner.reply_json({"number": 12, "state": "OPEN"})
        self.assertEqual(self.client.get_issue(12)["state"], "OPEN")
        self.assertEqual(len(self.runner.calls), 3)
        self.assertEqual(self.sleeps, [2.0, 5.0])
        self.assertEqual(len({tuple(argv) for argv in self.runner.argv}), 1, "the same argv is repeated")

    def test_read_only_timeouts_are_retried(self):
        attempts: list[list[str]] = []

        def flaky(argv, **kwargs):
            attempts.append(list(argv))
            if len(attempts) < 3:
                raise subprocess.TimeoutExpired(cmd=argv, timeout=kwargs["timeout"])
            return SimpleNamespace(returncode=0, stdout=json.dumps([{"status": "completed", "conclusion": "success"}]), stderr="")

        client = GitHubClient(REPO, runner=flaky, environ=self.environ, sleep=self.sleeps.append)
        self.assertEqual(client.verify_status("abcdef1234"), "success")
        self.assertEqual(len(attempts), 3)
        self.assertEqual(self.sleeps, [2.0, 5.0])

    def test_retries_stop_after_the_last_delay(self):
        for _ in range(4):
            self.runner.reply("", returncode=1, stderr="dial tcp: connection reset by peer")
        with self.assertRaises(CodeFactoryError) as caught:
            self.client.verify_status("abcdef1234")
        self.assertEqual(caught.exception.code, "github_failed")
        self.assertIn("connection reset", str(caught.exception))
        self.assertEqual(len(self.runner.calls), 4)
        self.assertEqual(self.sleeps, [2.0, 5.0, 15.0])

    def test_mutating_calls_are_never_retried(self):
        self.runner.reply_json({"number": 34, "state": "OPEN", "title": "Fix"})
        self.runner.reply("", returncode=1, stderr="gh: Bad Gateway (HTTP 502)")
        with self.assertRaises(CodeFactoryError) as caught:
            self.client.merge_pull_request(34, subject="Fix")
        self.assertEqual(caught.exception.code, "github_failed")
        self.assertEqual(self.runner.argv[1][:3], ["gh", "pr", "merge"])
        self.assertEqual(len(self.runner.calls), 2)
        self.runner.reply("", returncode=1, stderr="gh: API rate limit exceeded (HTTP 403)")
        with self.assertRaises(CodeFactoryError):
            self.client.comment_issue(12, "Picked up.")
        self.assertEqual(len(self.runner.calls), 3)
        self.assertEqual(self.sleeps, [])

    def test_invalid_json_maps_to_github_failed(self):
        self.runner.reply("not json")
        with self.assertRaises(CodeFactoryError) as caught:
            self.client.list_issues("herdr-autofix")
        self.assertEqual(caught.exception.code, "github_failed")
        self.assertIn("invalid JSON", str(caught.exception))

    def test_process_errors(self):
        def raising(argv, **kwargs):
            raise OSError("gh missing")

        client = GitHubClient(REPO, runner=raising, environ=self.environ)
        with self.assertRaises(CodeFactoryError) as caught:
            client.login()
        self.assertEqual(caught.exception.code, "github_failed")
        self.assertIn("could not start", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
