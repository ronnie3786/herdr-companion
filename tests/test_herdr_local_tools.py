import hashlib
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness import attachments, local_tools, workspace_tools


class LocalToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo with spaces"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Example Developer")
        self.git("config", "user.email", "developer@example.test")
        (self.root / "tracked.txt").write_text("before\n")
        self.git("add", "--", "tracked.txt")
        self.git("commit", "-qm", "Initial")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.env = {"HOME": self.temp.name, "HERDR_HARNESS_ATTACHMENTS_DIR": str(Path(self.temp.name) / "uploads")}
        self.tools = local_tools.LocalTools(environ=self.env)
        # Native tools must work even when opening any HTTP provider is forbidden.
        self.network = patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("unexpected HTTP request"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, check=True, timeout=15).stdout

    def test_git_status_diff_stage_unstage_and_commit_history_execute_locally(self):
        (self.root / "tracked.txt").write_text("after\n")
        (self.root / "new.txt").write_text("new\n")
        nested = self.root / "nested"
        nested.mkdir()
        status = self.tools.git_status(nested)
        self.assertEqual(status["root_path"], str(self.root.resolve()))
        self.assertEqual(status["unstaged"], [{"status": "M", "file": "tracked.txt"}])
        self.assertEqual(status["untracked"], ["new.txt"])
        self.assertIn("+after", self.tools.git_diff(nested, "tracked.txt", "unstaged")["diff"])
        self.assertIn("+new", self.tools.git_diff(nested, "new.txt", "untracked")["diff"])
        self.tools.git_stage(nested, "new.txt", expected_root=status["root_path"])
        self.assertIn("+new", self.tools.git_diff(nested, "new.txt", "staged")["diff"])
        self.tools.git_unstage(nested, "new.txt", expected_root=status["root_path"])
        self.assertIn("new.txt", self.tools.git_status(nested)["untracked"])
        self.assertEqual(self.tools.git_commit_files(nested, self.commit)["files"], [{"status": "A", "file": "tracked.txt"}])
        self.assertIn("+before", self.tools.git_commit_diff(nested, self.commit, "tracked.txt")["diff"])

    def test_git_mutations_support_unborn_head_and_literal_pathspec(self):
        plain = Path(self.temp.name) / "unborn"
        plain.mkdir()
        subprocess.run(["git", "init", "-q", str(plain)], check=True)
        (plain / "[a].txt").write_text("literal")
        (plain / "a.txt").write_text("other")
        self.tools.git_stage(plain, "[a].txt")
        self.assertEqual(self.tools.git_status(plain)["staged"], [{"status": "A", "file": "[a].txt"}])
        self.tools.git_unstage(plain, "[a].txt")
        self.assertEqual(self.tools.git_status(plain)["staged"], [])

    def test_stale_root_blocks_reads_mutations_and_open(self):
        expected = str(Path(self.temp.name) / "other")
        operations = [
            lambda: self.tools.git_stage(self.root, "tracked.txt", expected_root=expected),
            lambda: self.tools.git_unstage(self.root, "tracked.txt", expected_root=expected),
            lambda: self.tools.git_diff(self.root, "tracked.txt", "unstaged", expected_root=expected),
            lambda: self.tools.git_commit_files(self.root, self.commit, expected_root=expected),
            lambda: self.tools.git_commit_diff(self.root, self.commit, "tracked.txt", expected_root=expected),
            lambda: self.tools.git_open_file(self.root, "tracked.txt", expected_root=expected),
        ]
        for operation in operations:
            with self.subTest(operation=operation), self.assertRaises(local_tools.LocalToolsError) as failure:
                operation()
            self.assertEqual(failure.exception.code, "git_repository_changed")
            self.assertEqual(failure.exception.status, 409)

    def test_traversal_parent_symlinks_and_invalid_commits_cannot_select_outside_files(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("private")
        (self.root / "escape").symlink_to(outside)
        for path in (".", "../outside/secret.txt", str(outside / "secret.txt"), "escape/secret.txt"):
            with self.subTest(path=path), self.assertRaises(local_tools.LocalToolsError) as failure:
                self.tools.git_stage(self.root, path)
            self.assertEqual(failure.exception.code, "invalid_git_path")
        for commit in ("HEAD", "--help", "abc;whoami", "abc", "a" * 41):
            with self.subTest(commit=commit), self.assertRaises(local_tools.LocalToolsError):
                self.tools.git_commit_files(self.root, commit)

    def test_final_symlinks_can_be_staged_but_cannot_be_opened_outside_checkout(self):
        outside = Path(self.temp.name) / "secret.txt"
        outside.write_text("private")
        (self.root / "link").symlink_to(outside)
        self.tools.git_stage(self.root, "link")
        self.assertIn({"status": "A", "file": "link"}, self.tools.git_status(self.root)["staged"])
        with self.assertRaises(local_tools.LocalToolsError):
            self.tools.git_open_file(self.root, "link")

    def test_opener_is_platform_native_and_validates_missing_paths(self):
        with patch("herdr_harness.local_tools._open_repository_file", return_value=str(self.root / "tracked.txt")) as opened:
            self.assertTrue(self.tools.git_open_file(self.root, "tracked.txt", reveal=True)["revealed"])
            opened.assert_called_once_with(str(self.root.resolve()), "tracked.txt", reveal=True)
        with self.assertRaises(local_tools.LocalToolsError) as failure:
            self.tools.git_open_file(self.root, "missing.txt")
        self.assertEqual(failure.exception.code, "git_file_not_in_working_tree")
        for platform, expected in (("darwin", ["open", "-R"]), ("linux", ["xdg-open"]), ("win32", None)):
            with patch("herdr_harness.local_tools.sys.platform", platform):
                self.assertEqual(local_tools._open_command(True), expected)

    def test_bad_query_bounds_rejected(self):
        for limit in (0, 501, True, "invalid"):
            with self.subTest(limit=limit), self.assertRaises(local_tools.LocalToolsError):
                self.tools.search_files(self.root, "tracked", limit)
        for limit in (0, 101, True, "invalid"):
            with self.subTest(limit=limit), self.assertRaises(local_tools.LocalToolsError):
                self.tools.jira_assigned(limit=limit)

    def test_skills_and_files_are_native_and_root_scoped(self):
        skill = self.root / ".claude" / "skills" / "review" / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("# Review")
        self.assertEqual(self.tools.skills(self.root)["project_skills"][0]["name"], "review")
        self.assertEqual(self.tools.search_files(self.root, "tracked")["files"], [{"path": "tracked.txt"}])

    def test_attachments_are_private_herdr_files_with_opaque_workspace_directories(self):
        item = self.tools.upload_attachment(workspace_id="w1", filename="../../notes.txt", content_type="text/plain", data=b"hello")["attachment"]
        target = Path(item["path"])
        self.assertEqual(target.read_bytes(), b"hello")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)
        self.assertTrue(target.is_relative_to(Path(self.env["HERDR_HARNESS_ATTACHMENTS_DIR"]).resolve()))
        self.assertEqual(item["original_filename"], "../../notes.txt")
        self.assertEqual(item["workspace_id"], "w1")

    def test_attachments_reject_symlink_redirect_and_bad_metadata(self):
        root = Path(self.env["HERDR_HARNESS_ATTACHMENTS_DIR"])
        root.mkdir()
        key = hashlib.sha256(b"w1").hexdigest()
        (root / key).symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(local_tools.LocalToolsError) as failure:
            self.tools.upload_attachment(workspace_id="w1", filename="test.txt", content_type="text/plain", data=b"private")
        self.assertEqual(failure.exception.code, "attachment_storage_failed")
        for override in ({"filename": "evil\nfile"}, {"content_type": "text/plain\r\nX:evil"}, {"data": b""}, {"workspace_id": ""}):
            values = {"workspace_id": "w1", "filename": "test.txt", "content_type": "text/plain", "data": b"hello", **override}
            with self.subTest(override=override), self.assertRaises(local_tools.LocalToolsError):
                self.tools.upload_attachment(**values)
        with patch("herdr_harness.attachments.MAX_ATTACHMENT_BYTES", 2), self.assertRaises(local_tools.LocalToolsError) as failure:
            self.tools.upload_attachment(workspace_id="w2", filename="test.txt", content_type="text/plain", data=b"123")
        self.assertEqual(failure.exception.status, 413)

    def test_github_uses_authenticated_cli_and_no_organization_filter(self):
        response = [{"number": 42, "title": "Fix", "url": "https://github.com/example/project/pull/42", "isDraft": False, "state": "open", "author": {"login": "contributor"}, "repository": {"nameWithOwner": "example/project"}}]
        with patch("herdr_harness.workspace_tools._run", return_value=(json.dumps(response), False)) as run:
            payload = self.tools.github_review_requests()
        self.assertEqual(payload["items"][0]["owner"], "example")
        argv = run.call_args.args[0]
        self.assertEqual(argv[:3], ["gh", "search", "prs"])
        self.assertIn("--review-requested=@me", argv)
        self.assertFalse(any("--repo" in argument for argument in argv))

    def test_jira_uses_shared_configuration_and_bounded_acli_lookup(self):
        response = [{"key": "TASK-42", "fields": {"summary": "Example task", "status": {"name": "Open"}, "priority": {"name": "Medium"}, "issuetype": {"name": "Task"}}}]
        tools = local_tools.LocalTools(environ={**self.env, "HERDR_JIRA_URL": "https://example.atlassian.net"})
        with patch("herdr_harness.workspace_tools._run", return_value=(json.dumps(response), False)) as run:
            payload = tools.jira_issue("https://example.atlassian.net/browse/TASK-42")
        self.assertEqual(payload["ticket"]["url"], "https://example.atlassian.net/browse/TASK-42")
        self.assertEqual(run.call_args.args[0][:4], ["acli", "jira", "workitem", "search"])
        self.assertEqual(run.call_args.kwargs["timeout"], workspace_tools.JIRA_TIMEOUT_SECONDS)
        self.assertIn("key = TASK-42", run.call_args.args[0])

    def test_invalid_provider_json_and_oversized_output_fail_safely(self):
        for output in ("broken json", "{}", '[{"number":false}]'):
            with patch("herdr_harness.workspace_tools._run", return_value=(output, False)), self.assertRaises(local_tools.LocalToolsError):
                self.tools.github_review_requests()
        def fake_run(command, **options):
            options["stdout"].write(b"x" * (2 * 1024 * 1024 + 1))
            return subprocess.CompletedProcess(command, 0)
        with patch("herdr_harness.workspace_tools.subprocess.run", side_effect=fake_run), self.assertRaises(local_tools.LocalToolsError) as failure:
            workspace_tools._run(["gh", "search", "prs"])
        self.assertEqual(failure.exception.code, "gh_output_too_large")


if __name__ == "__main__":
    unittest.main()
