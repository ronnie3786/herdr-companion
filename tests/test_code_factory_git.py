"""Worktree, commit, push and cleanup operations against a temporary bare repository."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.code_factory import git as git_module
from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.git import GitRepository, validate_branch


def isolated_environment(home: Path) -> dict[str, str]:
    """A git environment that never reads the operator's configuration."""
    config = home / "gitconfig"
    config.write_text("[user]\n\tname = Herdr Tests\n\temail = tests@example.invalid\n[init]\n\tdefaultBranch = main\n")
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "GIT_CONFIG_GLOBAL": str(config),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Herdr Tests",
        "GIT_AUTHOR_EMAIL": "tests@example.invalid",
        "GIT_COMMITTER_NAME": "Herdr Tests",
        "GIT_COMMITTER_EMAIL": "tests@example.invalid",
        "GIT_TERMINAL_PROMPT": "0",
        "HERDR_HARNESS_API_TOKEN": "must-not-leak",
    }


class GitRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = isolated_environment(self.home)
        self.remote = self.root / "remote.git"
        self.checkout = self.root / "checkout"
        self.worktrees = self.root / "worktrees"
        self.git(["init", "--quiet", "--bare", "--initial-branch=main", str(self.remote)])
        self.git(["clone", "--quiet", str(self.remote), str(self.checkout)])
        self.git(["checkout", "--quiet", "-b", "main"], cwd=self.checkout)
        (self.checkout / "README.md").write_text("# Synthetic\n")
        self.git(["add", "-A"], cwd=self.checkout)
        self.git(["commit", "--quiet", "-m", "Initial"], cwd=self.checkout)
        self.git(["push", "--quiet", "-u", "origin", "main"], cwd=self.checkout)
        self.repo = GitRepository(self.checkout, environ=self.env)

    def git(self, args, cwd=None) -> str:
        result = subprocess.run(["git", *args], cwd=str(cwd) if cwd else None, env=self.env,
                                capture_output=True, text=True, check=True)
        return result.stdout

    def test_environment_strips_herdr_settings(self):
        env = self.repo.environment()
        self.assertNotIn("HERDR_HARNESS_API_TOKEN", env)
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(env["LC_ALL"], "C")
        self.assertEqual(env["LANGUAGE"], "C")

    def test_environment_forces_english_messages_and_disables_hooks(self):
        environ = dict(self.env, LC_ALL="de_DE.UTF-8", LANGUAGE="de", GIT_CONFIG_COUNT="1",
                       GIT_CONFIG_KEY_0="user.name", GIT_CONFIG_VALUE_0="Operator")
        repo = GitRepository(self.checkout, environ=environ)
        env = repo.environment()
        self.assertEqual(env["LC_ALL"], "C", "an inherited locale must not localize the messages we recognise")
        self.assertEqual(env["LANGUAGE"], "C")
        self.assertEqual(env["GIT_CONFIG_COUNT"], "2", "existing config overrides are kept")
        self.assertEqual((env["GIT_CONFIG_KEY_0"], env["GIT_CONFIG_VALUE_0"]), ("user.name", "Operator"))
        self.assertEqual((env["GIT_CONFIG_KEY_1"], env["GIT_CONFIG_VALUE_1"]), ("core.hooksPath", os.devnull))
        self.assertFalse(repo.delete_branch("never-created"), "the tolerant paths still recognise git's wording")

    def install_hooks(self) -> Path:
        """Commit executable hooks to main and enable them on the checkout; returns the marker directory."""
        markers = self.root / "hook-markers"
        hooks = self.checkout / ".githooks"
        hooks.mkdir()
        for name in ("pre-push", "post-commit", "post-checkout", "pre-rebase", "post-rewrite", "prepare-commit-msg"):
            script = hooks / name
            script.write_text(f'#!/bin/sh\nmkdir -p "{markers}"\ntouch "{markers}/$(basename "$0")"\n')
            script.chmod(0o755)
        self.git(["add", "-A"], cwd=self.checkout)
        self.git(["commit", "--quiet", "-m", "Add hooks"], cwd=self.checkout)
        self.git(["push", "--quiet", "origin", "main"], cwd=self.checkout)
        self.git(["config", "core.hooksPath", ".githooks"], cwd=self.checkout)
        return markers

    def test_repository_hooks_never_run_from_daemon_git(self):
        markers = self.install_hooks()

        def fired() -> set[str]:
            return {item.name for item in markers.iterdir()} if markers.is_dir() else set()

        # The setup is real: a plain git commit on the checkout does run the committed hook.
        self.git(["commit", "--quiet", "--allow-empty", "-m", "Hook probe"], cwd=self.checkout)
        self.assertIn("post-commit", fired())
        shutil.rmtree(markers)

        path = self.worktrees / "issue-6"
        self.repo.add_worktree(path, "codefactory/issue-6", "origin/main")
        self.assertTrue((path / ".githooks" / "pre-push").exists(), "the worktree carries the hooks")
        (path / "feature.txt").write_text("feature\n")
        self.repo.commit_all(path, "Issue #6: feature")
        self.repo.push(path, "origin", "HEAD:refs/heads/codefactory/issue-6")
        self.assertEqual(fired(), set(), "worktree add, commit and push ran no hook")

        no_hooks = ["-c", f"core.hooksPath={os.devnull}"]
        self.git([*no_hooks, "commit", "--quiet", "--allow-empty", "-m", "Upstream"], cwd=self.checkout)
        self.git([*no_hooks, "push", "--quiet", "origin", "main"], cwd=self.checkout)
        self.repo.fetch()
        self.repo.rebase(path, "origin/main")
        self.repo.checkout_detached(path, "origin/main")
        self.repo.add_worktree(self.worktrees / "release-6", None, "origin/main", detach=True)
        self.assertEqual(fired(), set(), "rebase, checkout and a detached worktree ran no hook")

    def test_fetch_holds_the_fetch_lock(self):
        seen: list[tuple[str, bool]] = []
        kwargs_seen: list[dict] = []

        def runner(argv, **kwargs):
            seen.append((argv[3], git_module._FETCH_LOCK.locked()))
            kwargs_seen.append(kwargs)
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        repo = GitRepository(self.checkout, runner=runner, environ=self.env)
        repo.fetch()
        repo.head(self.checkout)
        self.assertEqual(seen, [("fetch", True), ("rev-parse", False)])
        self.assertFalse(git_module._FETCH_LOCK.locked())
        self.assertEqual(kwargs_seen[0]["errors"], "replace")

    def test_non_utf8_git_output_is_decoded_leniently(self):
        # A stand-in git that prints raw Latin-1 bytes (as ``git log``/``git diff`` do for
        # non-UTF-8 content) exercises the real subprocess decoding of ``_run``.
        fake_git = self.root / "fake-git"
        fake_git.write_bytes(b"#!/bin/sh\nprintf 'abc123\\tcaf\\351 latin-1\\n'\n")
        fake_git.chmod(0o755)
        repo = GitRepository(self.checkout, environ=self.env, git_binary=str(fake_git))
        self.assertEqual(repo.log(self.checkout, 1), [{"sha": "abc123", "subject": "caf\ufffd latin-1"}])

    def test_remote_url_resolve_and_fetch(self):
        self.assertEqual(Path(self.repo.remote_url()).resolve(), self.remote)
        head = self.git(["rev-parse", "HEAD"], cwd=self.checkout).strip()
        self.assertEqual(self.repo.resolve("origin/main"), head)
        self.repo.fetch()
        self.assertEqual(self.repo.resolve("main"), head)
        with self.assertRaises(CodeFactoryError) as caught:
            self.repo.resolve("refs/heads/does-not-exist")
        self.assertEqual(caught.exception.code, "git_failed")
        with self.assertRaises(CodeFactoryError):
            self.repo.resolve("--output=/tmp/x")

    def test_worktree_lifecycle(self):
        path = self.worktrees / "issue-1"
        created = self.repo.add_worktree(path, "codefactory/issue-1", "origin/main")
        self.assertEqual(created["branch"], "codefactory/issue-1")
        self.assertTrue((path / "README.md").exists())
        self.assertEqual(created["head"], self.repo.resolve("origin/main"))
        self.assertTrue(self.repo.is_clean(path))
        self.assertEqual(self.repo.current_branch(path), "codefactory/issue-1")
        found = self.repo.find_worktree(path)
        self.assertIsNotNone(found)
        self.assertEqual(found["branch"], "codefactory/issue-1")
        self.assertFalse(found["detached"])
        self.assertEqual(len(self.repo.list_worktrees()), 2)

        (path / "feature.py").write_text("print('hello')\n")
        self.assertFalse(self.repo.is_clean(path))
        self.assertIn("feature.py", self.repo.status_porcelain(path))
        sha = self.repo.commit_all(path, "Issue #1: add feature")
        self.assertIsNotNone(sha)
        self.assertEqual(sha, self.repo.head(path))
        self.assertTrue(self.repo.is_clean(path))
        self.assertIsNone(self.repo.commit_all(path, "Nothing to commit"))
        self.assertEqual(self.repo.count_commits(path, "origin/main"), 1)
        log = self.repo.log(path, 5)
        self.assertEqual(log[0], {"sha": sha, "subject": "Issue #1: add feature"})
        self.assertEqual(log[1]["subject"], "Initial")

        self.repo.push(path, "origin", "HEAD:refs/heads/codefactory/issue-1")
        remote_sha = self.git(["rev-parse", "refs/heads/codefactory/issue-1"], cwd=self.remote).strip()
        self.assertEqual(remote_sha, sha)

        self.assertTrue(self.repo.remove_worktree(path))
        self.assertFalse(path.exists())
        self.assertFalse(self.repo.remove_worktree(path), "second removal is tolerated")
        self.assertIsNone(self.repo.find_worktree(path))
        self.assertTrue(self.repo.branch_exists("codefactory/issue-1"))
        self.assertTrue(self.repo.delete_branch("codefactory/issue-1"))
        self.assertFalse(self.repo.delete_branch("codefactory/issue-1"), "missing branch is tolerated")
        self.assertFalse(self.repo.branch_exists("codefactory/issue-1"))
        self.repo.prune_worktrees()
        self.assertEqual(len(self.repo.list_worktrees()), 1)

    def test_existing_branch_is_reused_and_detached_worktrees(self):
        path = self.worktrees / "issue-2"
        self.repo.add_worktree(path, "codefactory/issue-2", "origin/main")
        (path / "a.txt").write_text("a\n")
        sha = self.repo.commit_all(path, "Issue #2: a")
        self.repo.remove_worktree(path)
        again = self.repo.add_worktree(path, "codefactory/issue-2", "origin/main")
        self.assertEqual(again["head"], sha, "the interrupted branch keeps its commits")
        release = self.worktrees / "release-1"
        detached = self.repo.add_worktree(release, None, "origin/main", detach=True)
        self.assertIsNone(detached["branch"])
        self.assertIsNone(self.repo.current_branch(release))
        self.assertTrue(self.repo.find_worktree(release)["detached"])
        with self.assertRaises(CodeFactoryError) as caught:
            self.repo.add_worktree(path, "codefactory/other", "origin/main")
        self.assertEqual(caught.exception.code, "invalid_request")

    def test_stale_worktree_registration_is_pruned_and_recreated(self):
        path = self.worktrees / "issue-7"
        self.repo.add_worktree(path, "codefactory/issue-7", "origin/main")
        (path / "a.txt").write_text("a\n")
        sha = self.repo.commit_all(path, "Issue #7: a")
        shutil.rmtree(path)
        stale = [entry for entry in self.repo.list_worktrees() if entry["branch"] == "codefactory/issue-7"]
        self.assertEqual(len(stale), 1)
        self.assertTrue(stale[0]["prunable"])
        self.assertIsNone(self.repo.find_worktree(path), "a registration without a directory is not a live worktree")
        again = self.repo.add_worktree(path, "codefactory/issue-7", "origin/main")
        self.assertEqual(again["head"], sha, "the branch keeps its commits")
        self.assertTrue((path / "a.txt").exists())
        found = self.repo.find_worktree(path)
        self.assertIsNotNone(found)
        self.assertFalse(found["prunable"])
        self.assertFalse(found["locked"])

    def test_locked_worktree_is_removed(self):
        path = self.worktrees / "issue-8"
        self.repo.add_worktree(path, "codefactory/issue-8", "origin/main")
        self.git(["worktree", "lock", "--reason", "initializing", str(path)], cwd=self.checkout)
        self.assertTrue(self.repo.find_worktree(path)["locked"])
        self.assertTrue(self.repo.remove_worktree(path))
        self.assertFalse(path.exists())
        self.assertIsNone(self.repo.find_worktree(path))

    def test_orphaned_worktree_directory_is_removed(self):
        path = self.worktrees / "issue-3"
        self.repo.add_worktree(path, "codefactory/issue-3", "origin/main")
        # Simulate a checkout whose bookkeeping was pruned while the directory remained.
        self.git(["worktree", "prune"], cwd=self.checkout)
        common = Path(self.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=self.checkout).strip())
        shutil.rmtree(common / "worktrees", ignore_errors=True)
        self.assertTrue(path.exists())
        self.assertTrue(self.repo.remove_worktree(path))
        self.assertFalse(path.exists())
        stray = self.worktrees / "not-a-worktree"
        stray.mkdir(parents=True)
        (stray / "keep.txt").write_text("keep\n")
        with self.assertRaises(CodeFactoryError):
            self.repo.remove_worktree(stray)
        self.assertTrue((stray / "keep.txt").exists(), "unrelated directories are never deleted")

    def test_reset_clean_checkout_and_rebase(self):
        path = self.worktrees / "issue-4"
        self.repo.add_worktree(path, "codefactory/issue-4", "origin/main")
        (path / "README.md").write_text("changed\n")
        (path / "junk.txt").write_text("junk\n")
        self.repo.reset_hard(path)
        self.repo.clean(path)
        self.assertTrue(self.repo.is_clean(path))
        self.assertEqual((path / "README.md").read_text(), "# Synthetic\n")
        (path / "feature.txt").write_text("feature\n")
        feature_sha = self.repo.commit_all(path, "Issue #4: feature")

        (self.checkout / "upstream.txt").write_text("upstream\n")
        self.git(["add", "-A"], cwd=self.checkout)
        self.git(["commit", "--quiet", "-m", "Upstream change"], cwd=self.checkout)
        self.git(["push", "--quiet", "origin", "main"], cwd=self.checkout)
        self.repo.fetch()
        self.repo.rebase(path, "origin/main")
        self.assertNotEqual(self.repo.head(path), feature_sha)
        self.assertEqual(self.repo.count_commits(path, "origin/main"), 1)
        self.assertTrue((path / "upstream.txt").exists())

        self.repo.checkout_detached(path, "origin/main")
        self.assertIsNone(self.repo.current_branch(path))
        self.assertEqual(self.repo.head(path), self.repo.resolve("origin/main"))

    def test_rebase_conflict_is_aborted(self):
        path = self.worktrees / "issue-5"
        self.repo.add_worktree(path, "codefactory/issue-5", "origin/main")
        (path / "README.md").write_text("branch version\n")
        self.repo.commit_all(path, "Issue #5: readme")
        (self.checkout / "README.md").write_text("main version\n")
        self.git(["add", "-A"], cwd=self.checkout)
        self.git(["commit", "--quiet", "-m", "Conflicting"], cwd=self.checkout)
        self.git(["push", "--quiet", "origin", "main"], cwd=self.checkout)
        self.repo.fetch()
        with self.assertRaises(CodeFactoryError) as caught:
            self.repo.rebase(path, "origin/main")
        self.assertEqual(caught.exception.code, "git_failed")
        self.assertTrue(self.repo.is_clean(path), "the failed rebase was aborted")
        self.assertEqual((path / "README.md").read_text(), "branch version\n")

    def test_validation(self):
        for bad in ("", "-x", "a..b", "x/", "x.lock", "a//b", "bad name", 5):
            with self.subTest(bad=bad), self.assertRaises(CodeFactoryError):
                validate_branch(bad)
        self.assertEqual(validate_branch("codefactory/issue-1"), "codefactory/issue-1")
        with self.assertRaises(CodeFactoryError):
            self.repo.commit_all(self.checkout, "")
        with self.assertRaises(CodeFactoryError):
            self.repo.push(self.checkout, "origin", "--delete main")
        with self.assertRaises(CodeFactoryError):
            self.repo.add_worktree(self.worktrees / "x", "bad branch", "origin/main")

    def test_runner_failures_are_wrapped(self):
        def runner(argv, **kwargs):
            raise OSError("git missing")

        repo = GitRepository(self.checkout, runner=runner, environ=self.env)
        with self.assertRaises(CodeFactoryError) as caught:
            repo.head(self.checkout)
        self.assertEqual(caught.exception.code, "git_failed")
        self.assertIn("could not start", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
