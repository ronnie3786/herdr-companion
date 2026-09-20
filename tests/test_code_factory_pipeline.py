"""End-to-end journeys of the Code Factory orchestrator with fakes and a temporary git repository.

GitHub, Pi, the privacy check and the release script are scripted fakes; git worktrees,
branches, commits, pushes and merges are real operations against a temporary bare
remote. The clock and ``sleep`` are injected so CI polling never waits.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable

from herdr_harness.code_factory import prompts
from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.git import GitRepository
from herdr_harness.code_factory.github import GitHubClient
from herdr_harness.code_factory.pi import PiResult
from herdr_harness.code_factory.pipeline import CodeFactory, load_release_script
from herdr_harness.code_factory.settings import CodeFactorySettings
from herdr_harness.code_factory.store import CodeFactoryStore

REPO_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "owner/repo"
AUTHOR = "your-username"
MARKER = (
    '<!-- herdr-issue-report {"attachments":[{"asset":"isr_ab12-shot.png","contentType":"image/png","name":"shot.png",'
    '"size":4,"url":"https://github.com/owner/repo/releases/download/issue-attachments/isr_ab12-shot.png"}],'
    '"autofix":true,"environment":{},"kind":"bug","reportId":"isr_ab12","schema":1} -->'
)
ISSUE_BODY = (
    "  The HUD crashes when I open it.\n\n"
    "![shot](https://github.com/owner/repo/releases/download/issue-attachments/isr_ab12-shot.png)\n"
    "Also see https://github.com/user-attachments/assets/notes.md and "
    "https://github.com/other/repo/releases/download/x/evil.png\n\n"
    + MARKER
)


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
    }


def good_plan(**overrides) -> dict[str, Any]:
    plan = {
        "summary": "Guard the HUD window against a nil controller. Also add a regression test.",
        "kind": "bug",
        "acceptance_criteria": ["HUD opens without crashing", "Regression test exists"],
        "attachment_notes": "The screenshot shows a crash dialog.",
        "tasks": [
            {"id": "t1", "title": "Guard the nil window", "description": "Add a guard.", "owned_paths": ["app/"],
             "tests": ["python3 -m unittest tests.test_task_t1"], "docs": ["README.md feature row"]},
            {"id": "t2", "title": "Add a regression test", "description": "Cover the crash.", "owned_paths": ["tests/"],
             "tests": ["python3 -m unittest tests.test_task_t2"]},
        ],
        "release_notes_hint": "Fixed a crash when opening the HUD.",
        "risk": "low",
        "needs_human": False,
        "human_question": None,
    }
    plan.update(overrides)
    return plan


def json_reply(payload: dict[str, Any], prose: str = "Here is the result.") -> str:
    return f"{prose}\n\n```json\n{json.dumps(payload, indent=1)}\n```\n"


class FakeClock:
    def __init__(self, start: float = 1_800_000_000.0):
        self.now = start
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


class FakeGitHub:
    """Scripted GitHub: records calls; merges really land on the temporary remote."""

    def __init__(self, checkout: Path, env: dict[str, str]):
        self._checkout = checkout
        self._env = env
        # Merges happen "server-side" in a clone of the remote, never in the operator's
        # checkout, so parallel issues cannot race the daemon's own git commands.
        self._server = checkout.parent / "github-server"
        self._client = GitHubClient(REPOSITORY)
        self.issues: dict[int, dict[str, Any]] = {}
        self.calls: list[tuple[str, tuple[Any, ...]]] = []
        self.comments: dict[int, list[str]] = defaultdict(list)
        self.labels_added: dict[int, list[str]] = defaultdict(list)
        self.labels_removed: dict[int, list[str]] = defaultdict(list)
        self.closed: list[int] = []
        self.prs: dict[int, dict[str, Any]] = {}
        self.pr_by_branch: dict[str, int] = {}
        self.created_prs: list[dict[str, Any]] = []
        self.reviews: list[dict[str, Any]] = []
        self.verify_script: list[str] = []
        self.default_verify = "success"
        self.reruns: list[int] = []
        self.downloads: list[tuple[str, Path]] = []
        self.failing_downloads: set[str] = set()
        self.download_bytes: dict[str, bytes] = {}
        self.login_value = AUTHOR
        self.merges: list[dict[str, Any]] = []
        self.post_review_errors: list[Exception] = []
        self._merge_lock = threading.Lock()

    def _git(self, *args: str) -> str:
        if not self._server.exists():
            origin = subprocess.run(["git", "-C", str(self._checkout), "remote", "get-url", "origin"], env=self._env,
                                    capture_output=True, text=True, check=True).stdout.strip()
            subprocess.run(["git", "clone", "--quiet", origin, str(self._server)], env=self._env, capture_output=True, check=True)
        result = subprocess.run(["git", "-C", str(self._server), *args], env=self._env, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def add_issue(self, number: int, title: str, *, body: str = ISSUE_BODY, labels=("bug", "herdr-autofix"), author: str = AUTHOR, state: str = "OPEN") -> dict[str, Any]:
        issue = {
            "number": number, "title": title, "body": body, "author": {"login": author},
            "labels": [{"name": name} for name in labels], "url": f"https://github.com/{REPOSITORY}/issues/{number}",
            "createdAt": "2026-09-18T10:00:00Z", "updatedAt": "2026-09-18T10:00:00Z", "state": state,
        }
        self.issues[number] = issue
        return issue

    # -- issues --
    def login(self) -> str:
        self.calls.append(("login", ()))
        return self.login_value

    def list_issues(self, label: str) -> list[dict[str, Any]]:
        self.calls.append(("list_issues", (label,)))
        return [dict(issue) for issue in self.issues.values()
                if issue["state"] == "OPEN" and any(item["name"] == label for item in issue["labels"])]

    def get_issue(self, number: int) -> dict[str, Any]:
        self.calls.append(("get_issue", (number,)))
        if number not in self.issues:
            raise CodeFactoryError(f"gh issue view #{number} failed: not found", code="github_failed")
        return dict(self.issues[number])

    def add_labels(self, number: int, *labels: str) -> None:
        self.calls.append(("add_labels", (number, *labels)))
        self.labels_added[number].extend(labels)

    def remove_labels(self, number: int, *labels: str) -> None:
        self.calls.append(("remove_labels", (number, *labels)))
        self.labels_removed[number].extend(labels)

    def comment_issue(self, number: int, body: str) -> None:
        self.calls.append(("comment_issue", (number, body)))
        self.comments[number].append(body)

    def close_issue(self, number: int, *, comment: str | None = None) -> None:
        self.calls.append(("close_issue", (number, comment)))
        self.closed.append(number)
        self.issues[number]["state"] = "CLOSED"

    # -- attachments --
    def allowed_download(self, url: str) -> bool:
        return self._client.allowed_download(url)

    def download(self, url: str, destination) -> Path:
        self.calls.append(("download", (url, str(destination))))
        if url in self.failing_downloads:
            raise CodeFactoryError("attachment download returned HTTP 404", code="download_failed")
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(self.download_bytes.get(url) or (b"\x89PNG" if url.endswith(".png") else b"# notes\nrepro steps\n"))
        self.downloads.append((url, target))
        return target

    # -- pull requests --
    def create_pull_request(self, head: str, base: str, title: str, body: str) -> dict[str, Any]:
        self.calls.append(("create_pull_request", (head, base, title, body)))
        with self._merge_lock:
            number = 100 + len(self.prs)
            pr = {"number": number, "url": f"https://github.com/{REPOSITORY}/pull/{number}", "state": "OPEN",
                  "headRefName": head, "baseRefName": base, "title": title, "body": body, "headRefOid": ""}
            self.prs[number] = pr
            self.pr_by_branch[head] = number
            self.created_prs.append(pr)
        return {"number": number, "url": pr["url"]}

    def find_pull_request(self, head_branch: str) -> dict[str, Any] | None:
        self.calls.append(("find_pull_request", (head_branch,)))
        number = self.pr_by_branch.get(head_branch)
        if number is None:
            return None
        pr = self.prs[number]
        return {"number": number, "url": pr["url"], "state": pr["state"], "headRefOid": pr["headRefOid"]}

    def pull_request(self, number: int) -> dict[str, Any]:
        return dict(self.prs[number])

    def pull_request_diff(self, number: int) -> str:
        self.calls.append(("pull_request_diff", (number,)))
        return "diff --git a/app/task_t1.py b/app/task_t1.py\n+print('t1')\n"

    def verify_status(self, sha: str) -> str:
        self.calls.append(("verify_status", (sha,)))
        value = self.verify_script.pop(0) if self.verify_script else self.default_verify
        if isinstance(value, Exception):
            raise value
        return value

    def list_runs(self, sha: str) -> list[dict[str, Any]]:
        self.calls.append(("list_runs", (sha,)))
        return [{"status": "completed", "conclusion": "failure", "databaseId": 77,
                 "url": "https://github.com/owner/repo/actions/runs/77"}]

    def rerun_failed(self, run_id: int) -> None:
        self.calls.append(("rerun_failed", (run_id,)))
        self.reruns.append(run_id)

    def failed_run_log(self, sha: str) -> str:
        self.calls.append(("failed_run_log", (sha,)))
        return "FAIL: test_task (tests.test_task)\nAssertionError: boom\n"

    def post_review(self, number: int, body: str, comments=None) -> dict[str, Any]:
        self.calls.append(("post_review", (number, body, list(comments or []))))
        if self.post_review_errors:
            raise self.post_review_errors.pop(0)
        self.reviews.append({"number": number, "body": body, "comments": list(comments or [])})
        return {"id": len(self.reviews)}

    def merge_pull_request(self, number: int, *, subject: str | None = None, body: str | None = None,
                           head_sha: str | None = None) -> dict[str, Any]:
        self.calls.append(("merge_pull_request", (number, subject)))
        self.merges.append({"number": number, "subject": subject, "body": body, "headSha": head_sha})
        pr = self.prs[number]
        branch = pr["headRefName"]
        with self._merge_lock:
            # Squash-merge the way GitHub does: on the server, honouring --match-head-commit.
            self._git("fetch", "--quiet", "--prune", "origin")
            remote_head = self._git("rev-parse", f"refs/remotes/origin/{branch}")
            if head_sha and remote_head != head_sha:
                raise CodeFactoryError(f"gh pr merge #{number} failed: head {remote_head[:12]} does not match {head_sha[:12]}",
                                       code="github_failed")
            self._git("checkout", "--quiet", "main")
            self._git("reset", "--quiet", "--hard", "origin/main")
            self._git("merge", "--squash", "--quiet", f"origin/{branch}")
            self._git("commit", "--quiet", "-m", subject or pr["title"], *(["-m", body] if body else []))
            self._git("push", "--quiet", "origin", "main")
            self._git("push", "--quiet", "origin", "--delete", branch)
            self._git("fetch", "--quiet", "--prune", "origin")
            sha = self._git("rev-parse", "refs/remotes/origin/main")
        pr["state"] = "MERGED"
        pr["mergeCommit"] = {"oid": sha}
        return dict(pr, mergeSha=sha)

    def ensure_label(self, name: str, color: str, description: str) -> None:
        self.calls.append(("ensure_label", (name, color, description)))


class FakePi:
    """Role-aware Pi stand-in: plans, implements (commits real files), reviews, revises, releases."""

    def __init__(self, env: dict[str, str]):
        self._env = env
        self.calls: list[dict[str, Any]] = []
        self.plans: list[dict[str, Any] | str] = []
        self.reviews: list[dict[str, Any] | str] = []
        self.implement_noop = False
        self.release_mode = "commit"
        self.errors: dict[str, str] = {}
        self.error_once: dict[str, str] = {}
        self.raise_for: dict[str, Exception] = {}
        self.on_call: Callable[[dict[str, Any]], None] | None = None
        self.implementer_extra_files: dict[str, str] = {}
        self.block_roles: set[str] = set()
        self.session_started = threading.Event()
        self.reviewer_mentions_cwd = True

    @staticmethod
    def role_of(charter: str, name: str) -> str:
        if charter == prompts.PLANNER_CHARTER:
            return "planner"
        if charter == prompts.REVIEWER_CHARTER:
            return "reviewer"
        if charter == prompts.REVISER_CHARTER:
            return "reviser"
        if charter == prompts.RELEASE_AUTHOR_CHARTER:
            return "release-author"
        if charter == prompts.IMPLEMENTER_CHARTER:
            return "privacy-fix" if name.endswith(" privacy") else "implementer"
        raise AssertionError("unknown charter")

    def run(self, **kwargs: Any) -> PiResult:
        self.calls.append(kwargs)
        cwd = Path(kwargs["cwd"])
        name = kwargs["name"]
        role = self.role_of(kwargs["charter"], name)
        self.session_started.set()
        if self.on_call is not None:
            self.on_call(kwargs)
        if role in self.raise_for:
            raise self.raise_for.pop(role)
        Path(kwargs["log_path"]).parent.mkdir(parents=True, exist_ok=True)
        Path(kwargs["log_path"]).write_text('{"type":"herdr_runner_start"}\n', encoding="utf-8")
        if role in self.block_roles:
            # A long session: the real runner polls ``cancel`` about once a second and
            # terminates the process group once it is true.
            while not kwargs["cancel"]():
                time.sleep(0.01)
            return PiResult(text="", exit_code=-15, cost_usd=0.0, session_id=kwargs["session_id"], session_file=None,
                            log_path=Path(kwargs["log_path"]), error="cancelled", tool_steps=0)
        if role == "planner":
            text = self._scripted(self.plans, good_plan())
        elif role == "reviewer":
            default = {"verdict": "approve", "summary": f"Reviewed in {cwd}. Looks good."}
            text = self._scripted(self.reviews, default)
        elif role == "reviser":
            (cwd / "app").mkdir(exist_ok=True)
            (cwd / "app" / f"revision_{name.rsplit(' ', 1)[-1]}.txt").write_text("revised\n")
            text = "Addressed the review feedback. Tests: NOT RUN."
        elif role == "release-author":
            text = self._release(cwd, kwargs["prompt"])
        elif role == "privacy-fix":
            (cwd / "app" / "privacy_fix.txt").write_text("clean\n")
            text = "Removed the personal path."
        elif self.implement_noop:
            text = "Nothing to do."
        else:
            task_id = name.rsplit(" ", 1)[-1]
            (cwd / "app").mkdir(exist_ok=True)
            # Shared file with issue-independent content (identical additions squash-merge
            # cleanly when issues run in parallel) plus one file unique to this issue (so a
            # later issue still has something to commit after the first one merged).
            (cwd / "app" / f"task_{task_id}.py").write_text(f"print({task_id!r})\n")
            (cwd / "app" / f"{name.split()[0]}_{task_id}.txt").write_text(f"{name}\n")
            for relative, content in self.implementer_extra_files.items():
                target = cwd / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            text = f"Implemented {task_id}: app/task_{task_id}.py. Tests: python3 -m unittest tests.test_{task_id} (NOT RUN)."
        error = self.error_once.pop(role, None) or self.errors.get(role)
        return PiResult(
            text="" if error else text, exit_code=1 if error else 0, cost_usd=0.01, session_id=kwargs["session_id"],
            session_file=None, log_path=Path(kwargs["log_path"]), error=error, tool_steps=2,
        )

    @staticmethod
    def _scripted(queue: list[dict[str, Any] | str], default: dict[str, Any]) -> str:
        item = queue.pop(0) if queue else default
        return item if isinstance(item, str) else json_reply(item)

    def _release(self, cwd: Path, prompt: str) -> str:
        part = "minor" if "--part minor" in prompt else "patch"
        subprocess.run([sys.executable, "scripts/release-macos.py", "bump", "--part", part, "--channel", "preview"],
                       cwd=cwd, env=self._env, capture_output=True, text=True, check=True)
        version = json.loads((cwd / "release" / "macos.json").read_text())
        label = f"{version['version']}-beta.{version['preview']}"
        notes = cwd / "release" / "notes" / f"macos-{label}.md"
        notes.parent.mkdir(parents=True, exist_ok=True)
        notes.write_text(f"# macOS {label}\n\n## Fixes\n\n- Fixed a crash when opening the HUD.\n\n## Companion compatibility\n\nMac only.\n")
        if self.release_mode == "dirty":
            return "Wrote the notes but forgot to commit."
        if self.release_mode == "extra":
            (cwd / "scripts" / "release-macos.py").write_text("print('tampered')\n")
        message = f"Prepare macOS {label}" if self.release_mode != "subject" else f"Release {label} (Closes #21)"
        subprocess.run(["git", "add", "-A"], cwd=cwd, env=self._env, check=True, capture_output=True)
        subprocess.run(["git", "commit", "--quiet", "-m", message], cwd=cwd, env=self._env, check=True, capture_output=True)
        return f"Committed release/notes/macos-{label}.md as {message}."


class FakeCheckRunner:
    def __init__(self):
        self.calls: list[tuple[list[str], dict[str, Any]]] = []
        self.findings_script: list[list[dict[str, Any]]] = []

    def __call__(self, argv, **kwargs):
        self.calls.append((list(argv), kwargs))
        findings = self.findings_script.pop(0) if self.findings_script else []
        stdout = json.dumps({"ok": not findings, "filesChecked": 3, "findings": findings})
        return SimpleNamespace(returncode=1 if findings else 0, stdout=stdout, stderr="")


class FakeReleaseRunner:
    def __init__(self, env: dict[str, str] | None = None):
        self.calls: list[tuple[list[str], dict[str, Any]]] = []
        self.fail_step: str | None = None
        self.prepared_heads: list[str] = []
        self._env = env

    def __call__(self, argv, **kwargs):
        argv = list(argv)
        self.calls.append((argv, kwargs))
        step = argv[2]
        if step == self.fail_step:
            return SimpleNamespace(returncode=1, stdout="", stderr="Keychain locked")
        cwd = Path(kwargs["cwd"])
        if step == "prepare":
            output = Path(argv[argv.index("--output") + 1])
            output.mkdir(parents=True)
            self.prepared_heads.append(subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, env=self._env,
                                                      capture_output=True, text=True, check=True).stdout.strip())
            version = json.loads((cwd / "release" / "macos.json").read_text())
            tag = f"macos-v{version['version']}-beta.{version['preview']}"
            (output / "prepared.json").write_text(json.dumps({"schema": 1, "tag": tag}))
            payload = {"ok": True, "prepared": str(output / "prepared.json"), "tag": tag, "published": False}
            return SimpleNamespace(returncode=0, stdout="notice line\n" + json.dumps(payload) + "\n", stderr="")
        manifest = json.loads(Path(argv[3]).read_text())
        return SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True, "published": manifest["tag"]}), stderr="")


class PipelineTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = isolated_environment(self.home)
        self.remote = self.root / "remote.git"
        self.checkout = self.root / "checkout"
        self.git(["init", "--quiet", "--bare", "--initial-branch=main", str(self.remote)])
        self.git(["clone", "--quiet", str(self.remote), str(self.checkout)])
        self.git(["checkout", "--quiet", "-b", "main"], cwd=self.checkout)
        (self.checkout / "README.md").write_text("# Synthetic\n\nVerify with `python3 -m unittest`.\n")
        (self.checkout / "AGENTS.md").write_text("Keep it synthetic.\n")
        (self.checkout / "release").mkdir()
        (self.checkout / "release" / "notes").mkdir()
        (self.checkout / "release" / "macos.json").write_text(
            json.dumps({"build": 46, "channel": "preview", "preview": 1, "version": "0.20.0"}, indent=2, sort_keys=True) + "\n")
        (self.checkout / "release" / "notes" / "macos-0.20.0-beta.1.md").write_text("# macOS 0.20.0-beta.1\n")
        (self.checkout / "scripts").mkdir()
        shutil.copy(REPO_ROOT / "scripts" / "release-macos.py", self.checkout / "scripts" / "release-macos.py")
        (self.checkout / "scripts" / "check-public-source.py").write_text("#!/usr/bin/env python3\nprint('{\"ok\": true, \"findings\": []}')\n")
        self.git(["add", "-A"], cwd=self.checkout)
        self.git(["commit", "--quiet", "-m", "Initial"], cwd=self.checkout)
        self.git(["push", "--quiet", "-u", "origin", "main"], cwd=self.checkout)
        self.logs: list[str] = []
        self.clock = FakeClock()
        self.github = FakeGitHub(self.checkout, self.env)
        self.pi = FakePi(self.env)
        self.checks = FakeCheckRunner()
        self.releases = FakeReleaseRunner(self.env)
        self.side_clones: list[Path] = []
        self.store: CodeFactoryStore | None = None
        self.factory = self.make_factory()

    def git(self, args, cwd=None) -> str:
        result = subprocess.run(["git", *args], cwd=str(cwd) if cwd else None, env=self.env, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def make_settings(self, **overrides: str) -> CodeFactorySettings:
        environ = {
            "HOME": str(self.home),
            "HERDR_STATE_DIR": str(self.root / "state"),
            "HERDR_CODE_FACTORY_REPOSITORY": REPOSITORY,
            "HERDR_CODE_FACTORY_CHECKOUT": str(self.checkout),
            "HERDR_CODE_FACTORY_POLL_SECONDS": "10",
            "HERDR_CODE_FACTORY_MAX_REVIEW_ROUNDS": "3",
            "HERDR_CODE_FACTORY_VERIFY_WAIT_SECONDS": "120",
            "HERDR_CODE_FACTORY_SESSION_TIMEOUT_SECONDS": "60",
            "HERDR_CODE_FACTORY_ALLOWED_AUTHORS": AUTHOR,
            "HERDR_CODE_FACTORY_PYTHON": sys.executable,
            "HERDR_CONFIG": str(self.root / "config.toml"),
            "HERDR_MACHINE": "desktop",
        }
        environ.update({f"HERDR_CODE_FACTORY_{key.upper()}": value for key, value in overrides.items()})
        return CodeFactorySettings.from_environ(environ)

    def make_factory(self, **overrides: str) -> CodeFactory:
        self.settings = self.make_settings(**overrides)
        if self.store is None:
            self.store = CodeFactoryStore(self.settings.state_path)
            self.addCleanup(self.store.close)
        self.repo = GitRepository(self.checkout, environ=self.env)
        return CodeFactory(
            self.settings, self.store, github=self.github, git=self.repo, pi=self.pi, clock=self.clock,
            sleep=self.clock.sleep, release_runner=self.releases, log=self.logs.append, check_runner=self.checks,
        )

    def sessions(self, number: int | None) -> list[str]:
        """Session roles in start order, derived from the fake's chronological call log."""
        prefix = "release " if number is None else f"issue-{number} "
        roles = []
        for call in self.pi.calls:
            if not call["name"].startswith(prefix):
                continue
            charter, name = call["charter"], call["name"]
            if charter == prompts.PLANNER_CHARTER:
                roles.append("planner")
            elif charter == prompts.REVIEWER_CHARTER:
                roles.append("reviewer")
            elif charter == prompts.REVISER_CHARTER:
                roles.append("reviser")
            elif charter == prompts.RELEASE_AUTHOR_CHARTER:
                roles.append("release-author")
            else:
                roles.append("privacy-fix" if name.endswith(" privacy") else "implementer")
        stored = sorted(session["role"] for session in self.store.list_sessions(number))
        self.assertEqual(stored, sorted(roles), "every fake session is recorded in the ledger")
        return roles

    def events(self, number: int) -> list[str]:
        return [event["message"] for event in reversed(self.store.list_events(number, 500))]

    def remote_subjects(self, ref: str = "main") -> list[str]:
        return self.git(["log", "--format=%s", ref], cwd=self.remote).splitlines()

    def assert_public(self, text: str) -> None:
        self.assertNotIn(str(self.root), text, "local paths must never reach GitHub")
        self.assertNotIn("/Users/", text)

    def side_push(self, branch: str, filename: str, message: str) -> str:
        """Land a commit on ``branch`` of the remote from a separate clone (another contributor)."""
        clone = self.root / f"side-{len(self.side_clones)}"
        self.side_clones.append(clone)
        self.git(["clone", "--quiet", str(self.remote), str(clone)])
        self.git(["checkout", "--quiet", "-B", "work", f"origin/{branch}"], cwd=clone)
        (clone / filename).parent.mkdir(parents=True, exist_ok=True)
        (clone / filename).write_text(f"{message}\n")
        self.git(["add", "-A"], cwd=clone)
        self.git(["commit", "--quiet", "-m", message], cwd=clone)
        self.git(["push", "--quiet", "origin", f"HEAD:refs/heads/{branch}"], cwd=clone)
        return self.git(["rev-parse", "HEAD"], cwd=clone)

    def event_detail(self, number: int, prefix: str) -> Any:
        return next(event["detail"] for event in self.store.list_events(number, 500) if event["message"].startswith(prefix))


