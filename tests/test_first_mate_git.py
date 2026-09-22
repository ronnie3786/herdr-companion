import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness import local_tools
from herdr_harness.first_mate_store import FirstMateError
from herdr_harness.service import HerdrService
from herdr_harness.workspace_tools import WorkspaceToolError


class FakeFirstMateStore:
    def __init__(self, feature, assignments):
        self.feature = feature
        self.assignments = assignments

    def get_feature(self, feature_id):
        if feature_id != self.feature["id"]:
            raise FirstMateError("not found", code="not_found", status=404)
        return self.feature

    def get_assignment(self, assignment_id):
        for assignment in self.assignments:
            if assignment["id"] == assignment_id:
                return assignment
        raise FirstMateError("not found", code="not_found", status=404)

    def list_assignments(self, *, feature_id=None):
        return [item for item in self.assignments if feature_id is None or item["feature_id"] == feature_id]


class FirstMateGitServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.project = root / "project"
        self.worker = root / "worker"
        self.removed = root / "removed"
        self.other = root / "other"
        for path in (self.project, self.worker, self.other):
            self._initialize_repository(path)
        self.commit = self._git(self.worker, "rev-parse", "HEAD").strip()

        # Establish all three working-tree sections against a real repository.
        (self.worker / "tracked.txt").write_text("worker changed\n", encoding="utf-8")
        (self.worker / "staged.txt").write_text("staged\n", encoding="utf-8")
        (self.worker / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        self._git(self.worker, "add", "--", "staged.txt")

        self.feature = {"id": "fmf-one", "cwd": str(self.project)}
        self.assignments = [
            {"id": "fma-worker", "feature_id": "fmf-one", "title": "Worker", "metadata": {"worktree_path": str(self.worker)}},
            {"id": "fma-removed", "feature_id": "fmf-one", "title": "Removed", "metadata": {"worktree_path": str(self.removed)}},
            {"id": "fma-other", "feature_id": "fmf-other", "title": "Other feature", "metadata": {"worktree_path": str(self.other)}},
            {"id": "fma-no-path", "feature_id": "fmf-one", "title": "No path", "metadata": {}},
        ]
        self.service = object.__new__(HerdrService)
        self.service._lock = threading.RLock()
        self.service._first_mate_store = FakeFirstMateStore(self.feature, self.assignments)
        self.service.local_tools = local_tools.LocalTools(environ={"HOME": self.temp.name})

    def _initialize_repository(self, path):
        path.mkdir()
        self._git(path, "init", "-q")
        self._git(path, "config", "user.name", "Synthetic Developer")
        self._git(path, "config", "user.email", "developer@example.test")
        (path / "tracked.txt").write_text("initial\n", encoding="utf-8")
        self._git(path, "add", "--", "tracked.txt")
        self._git(path, "commit", "-qm", "Initial synthetic commit")

    @staticmethod
    def _git(root, *arguments):
        return subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout

    def test_catalog_has_project_and_only_recorded_owned_assignment_worktrees(self):
        response = self.service.first_mate_git_workspaces("fmf-one")
        self.assertEqual([item["id"] for item in response["workspaces"]], ["project", "fma-worker", "fma-removed"])
        self.assertEqual(response["workspaces"][0]["path"], str(self.project))

    def test_project_status_needs_no_herdr_terminal_or_pane(self):
        status = self.service.first_mate_git_status("fmf-one", "project")
        self.assertEqual(status["root_path"], str(self.project.resolve()))
        self.assertEqual(status["workspace"], "project")

    def test_real_repository_status_diffs_mutations_and_history_use_exact_recorded_root(self):
        status = self.service.first_mate_git_status("fmf-one", "fma-worker")
        expected_root = str(self.worker.resolve())
        self.assertEqual(status["workspace"], "fma-worker")
        self.assertEqual(status["root_path"], expected_root)
        self.assertEqual(status["staged"], [{"status": "A", "file": "staged.txt"}])
        self.assertEqual(status["unstaged"], [{"status": "M", "file": "tracked.txt"}])
        self.assertEqual(status["untracked"], ["untracked.txt"])
        self.assertIn("+worker changed", self.service.first_mate_git_diff(
            "fmf-one", "fma-worker", file="tracked.txt", section="unstaged", expected_root=expected_root
        )["diff"])
        self.assertIn("+staged", self.service.first_mate_git_diff(
            "fmf-one", "fma-worker", file="staged.txt", section="staged", expected_root=expected_root
        )["diff"])
        self.assertIn("+untracked", self.service.first_mate_git_diff(
            "fmf-one", "fma-worker", file="untracked.txt", section="untracked", expected_root=expected_root
        )["diff"])

        self.service.first_mate_git_stage(
            "fmf-one", "fma-worker", file="untracked.txt", expected_root=expected_root
        )
        self.assertIn("untracked.txt", [item["file"] for item in self.service.first_mate_git_status("fmf-one", "fma-worker")["staged"]])
        self.service.first_mate_git_unstage(
            "fmf-one", "fma-worker", file="untracked.txt", expected_root=expected_root
        )
        self.assertIn("untracked.txt", self.service.first_mate_git_status("fmf-one", "fma-worker")["untracked"])

        files = self.service.first_mate_git_commit_files(
            "fmf-one", "fma-worker", commit_hash=self.commit, expected_root=expected_root
        )
        self.assertEqual(files["files"], [{"status": "A", "file": "tracked.txt"}])
        historical = self.service.first_mate_git_commit_diff(
            "fmf-one", "fma-worker", commit_hash=self.commit, file="tracked.txt", expected_root=expected_root
        )
        self.assertIn("+initial", historical["diff"])

    def test_unknown_foreign_removed_missing_path_and_non_repository_roots_are_rejected(self):
        plain = Path(self.temp.name) / "plain"
        plain.mkdir()
        self.assignments.extend([
            {
                "id": "fma-plain", "feature_id": "fmf-one", "title": "Plain",
                "metadata": {"worktree_path": str(plain)},
            },
            {
                "id": "fma-relative", "feature_id": "fmf-one", "title": "Relative",
                "metadata": {"worktree_path": "relative/worktree"},
            },
        ])
        for workspace, code in (
            ("missing", "first_mate_git_workspace_not_found"),
            ("fma-other", "first_mate_git_workspace_not_found"),
            ("fma-removed", "workspace_root_not_found"),
            ("fma-no-path", "first_mate_git_workspace_not_found"),
            ("fma-relative", "invalid_workspace_root"),
            ("fma-plain", "git_repository_not_found"),
        ):
            with self.subTest(workspace=workspace), self.assertRaises(WorkspaceToolError) as raised:
                self.service.first_mate_git_status("fmf-one", workspace)
            self.assertEqual(raised.exception.code, code)

    def test_expected_root_traversal_and_symlink_guards_apply_through_first_mate_service(self):
        expected_root = str(self.worker.resolve())
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("private", encoding="utf-8")
        (self.worker / "escape").symlink_to(outside)

        cases = (
            (lambda: self.service.first_mate_git_diff(
                "fmf-one", "fma-worker", file="tracked.txt", section="unstaged", expected_root=str(self.project)
            ), "git_repository_changed"),
            (lambda: self.service.first_mate_git_stage(
                "fmf-one", "fma-worker", file="../outside/secret.txt", expected_root=expected_root
            ), "invalid_git_path"),
            (lambda: self.service.first_mate_git_diff(
                "fmf-one", "fma-worker", file="escape/secret.txt", section="untracked", expected_root=expected_root
            ), "invalid_git_path"),
            (lambda: self.service.first_mate_git_commit_files(
                "fmf-one", "fma-worker", commit_hash="HEAD", expected_root=expected_root
            ), "invalid_git_hash"),
        )
        for operation, code in cases:
            with self.subTest(code=code), self.assertRaises(WorkspaceToolError) as raised:
                operation()
            self.assertEqual(raised.exception.code, code)

    def test_open_and_reveal_keep_real_validation_while_only_os_launch_is_mocked(self):
        expected_root = str(self.worker.resolve())
        with patch("herdr_harness.local_tools._open_repository_file", return_value=str(self.worker / "tracked.txt")) as opened:
            response = self.service.first_mate_git_open(
                "fmf-one", "fma-worker", file="tracked.txt", expected_root=expected_root, reveal=True
            )
        self.assertTrue(response["revealed"])
        opened.assert_called_once_with(expected_root, "tracked.txt", reveal=True)

        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("private", encoding="utf-8")
        (self.worker / "outside-link").symlink_to(outside / "secret.txt")
        with self.assertRaises(WorkspaceToolError) as raised:
            self.service.first_mate_git_open(
                "fmf-one", "fma-worker", file="outside-link", expected_root=expected_root, reveal=False
            )
        self.assertEqual(raised.exception.code, "invalid_git_path")


if __name__ == "__main__":
    unittest.main()