class HappyPathTests(PipelineTestCase):
    def test_full_journey_then_patch_release(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.failing_downloads.add("https://github.com/user-attachments/assets/notes.md")
        self.github.verify_script = ["pending", "failure", "success", "success"]
        self.pi.reviews = [
            {"verdict": "request_changes", "summary": "Needs a nil guard.",
             "comments": [{"path": "app/task_t1.py", "line": 1,
                           "body": f"Guard nil here (seen in {self.settings.worktree_root / 'issue-12'})."}],
             "blocking": ["Missing nil guard"], "non_blocking": []},
            {"verdict": "approve", "summary": f"All criteria met (checked in {self.settings.worktree_root / 'issue-12'})."},
        ]
        self.store.set_daemon("dashboard_url", "http://127.0.0.1:9097/")

        counts = self.factory.poll_once()
        self.assertEqual(counts["new"], 1)
        self.assertEqual(counts["queued"], [12])
        self.assertFalse(counts["releaseStarted"])
        self.assertIsNotNone(self.store.daemon_info()["lastPollAt"])
        issue = self.factory.run_issue(12)

        self.assertEqual(issue["status"], "active")
        self.assertEqual(issue["stage"], "release")
        self.assertEqual(issue["kind"], "bug")
        self.assertEqual(issue["attempts"], 1)
        self.assertEqual(issue["reviewRound"], 2, "request_changes + approve")
        self.assertEqual(issue["ciFailures"], 1)
        self.assertEqual(issue["ciStatus"], "success")
        self.assertEqual(issue["prNumber"], 100)
        self.assertTrue(issue["worktreeCleaned"])
        self.assertIsNotNone(issue["mergeSha"])
        self.assertEqual(issue["planSummary"], good_plan()["summary"])
        worktree = Path(issue["worktreePath"])
        self.assertEqual(worktree, self.settings.worktree_root / "issue-12")
        self.assertFalse(worktree.exists(), "worktree removed right after merge")
        self.assertFalse(self.repo.branch_exists("codefactory/issue-12"))
        self.assertEqual(len(self.repo.list_worktrees()), 1)
        self.assertEqual(self.sessions(12), ["planner", "implementer", "implementer", "reviewer", "reviser", "reviewer"])
        for session in self.store.list_sessions(12):
            self.assertEqual(session["exitCode"], 0)
            self.assertEqual(session["costUSD"], 0.01)
            self.assertIsNotNone(session["finishedAt"])

        runs = self.settings.runs_root / "issue-12"
        self.assertTrue((runs / "issue.json").is_file())
        self.assertTrue((runs / "plan.json").is_file())
        self.assertIn("# Plan for issue #12", (runs / "plan.md").read_text())
        self.assertEqual(sorted(path.name for path in (runs / "attachments").iterdir()), ["01-shot.png"])
        planner = self.pi.calls[0]
        self.assertEqual(planner["attachments"], [str(runs / "attachments" / "01-shot.png")])
        self.assertEqual(planner["tools"], "read,bash,grep,find,ls")
        self.assertEqual(planner["model"], self.settings.planner_model)
        self.assertEqual(planner["thinking"], "xhigh")
        self.assertIn("<<<ISSUE_BODY\n" + ISSUE_BODY + "\nISSUE_BODY>>>", planner["prompt"])
        self.assertEqual(planner["name"], "issue-12 plan")
        self.assertEqual(planner["cwd"], str(worktree))
        implementer = self.pi.calls[1]
        self.assertEqual(implementer["model"], self.settings.implementer_model)
        self.assertEqual(implementer["thinking"], "max")
        self.assertEqual(implementer["tools"], "read,bash,edit,write,grep,find,ls")
        self.assertEqual(implementer["name"], "issue-12 t1")
        self.assertIn("Implemented t1", self.pi.calls[2]["prompt"], "task 2 sees the first summary")
        reviser = self.pi.calls[4]
        self.assertIn("- Missing nil guard", reviser["prompt"])
        self.assertIn("`app/task_t1.py:1`", reviser["prompt"])
        events = self.events(12)
        failed_head = next(args[0] for name, args in self.github.calls if name == "list_runs")
        self.assertEqual(issue["ciRerunRequested"], failed_head)
        self.assertIn("Skipped attachment 03-evil.png: host not allowed", events)
        self.assertTrue(any(message.startswith("Attachment 02-notes.md not downloaded") for message in events))
        self.assertIn("Picked up; 1 attachment(s) downloaded", events)
        self.assertIn("Plan ready: 2 task(s), risk low", events)
        self.assertIn("Task t1 finished: Guard the nil window", events)
        self.assertIn("Opened PR #100", events)
        self.assertIn(f"Verify failed on {failed_head[:12]}; re-running failed jobs once", events)
        self.assertIn("Review round 1: request_changes", events)
        self.assertIn("Review round 2: approve", events)
        self.assertIn("Squash-merged PR #100", events)
        self.assertIn("Worktree cleaned up", events)
        self.assertIn("Queued for the next release batch", events)
        self.assertEqual(self.clock.sleeps, [30], "one poll while CI was pending")

        pr = self.github.created_prs[0]
        self.assertEqual(pr["title"], "Guard the HUD window against a nil controller.")
        self.assertTrue(pr["body"].startswith("Refs #12\n"))
        self.assertNotIn("Closes", pr["body"])
        self.assertIn("- t1: Guard the nil window", pr["body"])
        self.assertIn("Filed automatically by the Herdr Code Factory.", pr["body"])
        self.assert_public(pr["body"])
        self.assertEqual(len(self.github.reviews), 2)
        self.assertTrue(self.github.reviews[0]["body"].startswith("### Astra review (round 1): request_changes"))
        self.assertTrue(self.github.reviews[1]["body"].startswith("### Astra review (round 2): approve"))
        self.assertEqual(self.github.reviews[0]["comments"][0]["path"], "app/task_t1.py")
        self.assertIn("<local>", self.github.reviews[0]["comments"][0]["body"])
        self.assertIn("<local>", self.github.reviews[1]["body"])
        for review in self.github.reviews:
            self.assert_public(review["body"])
        comments = self.github.comments[12]
        self.assertEqual(comments[0], "🤖 Code Factory picked this up.", "the dashboard URL never reaches GitHub")
        self.assertEqual(next(event["detail"] for event in self.store.list_events(12, 500)
                              if event["message"].startswith("Picked up;")), {"dashboardUrl": "http://127.0.0.1:9097/"})
        self.assertTrue(comments[1].startswith("🧭 Plan (Astra)"))
        self.assertIn("1. t1 — Guard the nil window", comments[1])
        self.assertTrue(comments[2].startswith(f"Merged as {issue['mergeSha'][:12]} in PR #100; queued for the next release."))
        for comment in comments:
            self.assert_public(comment)
        merge_call = next(call for call in self.github.calls if call[0] == "merge_pull_request")
        self.assertEqual(merge_call[1], (100, "Guard the HUD window against a nil controller."))
        merge = self.github.merges[0]
        self.assertEqual(merge["headSha"], issue["headSha"], "the squash merge is pinned to the reviewed head")
        self.assertRegex(merge["headSha"], r"^[0-9a-f]{40}$")
        self.assertTrue(merge["body"].startswith("Refs #12\n"), "the merge commit body is the neutralized PR body")
        self.assert_public(merge["body"])
        self.assertIn("Refs #12", self.git(["log", "-1", "--format=%B", "main"], cwd=self.remote))
        self.assertEqual(self.remote_subjects(), ["Guard the HUD window against a nil controller.", "Initial"])
        tree = self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote).splitlines()
        for name in ("app/task_t1.py", "app/task_t2.py", "app/revision_1.txt"):
            self.assertIn(name, tree)
        self.assertEqual(self.checks.calls[0][0], [sys.executable, "scripts/check-public-source.py"])
        self.assertEqual(self.checks.calls[0][1]["cwd"], str(worktree))
        self.assertEqual(self.github.closed, [], "the issue stays open until it is released")

        counts = self.factory.poll_once()
        self.assertTrue(counts["releaseStarted"])
        release = self.store.list_releases()[0]
        self.assertEqual(release["tag"], "macos-v0.20.1-beta.1", "bug-only batch bumps the patch version")
        self.assertEqual(release["version"], "0.20.1-beta.1")
        self.assertEqual(release["status"], "published")
        self.assertEqual(release["issueNumbers"], [12])
        self.assertEqual(release["url"], f"https://github.com/{REPOSITORY}/releases/tag/macos-v0.20.1-beta.1")
        self.assertEqual(release["notesPath"], "release/notes/macos-0.20.1-beta.1.md")
        self.assertIsNotNone(release["sourceSha"])
        self.assertIsNotNone(release["finishedAt"])
        issue = self.store.get_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("done", "done"))
        self.assertEqual(issue["releaseTag"], "macos-v0.20.1-beta.1")
        self.assertEqual(issue["releaseVersion"], "0.20.1-beta.1")
        self.assertEqual(issue["releaseUrl"], release["url"])
        self.assertIsNotNone(issue["finishedAt"])
        self.assertEqual(self.github.closed, [12])
        self.assertEqual(self.github.labels_added[12], ["released"])
        self.assertEqual(self.github.comments[12][-1], f"🚀 Released in macos-v0.20.1-beta.1: {release['url']}")
        self.assertEqual(self.sessions(None), ["release-author"])
        author = self.pi.calls[-1]
        self.assertEqual(author["charter"], prompts.RELEASE_AUTHOR_CHARTER)
        self.assertIn(f"{sys.executable} scripts/release-macos.py bump --part patch --channel preview", author["prompt"].replace("'", ""))
        self.assertIn("- #12 Crash when opening the HUD (bug)", author["prompt"])
        self.assertIn("Release notes hint: Fixed a crash when opening the HUD.", author["prompt"])
        self.assertEqual(self.remote_subjects()[0], "Prepare macOS 0.20.1-beta.1")
        self.assertIn("release/notes/macos-0.20.1-beta.1.md", self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote))
        prepare_argv, prepare_kwargs = self.releases.calls[0]
        self.assertEqual(prepare_argv[:3], [sys.executable, "scripts/release-macos.py", "prepare"])
        self.assertIn("--config", prepare_argv)
        self.assertEqual(prepare_argv[prepare_argv.index("--config") + 1], str(self.root / "config.toml"))
        self.assertEqual(prepare_argv[prepare_argv.index("--machine") + 1], "desktop")
        self.assertTrue(prepare_argv[prepare_argv.index("--notes") + 1].endswith("release/notes/macos-0.20.1-beta.1.md"))
        self.assertEqual(prepare_argv[prepare_argv.index("--output") + 1], str(self.settings.release_output_root / "0.20.1-beta.1"))
        self.assertEqual(prepare_kwargs["timeout"], 3 * 3600)
        self.assertTrue(prepare_kwargs["cwd"].startswith(str(self.settings.worktree_root / "release-")))
        publish_argv, _ = self.releases.calls[1]
        self.assertEqual(publish_argv[2], "publish")
        self.assertTrue(publish_argv[3].endswith("prepared.json"))
        self.assertEqual(publish_argv[4:], ["--config", str(self.root / "config.toml"), "--machine", "desktop"])
        self.assertEqual(len(self.repo.list_worktrees()), 1, "release worktree removed")
        self.assertEqual([path.name for path in self.settings.worktree_root.iterdir() if path.is_dir()], [])
        self.assertEqual(self.store.stats()["released"], 1)
        self.assertEqual(self.store.stats()["worktreesPending"], 0)
        self.assertTrue(self.factory.poll_once()["releaseStarted"] is False, "nothing left to release")


class BlockingAndActionTests(PipelineTestCase):
    def run_to_block(self, number: int = 12, plan=None):
        self.github.add_issue(number, "Crash when opening the HUD")
        self.pi.plans = [plan or good_plan(needs_human=True, human_question="Which window crashes?", tasks=[], acceptance_criteria=[])]
        self.factory.poll_once()
        return self.factory.run_issue(number)

    def test_needs_human_blocks_and_retry_resumes(self):
        issue = self.run_to_block()
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "plan", "human_question"))
        self.assertIsNone(issue["error"])
        self.assertIn("Which window crashes?", self.github.comments[12][-1])
        self.assertTrue(Path(issue["worktreePath"]).is_dir(), "the worktree is kept for the retry")
        with self.assertRaises(CodeFactoryError) as caught:
            self.factory.action(12, "cleanup_everything")
        self.assertEqual(caught.exception.code, "invalid_request")
        with self.assertRaises(CodeFactoryError) as caught:
            self.factory.action(99, "retry")
        self.assertEqual(caught.exception.code, "not_found")

        result = self.factory.action(12, "retry")
        self.assertEqual((result["issue"]["status"], result["issue"]["stage"]), ("active", "plan"))
        self.assertIsNone(result["issue"]["blockedReason"])
        self.assertFalse(result["queued"], "no executor is running; the caller processes it")
        with self.assertRaises(CodeFactoryError):
            self.factory.action(12, "retry")
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("active", "release"))
        self.assertEqual(issue["attempts"], 2)
        self.assertEqual(self.sessions(12), ["planner", "planner", "implementer", "implementer", "reviewer"])

    def test_review_rounds_exhausted(self):
        self.factory = self.make_factory(max_review_rounds="1")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.pi.reviews = [{"verdict": "request_changes", "summary": "No.", "blocking": ["x"]}] * 2
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "review", "review_rounds_exhausted"))
        self.assertEqual(issue["reviewRound"], 1)
        self.assertEqual(len(self.github.reviews), 1)
        self.assertEqual(self.sessions(12)[-2:], ["reviewer", "reviser"])
        self.assertTrue(Path(issue["worktreePath"]).is_dir())
        self.assertIn("Blocked (review_rounds_exhausted): 1 review round(s) used", self.events(12))

    def test_ci_failures_are_bounded_separately_from_review_rounds(self):
        self.factory = self.make_factory(max_ci_failures="1")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.verify_script = ["failure", "failure"]
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "verify", "ci_failures_exhausted"))
        self.assertEqual(issue["ciStatus"], "failure")
        self.assertEqual(issue["reviewRound"], 0)
        self.assertEqual(issue["ciFailures"], 1)
        self.assertEqual(self.sessions(12).count("reviser"), 0)
        self.assertEqual(sum(1 for call in self.github.calls if call[0] == "rerun_failed"), 1)

    def test_ci_rerun_that_passes_needs_no_revision(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.verify_script = ["failure", "success"]
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("active", "release"))
        self.assertEqual(issue["ciFailures"], 1)
        self.assertEqual(issue["reviewRound"], 1, "the only round is Astra's approval")
        self.assertNotIn("reviser", self.sessions(12))
        self.assertEqual(self.github.reruns, [77])

    def test_second_ci_failure_goes_to_revise_without_a_review_round(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.verify_script = ["failure", "failure"]
        self.github.default_verify = "pending"
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "verify", "ci_timeout"))
        self.assertEqual(issue["reviewRound"], 0)
        self.assertEqual(issue["ciFailures"], 2)
        self.assertIn("reviser", self.sessions(12))
        events = self.events(12)
        self.assertEqual(sum("re-running failed jobs once" in message for message in events), 1)
        self.assertTrue(any("(CI failure 2)" in message for message in events))

    def test_ci_timeout_blocks(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.default_verify = "pending"
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "verify", "ci_timeout"))
        self.assertEqual(issue["ciStatus"], "pending")
        self.assertEqual(self.clock.sleeps, [30, 30, 30, 30], "polled every 30 s until verify_wait_seconds elapsed")

    def test_skip_removes_worktree_and_label(self):
        issue = self.run_to_block()
        result = self.factory.action(12, "skip")
        skipped = result["issue"]
        self.assertEqual(skipped["status"], "skipped")
        self.assertTrue(skipped["worktreeCleaned"])
        self.assertIsNotNone(skipped["finishedAt"])
        self.assertFalse(Path(issue["worktreePath"]).exists())
        self.assertFalse(self.repo.branch_exists("codefactory/issue-12"))
        self.assertEqual(self.github.labels_removed[12], ["herdr-autofix"])
        with self.assertRaises(CodeFactoryError):
            self.factory.action(12, "retry")
        self.assertIsNone(self.factory.run_issue(12)["error"])
        self.assertEqual(self.store.get_issue(12)["status"], "skipped", "run_issue leaves non-active issues alone")

    def test_skip_while_running_wins_and_cleans_up_after_the_worker(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        seen: dict[str, Any] = {}

        def skip_mid_implement(call: dict[str, Any]) -> None:
            if call["name"] != "issue-12 t1":
                return
            seen["before"] = call["cancel"]()
            result = self.factory.action(12, "skip")
            seen["action"] = result["issue"]
            seen["after"] = call["cancel"]()
            seen["worktree_present"] = Path(result["issue"]["worktreePath"]).is_dir()

        self.pi.on_call = skip_mid_implement
        issue = self.factory.run_issue(12)
        self.assertFalse(seen["before"])
        self.assertTrue(seen["after"], "the running session is asked to stop")
        self.assertEqual(seen["action"]["status"], "skipped")
        self.assertFalse(seen["action"]["worktreeCleaned"], "cleanup waits for the worker")
        self.assertTrue(seen["worktree_present"], "the session's cwd is not pulled out from under it")
        self.assertEqual((issue["status"], issue["stage"], issue["error"]), ("skipped", "implement", None))
        self.assertTrue(issue["worktreeCleaned"])
        self.assertFalse(Path(issue["worktreePath"]).exists())
        self.assertFalse(self.repo.branch_exists("codefactory/issue-12"))
        self.assertEqual(self.github.labels_removed[12], ["herdr-autofix"])
        self.assertEqual(self.github.created_prs, [], "no later stage ran after the skip")
        self.assertEqual(self.sessions(12), ["planner", "implementer"])
        events = self.events(12)
        self.assertIn("Skipped; the running session is being cancelled and the worktree is removed once it exits", events)
        self.assertIn("issue #12: interrupted at implement", self.logs, "the worker stops at its next checkpoint")
        self.assertEqual(events[-1], "Worktree cleaned up")
        self.assertFalse(self.factory.is_running(12))

    def test_skip_while_running_is_not_overwritten_by_the_stage_failure(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()

        def skip_then_fail(call: dict[str, Any]) -> None:
            if call["name"] == "issue-12 t1":
                self.factory.action(12, "skip")
                self.pi.error_once["implementer"] = "pi exited with status 1"

        self.pi.on_call = skip_then_fail
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["error"]), ("skipped", None), "the skip wins over the worker's failure")
        self.assertTrue(issue["worktreeCleaned"])
        self.assertFalse(Path(issue["worktreePath"]).exists())
        self.assertIn("Ignored failure (implementer session failed: pi exited with status 1) at Implementing (DeepSeek): "
                      "the issue was marked skipped meanwhile", self.events(12))
        with self.assertRaises(CodeFactoryError):
            self.factory.action(12, "retry")

    def test_verify_failure_bound_does_not_inflate_the_ci_counter(self):
        self.factory = self.make_factory(max_ci_failures="1")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.default_verify = "failure"
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "verify", "ci_failures_exhausted"))
        self.assertEqual(issue["reviewRound"], 0)
        self.assertEqual(issue["ciFailures"], 1)
        for attempt in range(2):
            self.factory.action(12, "retry")
            issue = self.factory.run_issue(12)
            self.assertEqual((issue["status"], issue["blockedReason"]), ("blocked", "ci_failures_exhausted"))
            self.assertEqual(issue["reviewRound"], 0)
            self.assertEqual(issue["ciFailures"], 1, "a retry on the same failing head never exceeds the configured maximum")
        self.assertEqual(self.github.reruns, [77])
        self.assertEqual(sum(1 for call in self.github.calls if call[0] == "failed_run_log"), 0,
                         "no log is fetched for a CI failure that is going to block")
        self.assertIn("Blocked (ci_failures_exhausted): 1 CI failure(s) used; CI still failing", self.events(12))

    def test_session_row_is_finished_when_the_runner_raises(self):
        self.pi.raise_for["planner"] = CodeFactoryError("cwd must be an existing directory", code="invalid_request")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("failed", "plan"))
        self.assertEqual(issue["error"], "planner session could not run: cwd must be an existing directory")
        session = self.store.list_sessions(12)[0]
        self.assertIsNotNone(session["finishedAt"], "the ledger never shows the session as running forever")
        self.assertEqual(session["exitCode"], -1)
        self.assertEqual(session["summary"], "cwd must be an existing directory")
        self.assertEqual(self.store.list_events(12, 1)[0]["detail"], {"code": "pi_failed"})

    def test_review_survives_a_failed_post_and_a_retry_reposts_it(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.post_review_errors = [CodeFactoryError("gh api failed: HTTP 502 bad gateway", code="github_failed")]
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["reviewRound"]), ("failed", "review", 1))
        self.assertIn("HTTP 502", issue["error"])
        self.assertEqual(issue["planJson"]["last_review"]["verdict"], "approve", "the validated review is persisted before posting")
        self.assertIs(issue["planJson"]["last_review_posted"], False)
        self.factory.action(12, "retry")
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["reviewRound"]), ("active", "release", 1))
        self.assertEqual(self.sessions(12).count("reviewer"), 1, "the retry reposts the stored review instead of re-reviewing")
        self.assertEqual(len(self.github.reviews), 1)
        self.assertIn("Posting the stored review for round 1; the earlier post failed", self.events(12))
        self.assertIs(self.store.get_issue(12)["planJson"]["last_review_posted"], True)

    def test_transient_verify_errors_are_tolerated_up_to_a_cap(self):
        blip = CodeFactoryError("gh run list failed: HTTP 403 rate limit exceeded", code="github_failed")
        self.factory = self.make_factory(release_enabled="false")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.verify_script = ["pending", blip, blip, "success"]
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["ciStatus"]), ("done", "done", "success"))
        events = self.events(12)
        self.assertIn("Verify status check failed (1/5): gh run list failed: HTTP 403 rate limit exceeded", events)
        self.assertIn("Verify status check failed (2/5): gh run list failed: HTTP 403 rate limit exceeded", events)
        self.assertEqual(self.clock.sleeps, [30, 30, 30], "polling continued through the blips")
        self.github.add_issue(13, "Another crash")
        self.github.verify_script = [blip] * 5 + ["success"]
        self.factory.poll_once()
        issue = self.factory.run_issue(13)
        self.assertEqual((issue["status"], issue["stage"]), ("failed", "verify"))
        self.assertEqual(issue["error"], "gh run list failed: HTTP 403 rate limit exceeded")
        self.assertIn("Verify status check failed (5/5): gh run list failed: HTTP 403 rate limit exceeded", self.events(13))

    def test_cleanup_then_retry_at_implement_reruns_the_lost_tasks(self):
        finding = {"file": "app/task_t1.py", "line": 1, "category": "personal home path"}
        self.checks.findings_script = [[finding], [finding]]
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "implement", "privacy_check_failed"))
        self.factory.action(12, "cleanup")
        self.assertFalse(self.repo.branch_exists("codefactory/issue-12"), "the only copy of the commits is gone")
        self.factory.action(12, "retry")
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("active", "release", None))
        self.assertEqual(self.sessions(12).count("implementer"), 4, "every task is implemented again on the fresh branch")
        events = self.events(12)
        self.assertIn("Worktree created on codefactory/issue-12 from origin/main", events)
        self.assertTrue(any(message.startswith("The branch's unpushed commits are gone") for message in events))
        tree = self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote)
        self.assertIn("app/task_t1.py", tree)
        self.assertIn("app/task_t2.py", tree)

    def test_cleanup_then_retry_at_revise_keeps_the_pushed_commits(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.verify_script = ["failure", "failure"]
        self.pi.error_once["reviser"] = "timeout"
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("failed", "revise"))
        self.factory.action(12, "cleanup")
        self.assertFalse(Path(issue["worktreePath"]).exists())
        self.factory.action(12, "retry")
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("active", "release"))
        self.assertEqual(self.sessions(12).count("implementer"), 2, "the pushed task commits are reused, not re-done")
        self.assertIn("Worktree created on codefactory/issue-12 from origin/codefactory/issue-12", self.events(12))
        tree = self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote)
        for name in ("app/task_t1.py", "app/task_t2.py", "app/revision_0.txt"):
            self.assertIn(name, tree)

    def test_missing_worktree_directory_is_recreated_on_retry(self):
        issue = self.run_to_block()
        shutil.rmtree(issue["worktreePath"])
        self.assertTrue(any(entry["prunable"] for entry in self.repo.list_worktrees()), "git still lists the stale registration")
        self.factory.action(12, "retry")
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("active", "release"))
        self.assertIn("Worktree created on codefactory/issue-12 from local branch codefactory/issue-12", self.events(12))
        self.assertFalse(any(entry["prunable"] for entry in self.repo.list_worktrees()))

    def test_privacy_gate_refuses_a_modified_check_script(self):
        self.pi.implementer_extra_files["scripts/check-public-source.py"] = "print('{\"ok\": true, \"findings\": []}')  # tampered\n"
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("failed", "implement"))
        self.assertEqual(issue["error"], "scripts/check-public-source.py was modified on this branch; "
                                         "the daemon only runs the copy from origin/main")
        self.assertEqual(self.checks.calls, [], "the worktree's copy of the check is never executed")
        self.assertEqual(self.github.created_prs, [])

    def test_public_texts_never_carry_dashboard_or_secret_material(self):
        tailnet_ip = ".".join(["100", "100", "7", "8"])
        tailnet_host = "hud." + "tail" + "0badf00d" + ".ts" + ".net"
        key = "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nAAAA\n-----END " + "OPENSSH PRIVATE KEY-----"
        token = "ghp_" + "A" * 36
        self.store.set_daemon("dashboard_url", f"http://{tailnet_ip}:9097/")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.pi.plans = [good_plan(needs_human=True, tasks=[], acceptance_criteria=[],
                                   human_question=f"Is {tailnet_host} the right host? key {key} token {token} ip {tailnet_ip}")]
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual(issue["blockedReason"], "human_question")
        pickup, question = self.github.comments[12]
        self.assertEqual(pickup, "🤖 Code Factory picked this up.")
        self.assertEqual(self.event_detail(12, "Picked up;"), {"dashboardUrl": f"http://{tailnet_ip}:9097/"})
        for secret in (tailnet_ip, tailnet_host, "PRIVATE KEY", token):
            self.assertNotIn(secret, question)
        self.assertIn("[redacted host]", question)
        self.assertIn("[redacted private key]", question)
        self.assertIn("[redacted credential]", question)
        self.assertIn("[redacted address]", question)

    def test_merge_is_pinned_to_the_reviewed_head(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        collaborator: dict[str, str] = {}

        def push_behind_the_review(call: dict[str, Any]) -> None:
            if call["name"] == "issue-12 review 1":
                collaborator["sha"] = self.side_push("codefactory/issue-12", "app/collaborator.txt", "Someone else pushed")
                self.github.prs[100]["headRefOid"] = collaborator["sha"]

        self.pi.on_call = push_behind_the_review
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["reviewRound"]), ("active", "release", 2))
        self.assertEqual(issue["headSha"], collaborator["sha"])
        self.assertEqual(len(self.github.merges), 1)
        self.assertEqual(self.github.merges[0]["headSha"], collaborator["sha"], "only the re-verified, re-reviewed head is merged")
        self.assertEqual(self.sessions(12), ["planner", "implementer", "implementer", "reviewer", "reviewer"])
        self.assertTrue(any(message.startswith("The pull request head moved from") for message in self.events(12)))
        self.assertIn("app/collaborator.txt", self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote))

    def test_commit_messages_never_carry_closing_keywords(self):
        plan = good_plan()
        plan["tasks"][0]["title"] = "Fixes #12 crash on launch"
        self.pi.plans = [plan]
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        subjects: list[str] = []

        def capture_branch(call: dict[str, Any]) -> None:
            if call["name"] == "issue-12 review 1":
                subjects.extend(self.git(["log", "--format=%s", "codefactory/issue-12"], cwd=self.remote).splitlines())

        self.pi.on_call = capture_branch
        self.factory.run_issue(12)
        self.assertEqual(subjects[-2], "Issue #12: Refs #12 crash on launch")
        self.assertIn('git commit -m "Issue #12: Refs #12 crash on launch"', self.pi.calls[1]["prompt"])
        self.assertNotIn("Fixes #12", self.git(["log", "--format=%B", "main"], cwd=self.remote))

    def test_attachments_without_an_extension_are_sniffed_as_images(self):
        url = "https://github.com/user-attachments/assets/9f1e2d3c-4b5a-6789-abcd-ef0123456789"
        self.github.download_bytes[url] = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
        self.github.add_issue(12, "Crash when opening the HUD", body=f"Pasted screenshot: {url}\n\n{MARKER}")
        self.factory.poll_once()
        self.factory.run_issue(12)
        attachments = self.settings.runs_root / "issue-12" / "attachments"
        self.assertEqual(sorted(path.name for path in attachments.iterdir()),
                         ["01-shot.png", "02-9f1e2d3c-4b5a-6789-abcd-ef0123456789.png"])
        planner = self.pi.calls[0]
        self.assertEqual(planner["attachments"], [str(attachments / "01-shot.png"),
                                                  str(attachments / "02-9f1e2d3c-4b5a-6789-abcd-ef0123456789.png")])
        self.assertIn("02-9f1e2d3c-4b5a-6789-abcd-ef0123456789.png (image; attached to this session", planner["prompt"])
        self.assertIn("Picked up; 2 attachment(s) downloaded", self.events(12))

    def test_cleanup_action(self):
        issue = self.run_to_block()
        result = self.factory.action(12, "cleanup")
        self.assertTrue(result["issue"]["worktreeCleaned"])
        self.assertEqual(result["issue"]["status"], "blocked")
        self.assertFalse(Path(issue["worktreePath"]).exists())
        self.assertEqual(self.store.stats()["worktreesPending"], 0)
        again = self.factory.action(12, "cleanup")
        self.assertTrue(again["issue"]["worktreeCleaned"], "cleanup is idempotent")

    def test_privacy_check_failure_blocks_then_retry_passes(self):
        finding = {"file": "app/task_t1.py", "line": 1, "category": "personal home path"}
        self.checks.findings_script = [[finding], [finding]]
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "implement", "privacy_check_failed"))
        self.assertEqual(self.sessions(12), ["planner", "implementer", "implementer", "privacy-fix"])
        self.assertIn("- app/task_t1.py:1 — personal home path", self.pi.calls[-1]["prompt"])
        self.assertEqual(len(self.checks.calls), 2)
        self.assertIn("Privacy check reported 1 finding(s); asking for a fix", self.events(12))
        self.factory.action(12, "retry")
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("active", "release"))
        self.assertEqual(self.sessions(12).count("implementer"), 2, "finished tasks are not re-run")
        self.assertIn("app/privacy_fix.txt", self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote))

    def test_no_changes_blocks(self):
        self.pi.implement_noop = True
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["blockedReason"]), ("blocked", "implement", "no_changes"))
        self.assertEqual(self.github.created_prs, [])

    def test_session_error_fails_issue(self):
        self.pi.errors["planner"] = "timeout"
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("failed", "plan"))
        self.assertEqual(issue["error"], "planner session failed: timeout")
        session = self.store.list_sessions(12)[0]
        self.assertEqual(session["exitCode"], 1)
        self.assertEqual(session["summary"], "timeout")
        event = self.store.list_events(12, 1)[0]
        self.assertEqual(event["kind"], "error")
        self.assertEqual(event["detail"], {"code": "pi_failed"})

    def test_invalid_plan_fails_issue(self):
        self.pi.plans = ["I could not decide."]
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual(issue["status"], "failed")
        self.assertIn("no fenced ```json block", issue["error"])

    def test_release_disabled_finishes_after_merge(self):
        self.factory = self.make_factory(release_enabled="false")
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        issue = self.factory.run_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("done", "done"))
        self.assertIsNotNone(issue["finishedAt"])
        self.assertTrue(issue["worktreeCleaned"])
        self.assertTrue(self.github.comments[12][-1].endswith(f"in PR #100."))
        self.assertEqual(self.store.list_releases(), [])


class DiscoveryTests(PipelineTestCase):
    def test_poll_filters_authors_maps_kinds_and_retires_closed_issues(self):
        self.factory = self.make_factory(release_enabled="false")
        self.github.add_issue(1, "Add export", labels=("enhancement", "herdr-autofix"))
        self.github.add_issue(2, "Someone else's issue", author="stranger")
        self.github.add_issue(3, "Unlabeled", labels=("bug",))
        self.github.add_issue(4, "Closed one", state="CLOSED")
        self.github.add_issue(5, "Kind from marker", labels=("herdr-autofix",), body=ISSUE_BODY.replace('"kind":"bug"', '"kind":"feature"'))
        self.store.upsert_issue({"number": 4, "title": "Closed one", "status": "active", "stage": "plan"})
        self.store.upsert_issue({"number": 6, "title": "Merged and waiting", "status": "active", "stage": "release", "mergeSha": "abc"})
        self.github.add_issue(6, "Merged and waiting", state="CLOSED")

        counts = self.factory.poll_once()
        self.assertEqual(counts["discovered"], 3)
        self.assertEqual(counts["eligible"], 2)
        self.assertEqual(counts["new"], 2)
        self.assertEqual(counts["ignored"], 1)
        self.assertEqual(counts["skipped"], 1)
        self.assertEqual(sorted(counts["queued"]), [1, 5])
        self.assertEqual(self.store.get_issue(1)["kind"], "feature")
        self.assertEqual(self.store.get_issue(5)["kind"], "feature", "marker kind applies when no kind label exists")
        self.assertIsNone(self.store.get_issue(2))
        self.assertIsNone(self.store.get_issue(3))
        self.assertEqual(self.store.get_issue(4)["status"], "skipped")
        self.assertEqual(self.github.labels_removed[4], [], "closed issues keep their labels")
        self.assertEqual(self.store.get_issue(6)["status"], "active", "issues merged by us are not retired")
        self.assertIsNotNone(self.store.daemon_info()["lastPollAt"])

    def test_login_is_used_when_no_allow_list(self):
        self.factory = self.make_factory(allowed_authors="")
        self.github.login_value = "the-operator"
        self.github.add_issue(1, "Mine", author="the-operator")
        self.github.add_issue(2, "Not mine", author=AUTHOR)
        counts = self.factory.poll_once()
        self.factory.poll_once()
        self.assertEqual(counts["new"], 1)
        self.assertEqual(counts["ignored"], 1)
        self.assertEqual(sum(1 for call in self.github.calls if call[0] == "login"), 1, "login is cached")

    def test_restart_resumes_active_issue(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        self.assertEqual(self.store.get_issue(12)["stage"], "intake")

        restarted = self.make_factory(release_enabled="false")
        restarted.start()
        try:
            self.assertTrue(restarted.started)
            self.assertTrue(restarted.wait_idle(120))
        finally:
            restarted.stop()
        issue = self.store.get_issue(12)
        self.assertEqual((issue["status"], issue["stage"]), ("done", "done"))
        self.assertTrue(issue["worktreeCleaned"])
        self.assertIsNotNone(self.store.daemon_info()["startedAt"])
        self.assertFalse(restarted.started)
        self.assertIn("started", self.logs)
        self.assertIn("stopped", self.logs)

    def test_two_issues_run_concurrently_while_the_remote_moves(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.add_issue(13, "Another crash")
        self.factory.poll_once()
        self.side_push("main", "docs/elsewhere.md", "Someone merged something else")
        restarted = self.make_factory(release_enabled="false", max_parallel_issues="2")
        restarted.start()
        try:
            self.assertTrue(restarted.wait_idle(120))
        finally:
            restarted.stop(wait=True, timeout=30)
        for number in (12, 13):
            issue = self.store.get_issue(number)
            self.assertEqual((issue["status"], issue["stage"], issue["error"]), ("done", "done", None))
            self.assertTrue(issue["worktreeCleaned"])
            self.assertEqual(self.sessions(number), ["planner", "implementer", "implementer", "reviewer"])
        tree = self.git(["ls-tree", "--name-only", "-r", "main"], cwd=self.remote)
        for name in ("docs/elsewhere.md", "app/task_t1.py"):
            self.assertIn(name, tree)
        self.assertEqual(len(self.remote_subjects()), 4, "two squash merges landed on top of the outside commit")
        self.assertEqual(len(self.repo.list_worktrees()), 1)

    def test_stop_interrupts_a_running_session_and_keeps_the_issue_active(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.factory.poll_once()
        self.pi.block_roles.add("planner")
        restarted = self.make_factory(release_enabled="false")
        restarted.start()
        try:
            self.assertTrue(self.pi.session_started.wait(30), "the planner session is running")
            self.assertTrue(restarted.is_running(12))
            started = time.monotonic()
            restarted.stop(wait=True, timeout=30)
            self.assertLess(time.monotonic() - started, 30, "stop does not wait for the session timeout")
        finally:
            restarted.stop()
        issue = self.store.get_issue(12)
        self.assertEqual((issue["status"], issue["stage"], issue["error"]), ("active", "plan", None), "resumes on the next start")
        session = self.store.list_sessions(12)[0]
        self.assertEqual((session["exitCode"], session["summary"]), (-15, "cancelled"))
        self.assertIsNotNone(session["finishedAt"])
        self.assertTrue(any(line.startswith("stopping: interrupting 1 running issue(s) [12]") for line in self.logs))
        self.assertIn("issue #12: interrupted at plan", self.logs)
        self.pi.block_roles.clear()
        resumed = self.make_factory(release_enabled="false")
        self.assertEqual(resumed.run_issue(12)["status"], "done")

    def test_run_pending_and_run_issue_guards(self):
        self.github.add_issue(12, "Crash when opening the HUD")
        self.github.add_issue(13, "Another crash")
        self.factory.poll_once()
        self.assertEqual(sorted(self.factory.run_pending()), [12, 13])
        self.assertEqual({issue["stage"] for issue in self.store.list_issues()}, {"release"})
        self.assertEqual(self.factory.run_pending(), [], "issues waiting for a release are not re-run")
        with self.assertRaises(CodeFactoryError):
            self.factory.run_issue(0)
        with self.assertRaises(CodeFactoryError) as caught:
            self.factory.run_issue(77)
        self.assertEqual(caught.exception.code, "not_found")


class ReleaseBatchTests(PipelineTestCase):
    def seed_release_issues(self):
        for number, title, kind in ((21, "Crash on launch", "bug"), (22, "Add export", "feature")):
            self.github.add_issue(number, title, labels=("bug" if kind == "bug" else "enhancement", "herdr-autofix"))
            self.store.upsert_issue({
                "number": number, "title": title, "kind": kind, "status": "active", "stage": "release",
                "url": f"https://github.com/{REPOSITORY}/issues/{number}", "prNumber": 100 + number,
                "prUrl": f"https://github.com/{REPOSITORY}/pull/{100 + number}", "mergeSha": "abc123",
                "planJson": good_plan(kind=kind, release_notes_hint=f"Hint for {title}."),
            })

    def test_minor_bump_failure_then_resume(self):
        self.seed_release_issues()
        self.github.verify_script = ["pending", "failure"]
        result = self.factory.run_release_batch()
        self.assertFalse(result["ok"])
        self.assertEqual(result["tag"], "macos-v0.21.0-beta.1", "a feature forces a minor bump")
        self.assertIn("Verify failure", result["error"])
        release = self.store.get_release("macos-v0.21.0-beta.1")
        self.assertEqual(release["status"], "failed")
        self.assertEqual(release["issueNumbers"], [21, 22])
        self.assertIn("Verify failure", release["error"])
        self.assertEqual(self.remote_subjects()[0], "Prepare macOS 0.21.0-beta.1", "the bump commit already landed on main")
        for number in (21, 22):
            issue = self.store.get_issue(number)
            self.assertEqual((issue["status"], issue["stage"]), ("active", "release"))
            self.assertIn("Release failed: Verify failure on main commit", self.events(number)[-1])
        self.assertEqual(len(self.repo.list_worktrees()), 1, "the release worktree is removed on failure too")
        self.assertEqual(self.releases.calls, [])
        author = self.pi.calls[-1]
        self.assertIn("--part minor --channel preview", author["prompt"].replace("'", ""))
        self.assertIn("- #22 Add export (feature)", author["prompt"])
        self.assertIn("Hint for Add export.", author["prompt"])
        self.assertEqual(author["name"].split()[0], "release")

        self.clock.now += 60
        result = self.factory.action(None, "release_now")
        self.assertTrue(result["releaseStarted"])
        release = self.store.get_release("macos-v0.21.0-beta.1")
        self.assertEqual(release["status"], "published")
        self.assertIsNone(release["error"])
        self.assertEqual(self.sessions(None), ["release-author"], "the resumed batch does not bump again")
        self.assertEqual(self.remote_subjects()[0], "Prepare macOS 0.21.0-beta.1")
        self.assertEqual(json.loads(self.git(["show", "main:release/macos.json"], cwd=self.remote))["version"], "0.21.0")
        for number in (21, 22):
            issue = self.store.get_issue(number)
            self.assertEqual((issue["status"], issue["stage"], issue["releaseVersion"]), ("done", "done", "0.21.0-beta.1"))
            self.assertIn(number, self.github.closed)
            self.assertEqual(self.github.labels_added[number], ["released"])
            self.assertTrue(self.github.comments[number][-1].startswith("🚀 Released in macos-v0.21.0-beta.1"))
        self.assertIn("Resuming release macos-v0.21.0-beta.1", " ".join(self.events(21)))
        self.assertEqual(len(self.releases.calls), 2)
        self.assertEqual(self.store.stats(), {"active": 0, "blocked": 0, "failed": 0, "done": 2, "skipped": 0, "released": 2, "worktreesPending": 0})
        self.assertEqual(len(self.repo.list_worktrees()), 1)

    def test_release_validation_rejects_uncommitted_worktree(self):
        self.seed_release_issues()
        self.pi.release_mode = "dirty"
        result = self.factory.run_release_batch()
        self.assertFalse(result["ok"])
        self.assertIn("uncommitted changes", result["error"])
        self.assertEqual(self.store.get_release("macos-v0.21.0-beta.1")["status"], "failed")
        self.assertEqual(self.remote_subjects()[0], "Initial", "nothing was pushed")
        self.assertEqual(self.store.get_issue(21)["stage"], "release")
        self.assertEqual(len(self.repo.list_worktrees()), 1)

    def test_release_script_failure_then_resume(self):
        self.seed_release_issues()
        self.releases.fail_step = "publish"
        result = self.factory.run_release_batch()
        self.assertFalse(result["ok"])
        self.assertIn("release publish failed: Keychain locked", result["error"])
        release = self.store.get_release("macos-v0.21.0-beta.1")
        self.assertEqual(release["status"], "failed")
        self.assertEqual(self.github.closed, [])
        self.assertEqual(self.store.get_issue(22)["status"], "active")
        self.assertEqual(release["outputDir"], str(self.settings.release_output_root / "0.21.0-beta.1"),
                         "the prepared output is recorded before publish runs")
        self.clock.now += 60
        self.releases.fail_step = None
        result = self.factory.run_release_batch()
        self.assertTrue(result["ok"])
        self.assertEqual(result["tag"], "macos-v0.21.0-beta.1")
        self.assertEqual([argv[2] for argv, _ in self.releases.calls], ["prepare", "publish", "publish"],
                         "the resume reuses the prepared manifest instead of rebuilding")
        self.assertEqual(self.releases.calls[1][0][3], self.releases.calls[2][0][3])
        self.assertEqual(self.sessions(None), ["release-author"])
        self.assertEqual(self.store.get_release("macos-v0.21.0-beta.1")["status"], "published")

    def test_failed_batch_backs_off_instead_of_retrying_every_poll(self):
        self.seed_release_issues()
        self.pi.release_mode = "dirty"
        self.assertFalse(self.factory.run_release_batch()["ok"])
        self.assertEqual(len(self.sessions(None)), 1)
        counts = self.factory.poll_once()
        self.assertEqual((counts["releaseStarted"], counts["releaseDeferred"]), (False, True))
        self.assertEqual(len(self.sessions(None)), 1, "no new release-author session while backing off")
        self.assertTrue(any(line.startswith("release retry deferred after 1 failed batch(es)") for line in self.logs))
        self.clock.now += 600
        counts = self.factory.poll_once()
        self.assertEqual((counts["releaseStarted"], counts["releaseDeferred"]), (True, False))
        self.assertEqual(len(self.sessions(None)), 2)
        self.clock.now += 600
        self.assertTrue(self.factory.poll_once()["releaseDeferred"], "the window doubles after the second failure")
        self.assertEqual(len(self.sessions(None)), 2)
        self.clock.now += 600
        self.assertTrue(self.factory.poll_once()["releaseStarted"])
        self.assertEqual(len(self.sessions(None)), 3)
        self.assertTrue(self.factory.action(None, "release_now")["releaseStarted"], "an explicit action ignores the backoff")
        self.assertEqual(len(self.sessions(None)), 4)
        self.pi.release_mode = "commit"
        self.clock.now += 6 * 3600
        self.assertTrue(self.factory.poll_once()["releaseStarted"])
        self.assertEqual(self.store.get_release("macos-v0.21.0-beta.1")["status"], "published")
        self.assertEqual(self.store.get_issue(21)["status"], "done")

    def test_resumed_release_ships_the_recorded_source_without_late_issues(self):
        self.seed_release_issues()
        self.github.verify_script = ["pending", "failure"]
        self.assertFalse(self.factory.run_release_batch()["ok"])
        release = self.store.get_release("macos-v0.21.0-beta.1")
        source = release["sourceSha"]
        self.assertEqual(source, self.git(["rev-parse", "main"], cwd=self.remote))
        fix = self.side_push("main", "app/fix23.txt", "Fix for the late issue")
        self.github.add_issue(23, "Late crash")
        self.store.upsert_issue({"number": 23, "title": "Late crash", "kind": "bug", "status": "active", "stage": "release",
                                 "mergeSha": fix, "planJson": good_plan()})
        self.clock.now += 60
        result = self.factory.run_release_batch()
        self.assertTrue(result["ok"])
        self.assertEqual(result["issues"], [21, 22], "issues merged after the bump commit wait for the next batch")
        release = self.store.get_release("macos-v0.21.0-beta.1")
        self.assertEqual((release["status"], release["sourceSha"], release["issueNumbers"]), ("published", source, [21, 22]))
        self.assertEqual(self.releases.prepared_heads, [source], "the build is made from the recorded source, not the moved tip")
        self.assertEqual(self.sessions(None), ["release-author"], "no second author session for a resume")
        late = self.store.get_issue(23)
        self.assertEqual((late["status"], late["stage"], late["releaseTag"]), ("active", "release", None))
        self.assertNotIn(23, self.github.closed)
        self.assertIn("Waiting for the next batch: release macos-v0.21.0-beta.1 is being resumed and its notes do not cover this issue",
                      self.events(23))
        self.assertTrue(any(message.startswith(f"Resuming release macos-v0.21.0-beta.1 at {source[:12]}") for message in self.events(21)))
        self.clock.now += 60
        result = self.factory.run_release_batch()
        self.assertEqual((result["ok"], result["tag"], result["issues"]), (True, "macos-v0.21.1-beta.1", [23]))
        self.assertEqual(self.sessions(None), ["release-author", "release-author"])
        self.assertEqual(self.store.get_issue(23)["releaseVersion"], "0.21.1-beta.1")
        self.assertIn("- #23 Late crash (bug)", self.pi.calls[-1]["prompt"])
        self.assertEqual(len(self.repo.list_worktrees()), 1)

    def test_release_commit_touching_other_files_is_rejected(self):
        self.seed_release_issues()
        self.pi.release_mode = "extra"
        result = self.factory.run_release_batch()
        self.assertFalse(result["ok"])
        self.assertIn("the release commit must change exactly release/macos.json and release/notes/macos-0.21.0-beta.1.md; "
                      "unexpected: scripts/release-macos.py", result["error"])
        self.assertEqual(self.remote_subjects()[0], "Initial", "nothing was pushed")
        self.assertEqual(self.releases.calls, [])
        self.assertEqual(self.store.get_release("macos-v0.21.0-beta.1")["status"], "failed")
        self.pi.release_mode = "subject"
        self.clock.now += 6 * 3600
        result = self.factory.run_release_batch()
        self.assertFalse(result["ok"])
        self.assertIn("the release commit subject must be 'Prepare macOS 0.21.0-beta.1', found 'Release 0.21.0-beta.1 (Closes #21)'",
                      result["error"])
        self.assertEqual(self.remote_subjects()[0], "Initial")
        self.assertEqual(len(self.repo.list_worktrees()), 1)

    def test_nothing_to_release_and_busy(self):
        self.assertEqual(self.factory.run_release_batch(), {"ok": True, "reason": "nothing_to_release", "issues": []})
        self.assertTrue(self.factory.action(None, "release_now")["releaseStarted"])
        self.assertEqual(self.store.list_releases(), [])
        self.factory = self.make_factory(release_enabled="false")
        self.seed_release_issues()
        self.assertEqual(self.factory.run_release_batch()["reason"], "release_disabled")
        self.factory._release_lock.acquire()
        try:
            self.assertEqual(self.factory.run_release_batch()["reason"], "busy")
            self.assertFalse(self.factory.action(None, "release_now")["releaseStarted"])
        finally:
            self.factory._release_lock.release()

    def test_load_release_script_falls_back_to_package_copy(self):
        module = load_release_script(self.root / "nowhere")
        self.assertEqual(module.release_tag({"version": "1.2.3", "build": 9, "channel": "preview", "preview": 2}), "macos-v1.2.3-beta.2")
        self.assertEqual(module.next_version({"version": "0.20.0", "build": 46, "channel": "preview", "preview": 1}, "patch", "preview"),
                         {"version": "0.20.1", "build": 47, "channel": "preview", "preview": 1})


if __name__ == "__main__":
    unittest.main()
