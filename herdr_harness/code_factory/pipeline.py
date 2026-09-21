"""The Code Factory orchestrator: issue discovery, the per-issue stage machine and releases.

``CodeFactory`` owns a background poller thread and a bounded worker pool. Every stage
is idempotent and re-reads the ledger before acting, so a crashed or restarted daemon
resumes from the recorded stage; every transition, warning and failure is written to
the ledger as an event. All collaborators (GitHub, git, Pi, the clock, ``sleep``, the
release script runner and the privacy-check runner) are injected so the whole journey
can be exercised offline with fakes and a temporary git repository.

Status writes that end a stage (advance, fail, block) are compare-and-set against the
ledger under the factory lock, so an operator action that skips an issue while a stage
is running always wins; the worker notices at its next checkpoint, the running Pi
session is cancelled, and the worktree is removed once the worker has unwound.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, Mapping, Sequence

from .. import issue_reports
from ..agent_runs import ATTACHMENT_EXTENSIONS
from . import prompts
from .errors import CodeFactoryError
from .git import GitRepository
from .github import GitHubClient
from .pi import PiResult, PiRunner
from .settings import CodeFactorySettings
from .store import STAGE_LABELS, STAGE_ORDER, CodeFactoryStore, utc_now

BRANCH_PREFIX = "codefactory/issue-"
RELEASED_LABEL = "released"
VERIFY_POLL_SECONDS = 30
RELEASE_TIMEOUT_SECONDS = 3 * 3600
KILL_GRACE_SECONDS = 10.0
PRIVACY_CHECK_TIMEOUT_SECONDS = 600
MAX_ATTACHMENT_DOWNLOADS = 12
MAX_ATTACHMENT_NAME_CHARS = 120
MAX_ERROR_CHARS = 2000
MAX_SESSION_SUMMARY_CHARS = 2000
MAX_NOTES_BYTES = 128 * 1024
TERMINAL_STAGES = frozenset({"release", "done"})
ACTIONS = ("retry", "skip", "cleanup", "release_now")
RELEASE_RESUMABLE = frozenset({"failed", "verifying", "publishing"})
RELEASE_RETRY_MIN_SECONDS = 600
RELEASE_RETRY_MAX_SECONDS = 6 * 3600
VERIFY_POLL_MAX_ERRORS = 5
PRIVACY_CHECK_SCRIPT = "scripts/check-public-source.py"
RELEASE_VERSION_FILE = "release/macos.json"
MAX_CHECK_OUTPUT_CHARS = 1024 * 1024
MAX_FINDINGS = 50
MESSAGE_ME_TIMEOUT_SECONDS = 30
MESSAGE_ME_SCRIPT = Path.home() / ".codex" / "skills" / "message-me" / "scripts" / "message_me.py"

_ATTACHMENT_URL_RE = re.compile(
    r"https://github\.com/(?:user-attachments/[^\s)\]\"'<>]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[^\s)\]\"'<>]+)"
)
_SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")

Runner = Callable[..., Any]
Logger = Callable[[str], None]


def _default_log(message: str) -> None:
    print(f"[code-factory] {message}", file=sys.stderr, flush=True)


def _error_text(exc: BaseException) -> str:
    text = str(exc).strip() or type(exc).__name__
    return text[:MAX_ERROR_CHARS]


def _safe_attachment_name(name: Any, index: int) -> str:
    """A filesystem-safe attachment name (no separators, bounded, indexed to avoid clashes)."""
    text = name if isinstance(name, str) else ""
    text = _SAFE_NAME_RE.sub("_", text.strip().replace("\\", "/").rsplit("/", 1)[-1]).strip("._")
    if not text:
        text = f"attachment-{index}"
    return f"{index:02d}-{text[:MAX_ATTACHMENT_NAME_CHARS]}"


def _extension(name: str) -> str:
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def _kind_from(labels: Sequence[str], marker: Mapping[str, Any] | None) -> str:
    names = {str(label).lower() for label in labels}
    if "bug" in names:
        return "bug"
    if "enhancement" in names:
        return "feature"
    if isinstance(marker, Mapping) and marker.get("kind") in ("bug", "feature"):
        return str(marker["kind"])
    return "bug"


def _label_names(issue: Mapping[str, Any]) -> list[str]:
    labels = issue.get("labels")
    names: list[str] = []
    for item in labels if isinstance(labels, list) else []:
        name = item.get("name") if isinstance(item, Mapping) else item
        if isinstance(name, str) and name.strip():
            names.append(name.strip()[:100])
    return names[:100]


def _author_login(issue: Mapping[str, Any]) -> str:
    author = issue.get("author")
    if isinstance(author, Mapping):
        login = author.get("login")
    else:
        login = author
    return login.strip() if isinstance(login, str) else ""


class _ReadOnlySourceLoader(importlib.machinery.SourceFileLoader):
    """A source loader that never writes a bytecode cache.

    The release script is loaded from the release worktree; a ``__pycache__`` written
    there would be swept into the release author's ``git add -A`` and fail (or worse,
    pollute) the release commit.
    """

    def set_data(self, path: str, data: bytes, *, _mode: int = 0o666) -> None:
        return None


def load_release_script(worktree: Path) -> ModuleType:
    """Load ``scripts/release-macos.py`` as a module (from the worktree, else this package's repository)."""
    candidates = [worktree / "scripts" / "release-macos.py", Path(__file__).resolve().parents[2] / "scripts" / "release-macos.py"]
    for candidate in candidates:
        if candidate.is_file():
            loader = _ReadOnlySourceLoader("herdr_release_macos", str(candidate))
            spec = importlib.util.spec_from_file_location("herdr_release_macos", candidate, loader=loader)
            if spec is None or spec.loader is None:
                continue
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise CodeFactoryError("scripts/release-macos.py was not found in the release worktree", code="release_failed")


@dataclass(frozen=True)
class RunPaths:
    """The per-issue (or per-release) run directory layout under ``runs_root``."""

    root: Path

    @property
    def issue_json(self) -> Path:
        return self.root / "issue.json"

    @property
    def attachments(self) -> Path:
        return self.root / "attachments"

    @property
    def plan_json(self) -> Path:
        return self.root / "plan.json"

    @property
    def plan_md(self) -> Path:
        return self.root / "plan.md"

    @property
    def sessions(self) -> Path:
        return self.root / "sessions"

    @property
    def logs(self) -> Path:
        return self.root / "logs"

    def ensure(self) -> "RunPaths":
        for directory in (self.root, self.attachments, self.sessions, self.logs):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        return self


class _Interrupted(Exception):
    """Raised inside a stage when the daemon is stopping or the issue was skipped; its status is left alone."""

    def __init__(self, message: str = "interrupted: the daemon is stopping"):
        super().__init__(message)


class CodeFactory:
    """Discover labeled issues and drive each one from intake to a released version.

    Release batches normally finish before shutdown. A caller that gives ``stop()`` a
    timeout may interrupt its release command after that wait expires.
    """

    def __init__(
        self,
        settings: CodeFactorySettings,
        store: CodeFactoryStore,
        *,
        github: GitHubClient | Any,
        git: GitRepository | Any,
        pi: PiRunner | Any,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        release_runner: Runner | None = None,
        log: Logger | None = None,
        check_runner: Runner | None = None,
        message_runner: Runner | None = None,
    ):
        self._settings = settings
        self._store = store
        self._github = github
        self._git = git
        self._pi = pi
        self._clock = clock
        self._sleep = sleep
        self._check_runner: Runner = check_runner or subprocess.run
        self._message_runner: Runner = message_runner or subprocess.run
        self._log: Logger = log or _default_log
        self._lock = threading.RLock()
        self._active: set[int] = set()
        self._futures: dict[int, Future[Any]] = {}
        self._executor: ThreadPoolExecutor | None = None
        self._poller: threading.Thread | None = None
        self._release_thread: threading.Thread | None = None
        self._release_lock = threading.Lock()
        self._release_process_lock = threading.Lock()
        self._release_process: Any | None = None
        self._release_runner: Runner = release_runner or self._default_release_runner
        self._stop_event = threading.Event()
        self._cancelled: set[int] = set()
        self._release_failures = 0
        self._release_failed_at: float | None = None
        self._release_deferred_logged = False
        self._login: str | None = None
        self._handlers: dict[str, Callable[[dict[str, Any]], str | None]] = {
            "intake": self._stage_intake,
            "worktree": self._stage_worktree,
            "plan": self._stage_plan,
            "implement": self._stage_implement,
            "pull_request": self._stage_pull_request,
            "verify": self._stage_verify,
            "review": self._stage_review,
            "revise": self._stage_revise,
            "merge": self._stage_merge,
        }

    # -- lifecycle ------------------------------------------------------------------

    @property
    def settings(self) -> CodeFactorySettings:
        return self._settings

    @property
    def started(self) -> bool:
        return self._executor is not None

    def start(self) -> None:
        """Start the worker pool and poller; re-submit every active, non-terminal issue."""
        with self._lock:
            if self._executor is not None:
                return
            self._stop_event.clear()
            self._executor = ThreadPoolExecutor(
                max_workers=self._settings.max_parallel_issues, thread_name_prefix="code-factory",
            )
        self._store.set_daemon("started_at", utc_now())
        for issue in self._store.list_issues("active"):
            if issue["stage"] not in TERMINAL_STAGES:
                self._submit(issue["number"])
        self._poller = threading.Thread(target=self._poll_loop, name="code-factory-poller", daemon=True)
        self._poller.start()
        self._log("started")

    def stop(self, *, wait: bool = False, timeout: float | None = None) -> None:
        """Stop polling and interrupt running stages.

        In-flight Pi sessions are cancelled (their process group is terminated) and the
        issues stay ``active`` at their current stage, so the next ``start()`` resumes
        them. A release batch is joined because a half-finished publish is worse than
        a slow shutdown, unless a caller explicitly gives a stop timeout and it
        elapses; then its current release command is terminated as a process group.
        """
        self._stop_event.set()
        with self._lock:
            running = sorted(self._active)
        if running:
            self._log(f"stopping: interrupting {len(running)} running issue(s) {running}; they resume on the next start")
        poller = self._poller
        if poller is not None and poller is not threading.current_thread():
            poller.join(timeout=5)
        self._poller = None
        if wait:
            self.wait_idle(timeout)
        with self._lock:
            executor = self._executor
            self._executor = None
            release_thread = self._release_thread
        if executor is not None:
            executor.shutdown(wait=wait, cancel_futures=True)
        if release_thread is not None and release_thread.is_alive() and release_thread is not threading.current_thread():
            self._log("waiting for the release batch to finish; a bounded stop may interrupt its command")
            release_thread.join(timeout)
            if timeout is not None and release_thread.is_alive():
                self._terminate_tracked_release_process("stop timeout elapsed")
        self._log("stopped")

    def wait_idle(self, timeout: float | None = None) -> bool:
        """Block until no issue or release is in flight; returns False on timeout."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            with self._lock:
                futures = list(self._futures.values())
                release_thread = self._release_thread
                busy = bool(self._active) or self._release_lock.locked() or (
                    release_thread is not None and release_thread.is_alive()
                )
            if not busy:
                return True
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                return False
            for future in futures:
                try:
                    future.result(timeout=remaining)
                except Exception:
                    pass
            if release_thread is not None and release_thread.is_alive():
                release_thread.join(timeout=remaining)
            time.sleep(0.01)

    def is_running(self, number: int) -> bool:
        with self._lock:
            return number in self._active

    def _poll_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.poll_once()
            except Exception as exc:  # pragma: no cover - defensive; poll errors must not kill the loop
                self._log(f"poll failed: {_error_text(exc)}")
            self._stop_event.wait(self._settings.poll_seconds)

    def _submit(self, number: int) -> bool:
        with self._lock:
            executor = self._executor
            if executor is None or number in self._active:
                return False
            self._active.add(number)
            future = executor.submit(self._run_submitted, number)
            self._futures[number] = future
            return True

    def _run_submitted(self, number: int) -> None:
        try:
            self._process(number)
        except Exception as exc:  # pragma: no cover - _process records its own failures
            self._log(f"issue #{number}: unexpected failure: {_error_text(exc)}")
        finally:
            self._finish_run(number)

    def _finish_run(self, number: int) -> None:
        """Release the issue's worker slot; finish a skip that was requested while it ran."""
        with self._lock:
            self._active.discard(number)
            self._futures.pop(number, None)
            cancelled = number in self._cancelled
            self._cancelled.discard(number)
        if not cancelled:
            return
        issue = self._store.get_issue(number)
        if issue is not None and issue["status"] == "skipped" and not issue.get("worktreeCleaned"):
            self._cleanup_worktree(issue, issue["stage"])

    def _cancel_requested(self, number: int | None) -> bool:
        """True once the daemon is stopping or the operator skipped ``number`` mid-run."""
        if self._stop_event.is_set():
            return True
        if number is None:
            return False
        with self._lock:
            return number in self._cancelled

    # -- discovery ------------------------------------------------------------------

    def allowed_authors(self) -> tuple[str, ...]:
        """The configured allow-list, or the authenticated ``gh`` login (cached)."""
        if self._settings.allowed_authors:
            return self._settings.allowed_authors
        if self._login is None:
            self._login = self._github.login()
        return (self._login,)

    def poll_once(self) -> dict[str, Any]:
        """Discover labeled issues, queue new/resumable ones, retire closed ones, kick releases."""
        counts: dict[str, Any] = {
            "discovered": 0, "eligible": 0, "new": 0, "resumed": 0, "ignored": 0, "skipped": 0,
            "queued": [], "releaseStarted": False, "releaseDeferred": False,
        }
        listed = self._github.list_issues(self._settings.trigger_label)
        counts["discovered"] = len(listed)
        allowed = {login.lower() for login in self.allowed_authors()}
        open_numbers: set[int] = set()
        for item in listed:
            number = item.get("number")
            if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
                continue
            open_numbers.add(number)
            if _author_login(item).lower() not in allowed:
                counts["ignored"] += 1
                continue
            counts["eligible"] += 1
            existing = self._store.get_issue(number)
            if existing is None:
                labels = _label_names(item)
                marker = issue_reports.parse_report_marker(item.get("body"))
                self._store.upsert_issue({
                    "number": number,
                    "title": prompts.single_line(item.get("title"))[:500] or f"Issue #{number}",
                    "kind": _kind_from(labels, marker),
                    "author": _author_login(item)[:100],
                    "url": str(item.get("url") or "")[:500],
                    "labels": labels,
                    "status": "active",
                    "stage": "intake",
                })
                self._store.add_event(number, "intake", "info", "Discovered with the trigger label")
                counts["new"] += 1
                if self._submit(number) or not self.started:
                    counts["queued"].append(number)
            elif existing["status"] == "active" and existing["stage"] not in TERMINAL_STAGES and not self.is_running(number):
                if self._submit(number) or not self.started:
                    counts["resumed"] += 1
                    counts["queued"].append(number)
        for issue in self._store.list_issues("active"):
            number = issue["number"]
            if number in open_numbers or issue["stage"] in TERMINAL_STAGES or self.is_running(number):
                continue
            try:
                remote = self._github.get_issue(number)
            except CodeFactoryError as exc:
                self._log(f"issue #{number}: state check failed: {_error_text(exc)}")
                continue
            if str(remote.get("state") or "").upper() == "CLOSED" and not issue.get("mergeSha"):
                self._store.add_event(number, issue["stage"], "warning", "Issue was closed on GitHub; skipping")
                self._skip_issue(issue, remove_label=False)
                counts["skipped"] += 1
        if any(issue["stage"] == "release" for issue in self._store.list_issues("active")):
            if self._release_retry_due():
                counts["releaseStarted"] = self._start_release()
            else:
                counts["releaseDeferred"] = True
                if not self._release_deferred_logged:
                    self._release_deferred_logged = True
                    self._log(f"release retry deferred after {self._release_failures} failed batch(es); "
                              "use the release_now action to retry immediately")
        self._store.set_daemon("last_poll_at", utc_now())
        return counts

    def _release_retry_due(self) -> bool:
        """False while the last failed batch is inside its exponential backoff window.

        Only the poller honours this; the ``release_now`` and ``retry`` actions are explicit
        and always start a batch. Without it a failing publish (locked Keychain, notarization
        outage) re-ran a release-author session and a full build on every poll.
        """
        if self._release_failed_at is None:
            return True
        delay = min(RELEASE_RETRY_MIN_SECONDS * (2 ** max(0, self._release_failures - 1)), RELEASE_RETRY_MAX_SECONDS)
        return self._clock() - self._release_failed_at >= delay

    def run_pending(self) -> list[int]:
        """Synchronously process every active, non-terminal issue (``once`` semantics)."""
        processed: list[int] = []
        for issue in self._store.list_issues("active"):
            if issue["stage"] in TERMINAL_STAGES or self.is_running(issue["number"]):
                continue
            self.run_issue(issue["number"])
            processed.append(issue["number"])
        return processed

    # -- per-issue driver -----------------------------------------------------------

    def run_issue(self, number: int) -> dict[str, Any] | None:
        """Run stages for one issue until it is terminal, blocked, failed or waiting; returns the issue."""
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise CodeFactoryError("issue number must be a positive integer", code="invalid_request")
        with self._lock:
            if number in self._active:
                return self._store.get_issue(number)
            self._active.add(number)
        try:
            self._process(number)
        finally:
            self._finish_run(number)
        return self._store.get_issue(number)

    def _process(self, number: int) -> None:
        issue = self._store.get_issue(number)
        if issue is None:
            raise CodeFactoryError(f"issue #{number} is not tracked", code="not_found")
        if issue["status"] != "active" or issue["stage"] in TERMINAL_STAGES:
            return
        self._store.update_issue(
            number, attempts=int(issue["attempts"] or 0) + 1, claimedAt=issue["claimedAt"] or utc_now(),
        )
        while True:
            issue = self._store.get_issue(number)
            if issue is None or issue["status"] != "active" or issue["stage"] in TERMINAL_STAGES:
                return
            if self._stop_event.is_set():
                self._log(f"issue #{number}: paused at {issue['stage']} (stopping)")
                return
            stage = issue["stage"]
            handler = self._handlers.get(stage)
            if handler is None:
                self._fail(number, stage, CodeFactoryError(f"unknown stage {stage!r}", code="invalid_request"))
                return
            try:
                next_stage = handler(issue)
            except _Interrupted:
                self._log(f"issue #{number}: interrupted at {stage}")
                return
            except Exception as exc:
                self._fail(number, stage, exc)
                return
            if next_stage is None:
                return
            self._advance(number, stage, next_stage)

    def _advance(self, number: int, stage: str, next_stage: str) -> None:
        if next_stage not in STAGE_ORDER:
            raise CodeFactoryError(f"invalid next stage {next_stage!r}", code="invalid_request")
        fields: dict[str, Any] = {"stage": next_stage}
        if next_stage == "done":
            fields.update(status="done", finishedAt=utc_now())
        with self._lock:
            if not self._still_active(number, stage, f"transition to {next_stage}"):
                return
            self._store.update_issue(number, **fields)
        if next_stage == "done":
            self._store.add_event(number, "done", "success", "Done")
        elif next_stage == "release":
            self._store.add_event(number, "release", "info", "Queued for the next release batch")
        else:
            self._store.add_event(number, stage, "info", f"Next: {STAGE_LABELS.get(next_stage, next_stage)}")
        self._log(f"issue #{number}: {stage} → {next_stage}")

    def _still_active(self, number: int, stage: str, outcome: str) -> bool:
        """Guard for stage outcomes (call under ``_lock``): dropped once the issue is no longer active."""
        issue = self._store.get_issue(number)
        if issue is not None and issue["status"] == "active":
            return True
        status = issue["status"] if issue is not None else "untracked"
        self._log(f"issue #{number}: dropped {outcome} at {stage}; the issue is {status}")
        if issue is not None:
            self._store.add_event(number, stage, "info",
                                  f"Ignored {outcome} at {STAGE_LABELS.get(stage, stage)}: the issue was marked {status} meanwhile")
        return False

    def _fail(self, number: int, stage: str, exc: BaseException) -> None:
        message = _error_text(exc)
        code = getattr(exc, "code", None) if isinstance(exc, CodeFactoryError) else type(exc).__name__
        with self._lock:
            if not self._still_active(number, stage, f"failure ({message[:120]})"):
                return
            self._store.update_issue(number, status="failed", error=message)
        self._store.add_event(number, stage, "error", f"Failed: {message}", {"code": code})
        self._log(f"issue #{number}: failed at {stage}: {message}")

    def _block(self, number: int, stage: str, reason: str, message: str) -> None:
        with self._lock:
            if not self._still_active(number, stage, f"block ({reason})"):
                return
            self._store.update_issue(number, status="blocked", blockedReason=reason, error=None)
        self._store.add_event(number, stage, "warning", f"Blocked ({reason}): {message}"[:20_000], {"reason": reason})
        self._log(f"issue #{number}: blocked at {stage}: {reason}")
        if reason == "human_question":
            self._notify_human_question(number, stage, message)

    # -- helpers shared by stages ---------------------------------------------------

    def _paths(self, number: int) -> RunPaths:
        return RunPaths(self._settings.runs_root / f"issue-{number}").ensure()

    def _release_paths(self, label: str) -> RunPaths:
        return RunPaths(self._settings.runs_root / f"release-{label}").ensure()

    def _worktree_path(self, number: int) -> Path:
        return self._settings.worktree_root / f"issue-{number}"

    def _branch(self, number: int) -> str:
        return f"{BRANCH_PREFIX}{number}"

    def _base_ref(self) -> str:
        return f"origin/{self._settings.base_branch}"

    def _dashboard_url(self) -> str:
        if self._settings.dashboard_link:
            return self._settings.dashboard_link
        daemon = self._store.daemon_info()
        for key in ("dashboardUrl", "dashboardBindUrl"):
            value = daemon.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        return ""

    def _notify_human_question(self, number: int, stage: str, question: str) -> None:
        """Send a best-effort Message Me alert without changing the blocked outcome."""
        issue = self._store.get_issue(number) or {}
        title = self._public(str(issue.get("title") or "Untitled feature"))
        safe_question = self._public(question)
        body = (
            f"Feature #{number}, {title}, is blocked waiting for your response. "
            f"Question: {safe_question} Reply on the GitHub issue, then choose Retry in the Code Factory Dashboard."
        )
        argv = [
            self._settings.python,
            str(MESSAGE_ME_SCRIPT),
            "--title", "Code Factory needs your response",
            "--sender", "Herdr · Code Factory",
            "--urgency", "active",
        ]
        dashboard_url = self._dashboard_url()
        if dashboard_url:
            argv.extend(("--link", dashboard_url))
        argv.append(body)
        try:
            result = self._message_runner(
                argv, capture_output=True, text=True, timeout=MESSAGE_ME_TIMEOUT_SECONDS, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            detail = f"Message Me notification failed: {_error_text(exc)}"
            self._store.add_event(number, stage, "warning", detail)
            self._log(f"issue #{number}: {detail}")
            return
        returncode = int(getattr(result, "returncode", 1))
        if returncode == 0:
            self._store.add_event(number, stage, "info", "Message Me notification sent")
            return
        if returncode == 2:
            detail = "Message Me stored the alert, but iPhone delivery was not confirmed"
        else:
            detail = f"Message Me notification failed with exit status {returncode}"
        self._store.add_event(number, stage, "warning", detail)
        self._log(f"issue #{number}: {detail}")

    def _public(self, text: str) -> str:
        """Every GitHub-bound text passes here: local paths, tailnet names/addresses, keys and tokens are redacted."""
        roots = [self._settings.worktree_root, self._settings.runs_root, self._settings.checkout, Path.home()]
        return prompts.scrub_public_text(text, [str(root) for root in roots if str(root) not in ("", ".")])

    def _comment(self, number: int, stage: str, text: str) -> None:
        if not self._settings.comment_on_issues:
            return
        try:
            self._github.comment_issue(number, self._public(text))
        except CodeFactoryError as exc:
            self._store.add_event(number, stage, "warning", f"Could not comment on the issue: {_error_text(exc)}")

    def _issue_view(self, issue: Mapping[str, Any], paths: RunPaths, *, refresh: bool = False) -> dict[str, Any]:
        """The issue as prompt builders expect it (title, verbatim body, url, kind, labels)."""
        body = ""
        data: dict[str, Any] = {}
        if not refresh:
            try:
                data = json.loads(paths.issue_json.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                data = {}
        if not isinstance(data, dict) or not isinstance(data.get("body"), str):
            data = self._github.get_issue(issue["number"])
            self._write_json(paths.issue_json, data)
        body = data.get("body") if isinstance(data.get("body"), str) else ""
        allowed = {login.lower() for login in self.allowed_authors()}
        comments = [
            item for item in (data.get("comments") if isinstance(data.get("comments"), list) else [])
            if isinstance(item, Mapping) and _author_login(item).lower() in allowed
        ]
        return {
            "number": issue["number"], "title": issue["title"], "body": body, "url": issue["url"],
            "kind": issue["kind"], "author": issue["author"], "labels": issue.get("labels") or [],
            "comments": comments,
        }

    @staticmethod
    def _write_json(path: Path, value: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")

    def _save_plan(self, issue: Mapping[str, Any], plan: dict[str, Any], paths: RunPaths) -> None:
        self._store.update_issue(issue["number"], planJson=plan)
        self._write_json(paths.plan_json, plan)
        paths.plan_md.write_text(prompts.plan_markdown(plan, issue), encoding="utf-8")

    def _plan_for(self, issue: Mapping[str, Any]) -> dict[str, Any]:
        plan = issue.get("planJson")
        if not isinstance(plan, dict) or not isinstance(plan.get("tasks"), list):
            raise CodeFactoryError("the plan is missing; retry from the plan stage", code="invalid_request")
        return dict(plan)

    def _ready_plan(
        self, issue: Mapping[str, Any], paths: RunPaths, stage: str,
    ) -> dict[str, Any] | None:
        """Return a fully validated implementation-ready plan, or route stale data to replanning."""
        raw = issue.get("planJson")
        try:
            plan = self._plan_for(issue)
            normalized = prompts.validate_plan(plan)
            if normalized["needs_human"]:
                raise CodeFactoryError("the stored plan still needs human input", code="model_output_invalid")
        except CodeFactoryError as exc:
            if isinstance(raw, dict):
                stale = dict(raw)
                stale.pop("progress", None)
                self._save_plan(issue, stale, paths)
            self._store.add_event(
                issue["number"], stage, "warning",
                f"The stored plan is not implementation-ready ({_error_text(exc)}); returning to planning",
            )
            return None
        ready = dict(plan)
        ready.update(normalized)
        return ready

    def _session(
        self,
        *,
        issue_number: int | None,
        role: str,
        model: str,
        thinking: str,
        prompt: str,
        cwd: Path,
        name: str,
        charter: str,
        tools: str,
        paths: RunPaths,
        attachments: Sequence[str] = (),
    ) -> PiResult:
        """Run one Pi session, record it in the ledger, and raise ``pi_failed`` on an error."""
        session_id = uuid.uuid4().hex
        log_path = paths.logs / f"{role}-{session_id}.jsonl"
        self._store.add_session(session_id, issue_number, role, model, thinking, log_path=str(log_path))
        if issue_number is not None:
            self._store.add_event(issue_number, self._store.get_issue(issue_number)["stage"], "info",
                                  f"{role} session started ({model}, thinking {thinking})", {"sessionId": session_id})
        result: PiResult
        try:
            result = self._pi.run(
                prompt=prompt, cwd=str(cwd), model=model, thinking=thinking, session_dir=str(paths.sessions),
                session_id=session_id, name=name, charter=charter, tools=tools, attachments=list(attachments),
                timeout_seconds=self._settings.session_timeout_seconds, log_path=str(log_path),
                cancel=lambda: self._cancel_requested(issue_number),
            )
        except BaseException as exc:
            # PiRunner.run raises before spawning for a bad cwd or an oversized prompt; the
            # row must not stay "(running)" in the ledger forever.
            message = _error_text(exc)
            self._store.finish_session(session_id, -1, 0.0, message[:MAX_SESSION_SUMMARY_CHARS])
            if isinstance(exc, Exception):
                raise CodeFactoryError(f"{role} session could not run: {message}"[:MAX_ERROR_CHARS], code="pi_failed") from exc
            raise
        summary = (result.error or result.text or "")[:MAX_SESSION_SUMMARY_CHARS]
        self._store.finish_session(session_id, result.exit_code, result.cost_usd, summary, session_file=result.session_file)
        if result.error == "cancelled":
            raise _Interrupted(f"{role} session cancelled")
        if result.error:
            raise CodeFactoryError(f"{role} session failed: {result.error}"[:MAX_ERROR_CHARS], code="pi_failed")
        return result

    def _restore_clean_worktree(self, number: int, stage: str, cwd: Path, role: str) -> None:
        if self._git.is_clean(cwd):
            return
        self._git.reset_hard(cwd)
        self._git.clean(cwd)
        self._store.add_event(number, stage, "warning", f"The {role} session left changes behind; the worktree was reset")

    def _discard_leftovers(self, number: int, stage: str, cwd: Path, role: str) -> None:
        """Reset a dirty tree before a fresh session (an interrupted or crashed one left it behind)."""
        if self._git.is_clean(cwd):
            return
        self._git.reset_hard(cwd)
        self._git.clean(cwd)
        self._store.add_event(number, stage, "warning",
                              f"Uncommitted changes from an interrupted {role} session were discarded before starting a fresh one")

    def _resolve_optional(self, ref: str) -> str:
        try:
            return self._git.resolve(ref)
        except CodeFactoryError:
            return ""

    def _ensure_worktree(self, issue: Mapping[str, Any]) -> Path:
        """Return the issue's worktree path, (re)creating it when it is missing.

        A stale registration (directory deleted out of band) counts as missing. The
        recreated branch keeps the work that already exists: the local branch when it
        survived, else the pushed ``origin/<branch>``, else the recorded head sha. Only
        when none exists is it based on the base branch again, and then the plan's task
        progress is reset so the implement stage re-runs instead of blocking on
        ``no_changes`` (or pushing an empty branch).
        """
        number = issue["number"]
        path = Path(issue.get("worktreePath") or self._worktree_path(number))
        branch = issue.get("branch") or self._branch(number)
        if self._git.find_worktree(path) is None:
            if path.exists():
                self._git.remove_worktree(path)
            source = self._create_worktree(issue, path, branch)
            self._store.add_event(number, issue["stage"], "info", f"Worktree created on {branch} from {source}")
        self._store.update_issue(number, branch=branch, worktreePath=str(path), worktreeCleaned=False)
        return path

    def _create_worktree(self, issue: Mapping[str, Any], path: Path, branch: str) -> str:
        """Create the worktree from the best surviving copy of the branch; returns what it was based on."""
        if self._git.branch_exists(branch):
            self._git.add_worktree(path, branch, self._base_ref())
            return f"local branch {branch}"
        remote_ref = f"origin/{branch}"
        if self._resolve_optional(remote_ref):
            self._git.add_worktree(path, branch, remote_ref)
            return remote_ref
        head = str(issue.get("headSha") or "")
        if head and self._resolve_optional(head):
            self._git.add_worktree(path, branch, self._base_ref())
            self._git.reset_hard(path, head)
            return f"recorded head {head[:12]}"
        self._git.add_worktree(path, branch, self._base_ref())
        self._forget_lost_progress(issue)
        return self._base_ref()

    def _forget_lost_progress(self, issue: Mapping[str, Any]) -> None:
        """Reset task progress when the branch's never-pushed commits are gone for good."""
        plan = issue.get("planJson")
        if not isinstance(plan, dict):
            return
        progress = plan.get("progress")
        if not isinstance(progress, dict) or not any(
            isinstance(item, dict) and item.get("done") for item in progress.values()
        ):
            return
        plan = dict(plan)
        plan["progress"] = {}
        self._save_plan(issue, plan, self._paths(issue["number"]))
        self._store.add_event(
            issue["number"], issue["stage"], "warning",
            "The branch's unpushed commits are gone (worktree and local branch were removed before any push); "
            "task progress was reset so the implement stage re-runs every task",
        )

    def _cleanup_worktree(self, issue: Mapping[str, Any], stage: str) -> bool:
        """Remove the issue's worktree and local branch; returns True when nothing is left behind."""
        number = issue["number"]
        ok = True
        path = issue.get("worktreePath")
        if path:
            try:
                self._git.remove_worktree(path)
            except CodeFactoryError as exc:
                ok = False
                self._store.add_event(number, stage, "warning", f"Worktree removal failed: {_error_text(exc)}")
        branch = issue.get("branch")
        if branch and ok:
            try:
                self._git.delete_branch(branch)
            except CodeFactoryError as exc:
                self._store.add_event(number, stage, "warning", f"Branch deletion failed: {_error_text(exc)}")
        try:
            self._git.prune_worktrees()
        except CodeFactoryError as exc:
            self._store.add_event(number, stage, "warning", f"Worktree prune failed: {_error_text(exc)}")
        if ok:
            self._store.update_issue(number, worktreeCleaned=True)
            self._store.add_event(number, stage, "success", "Worktree cleaned up")
        return ok

    @staticmethod
    def _coerce_finding(item: Mapping[str, Any]) -> dict[str, Any]:
        finding: dict[str, Any] = {
            "file": str(item.get("file") or "(unknown)")[:512],
            "category": str(item.get("category") or "finding")[:200],
        }
        line = item.get("line")
        if isinstance(line, int) and not isinstance(line, bool) and line > 0:
            finding["line"] = line
        return finding

    def _privacy_findings(self, cwd: Path) -> list[dict[str, Any]]:
        """Run ``scripts/check-public-source.py`` in ``cwd`` and return its findings.

        The script resolves its root from its own location, so the daemon would execute
        whatever copy the session left in the worktree; the gate therefore refuses to run
        when the branch changed the script (compared with the merge base of the base
        branch). Its output is size-capped and every finding is reduced to
        ``{file, line, category}`` before it reaches the ledger or a prompt.
        """
        base = self._base_ref()
        try:
            changed = self._git.changed_files(cwd, base)
        except CodeFactoryError as exc:
            raise CodeFactoryError(
                f"privacy check could not compare {PRIVACY_CHECK_SCRIPT} with {base}: {_error_text(exc)[:300]}",
                code="privacy_check_failed",
            ) from exc
        if PRIVACY_CHECK_SCRIPT in changed:
            raise CodeFactoryError(
                f"{PRIVACY_CHECK_SCRIPT} was modified on this branch; the daemon only runs the copy from {base}",
                code="privacy_check_failed",
            )
        argv = [self._settings.python, PRIVACY_CHECK_SCRIPT]
        try:
            result = self._check_runner(
                argv, cwd=str(cwd), capture_output=True, text=True, timeout=PRIVACY_CHECK_TIMEOUT_SECONDS,
                env=self._git.environment(),
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise CodeFactoryError(f"privacy check could not run: {_error_text(exc)[:300]}", code="privacy_check_failed") from exc
        stdout = result.stdout if isinstance(result.stdout, str) else ""
        if len(stdout) > MAX_CHECK_OUTPUT_CHARS:
            raise CodeFactoryError(f"privacy check output exceeded {MAX_CHECK_OUTPUT_CHARS} characters", code="privacy_check_failed")
        try:
            payload = json.loads(stdout) if stdout.strip() else None
        except ValueError:
            payload = None
        if not isinstance(payload, dict):
            stderr = (result.stderr if isinstance(result.stderr, str) else "").strip()[-300:]
            raise CodeFactoryError(f"privacy check produced no report (exit {result.returncode}): {stderr}", code="privacy_check_failed")
        findings = payload.get("findings")
        if payload.get("ok") is True and not findings:
            return []
        items = [self._coerce_finding(item) for item in (findings if isinstance(findings, list) else []) if isinstance(item, Mapping)]
        return items[:MAX_FINDINGS] or [{"file": "(unknown)", "category": "privacy check failed"}]

    def _wait_for_verify(
        self,
        sha: str,
        on_status: Callable[[str], None] | None = None,
        *,
        on_warning: Callable[[str], None] | None = None,
        cancel: Callable[[], bool] | None = None,
    ) -> str:
        """Poll the Verify workflow for ``sha``; returns success, failure, timeout or interrupted.

        A failing ``gh run list`` (rate limit, 5xx, network blip) is reported through
        ``on_warning`` and polling continues within the same deadline; only
        ``VERIFY_POLL_MAX_ERRORS`` consecutive failures propagate.
        """
        started = self._clock()
        errors = 0
        while True:
            status: str | None
            try:
                status = self._github.verify_status(sha)
                errors = 0
            except CodeFactoryError as exc:
                errors += 1
                message = f"Verify status check failed ({errors}/{VERIFY_POLL_MAX_ERRORS}): {_error_text(exc)[:300]}"
                if on_warning is not None:
                    on_warning(message)
                self._log(message)
                if errors >= VERIFY_POLL_MAX_ERRORS:
                    raise
                status = None
            if status is not None:
                if on_status is not None:
                    on_status(status)
                if status in ("success", "failure"):
                    return status
            if self._clock() - started >= self._settings.verify_wait_seconds:
                return "timeout"
            if self._stop_event.is_set() or (cancel is not None and cancel()):
                return "interrupted"
            self._sleep(VERIFY_POLL_SECONDS)

    # -- stages ---------------------------------------------------------------------

    def _stage_intake(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        paths = self._paths(number)
        remote = self._github.get_issue(number)
        self._write_json(paths.issue_json, remote)
        labels = _label_names(remote) or list(issue.get("labels") or [])
        marker = issue_reports.parse_report_marker(remote.get("body"))
        self._store.update_issue(
            number,
            title=prompts.single_line(remote.get("title"))[:500] or issue["title"],
            url=str(remote.get("url") or issue["url"] or "")[:500],
            author=_author_login(remote)[:100] or issue["author"],
            labels=labels,
            kind=_kind_from(labels, marker) if (labels or marker) else issue["kind"],
        )
        if str(remote.get("state") or "").upper() == "CLOSED":
            self._store.add_event(number, "intake", "warning", "Issue is already closed on GitHub; skipping")
            self._skip_issue(self._store.get_issue(number) or issue, remove_label=False)
            return None
        downloaded = self._download_attachments(number, remote, marker, paths)
        # The dashboard URL is tailnet-bound and its API may be token-less: it goes into the
        # private ledger only, never into the public issue comment.
        self._store.add_event(number, "intake", "info", f"Picked up; {downloaded} attachment(s) downloaded",
                              {"dashboardUrl": self._dashboard_url() or None})
        self._comment(number, "intake", prompts.pickup_comment())
        return "worktree"

    def _download_attachments(self, number: int, remote: Mapping[str, Any], marker: Mapping[str, Any] | None, paths: RunPaths) -> int:
        candidates: list[tuple[str, str]] = []
        seen: set[str] = set()
        if isinstance(marker, Mapping) and isinstance(marker.get("attachments"), list):
            for item in marker["attachments"]:
                if not isinstance(item, Mapping):
                    continue
                url = item.get("url")
                if isinstance(url, str) and url not in seen:
                    seen.add(url)
                    candidates.append((str(item.get("name") or item.get("asset") or url.rsplit("/", 1)[-1]), url))
        body = remote.get("body") if isinstance(remote.get("body"), str) else ""
        for match in _ATTACHMENT_URL_RE.finditer(body):
            url = match.group(0).rstrip(".,;")
            if url not in seen:
                seen.add(url)
                candidates.append((url.rsplit("/", 1)[-1].split("?", 1)[0], url))
        downloaded = 0
        for index, (name, url) in enumerate(candidates[:MAX_ATTACHMENT_DOWNLOADS], start=1):
            safe_name = _safe_attachment_name(name, index)
            extension = _extension(safe_name)
            if extension and extension not in ATTACHMENT_EXTENSIONS:
                self._store.add_event(number, "intake", "warning", f"Skipped attachment {safe_name}: extension not allowed")
                continue
            if not self._github.allowed_download(url):
                self._store.add_event(number, "intake", "warning", f"Skipped attachment {safe_name}: host not allowed")
                continue
            destination = paths.attachments / safe_name
            if self._attachment_present(paths, safe_name, extension):
                downloaded += 1
                continue
            try:
                self._github.download(url, destination)
                if not extension:
                    # GitHub web-UI screenshots are served as user-attachments/assets/<uuid>;
                    # the planner only gets them as images when the file name says so.
                    sniffed = prompts.sniff_image_extension(destination)
                    if sniffed:
                        destination.rename(destination.with_name(f"{safe_name}.{sniffed}"))
                downloaded += 1
            except CodeFactoryError as exc:
                self._store.add_event(number, "intake", "warning", f"Attachment {safe_name} not downloaded: {_error_text(exc)}")
        return downloaded

    @staticmethod
    def _attachment_present(paths: RunPaths, safe_name: str, extension: str) -> bool:
        candidates = [paths.attachments / safe_name]
        if not extension:
            candidates += sorted(paths.attachments.glob(f"{safe_name}.*"))
        return any(candidate.is_file() and candidate.stat().st_size > 0 for candidate in candidates)

    def _commit_message(self, number: int, text: str) -> str:
        """A commit subject that can never auto-close an issue when the squash merge inherits it."""
        return prompts.neutralize_closing_keywords(f"Issue #{number}: {prompts.single_line(text)[:200]}")

    def _stage_worktree(self, issue: dict[str, Any]) -> str | None:
        self._git.fetch()
        path = self._ensure_worktree(issue)
        self._store.add_event(issue["number"], "worktree", "info", f"Worktree ready on {self._branch(issue['number'])}",
                              {"path": str(path)})
        return "plan"

    def _stage_plan(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        paths = self._paths(number)
        cwd = self._ensure_worktree(issue)
        # A retry after a human question must see replies and description edits made
        # after intake; the cached issue snapshot is deliberately refreshed here.
        view = self._issue_view(issue, paths, refresh=True)
        descriptors = [prompts.attachment_descriptor(file) for file in sorted(paths.attachments.iterdir()) if file.is_file()]
        images = [item["path"] for item in descriptors if item["isImage"]]
        hints = [
            f"Verification commands are listed in README.md; Python tests run with `python3 -m unittest tests.test_x`.",
            f"Base branch: {self._settings.base_branch}; the worktree branch is {self._branch(number)}.",
        ]
        previous = issue.get("planJson") if isinstance(issue.get("planJson"), dict) else None
        prior_review = previous.get("last_review") if isinstance(previous, dict) else None
        if isinstance(prior_review, dict) and prior_review:
            self._store.add_event(
                number, "plan", "info", "Prior review evidence retained for corrective planning",
                {
                    "reviewRound": int(issue.get("reviewRound") or 0),
                    "requirementsAssessment": prior_review.get("requirements_assessment"),
                    "planAdjustmentAssessment": prior_review.get("plan_adjustment_assessment"),
                    "blocking": prior_review.get("blocking"),
                    "needsHuman": prior_review.get("needs_human"),
                    "humanQuestion": prior_review.get("human_question"),
                },
            )
        result = self._session(
            issue_number=number, role="planner", model=self._settings.planner_model,
            thinking=self._settings.planner_thinking,
            prompt=prompts.planner_prompt(view, descriptors, hints, previous), cwd=cwd, name=f"issue-{number} plan",
            charter=prompts.PLANNER_CHARTER, tools=prompts.PLANNER_TOOLS, paths=paths, attachments=images,
        )
        self._restore_clean_worktree(number, "plan", cwd, "planner")
        plan = prompts.validate_plan(prompts.extract_json_block(result.text))
        self._save_plan(issue, plan, paths)
        self._store.update_issue(number, planSummary=plan["summary"][:4000])
        if plan["needs_human"]:
            question = plan["human_question"] or "The planner needs a decision."
            self._comment(number, "plan", prompts.human_question_comment(question))
            self._block(number, "plan", "human_question", question)
            return None
        self._store.add_event(number, "plan", "success", f"Plan ready: {len(plan['tasks'])} task(s), risk {plan['risk']}")
        self._comment(number, "plan", prompts.plan_digest(plan, corrected=previous is not None))
        return "implement"

    def _stage_implement(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        paths = self._paths(number)
        cwd = self._ensure_worktree(issue)
        issue = self._store.get_issue(number) or issue  # progress may have been reset while recreating the worktree
        plan = self._ready_plan(issue, paths, "implement")
        if plan is None:
            return "plan"
        view = self._issue_view(issue, paths)
        progress: dict[str, Any] = dict(plan.get("progress") or {})
        summaries: list[str] = [
            str(progress[task["id"]].get("summary") or "") for task in plan["tasks"]
            if isinstance(progress.get(task["id"]), dict) and progress[task["id"]].get("done")
        ]
        for task in plan["tasks"]:
            task_id = str(task["id"])
            if isinstance(progress.get(task_id), dict) and progress[task_id].get("done"):
                continue
            if self._cancel_requested(number):
                raise _Interrupted("skip or shutdown requested between tasks")
            self._discard_leftovers(number, "implement", cwd, "implementer")
            result = self._session(
                issue_number=number, role="implementer", model=self._settings.implementer_model,
                thinking=self._settings.implementer_thinking,
                prompt=prompts.implementer_prompt(plan, task, view, summaries), cwd=cwd,
                name=f"issue-{number} {task_id}", charter=prompts.IMPLEMENTER_CHARTER,
                tools=prompts.IMPLEMENTER_TOOLS, paths=paths,
            )
            sha = self._git.commit_all(cwd, self._commit_message(number, task["title"]))
            summary = (result.text or "")[:MAX_SESSION_SUMMARY_CHARS]
            progress[task_id] = {"done": True, "sha": sha, "summary": summary, "finishedAt": utc_now()}
            plan["progress"] = progress
            self._save_plan(issue, plan, paths)
            self._store.add_event(number, "implement", "success", f"Task {task_id} finished: {prompts.single_line(task['title'])}",
                                  {"sha": sha, "committed": sha is not None})
            summaries.append(summary)
        findings = self._privacy_findings(cwd)
        if findings:
            self._store.add_event(number, "implement", "warning", f"Privacy check reported {len(findings)} finding(s); asking for a fix",
                                  {"findings": findings[:50]})
            self._session(
                issue_number=number, role="privacy-fix", model=self._settings.implementer_model,
                thinking=self._settings.implementer_thinking, prompt=prompts.privacy_fix_prompt(findings, view), cwd=cwd,
                name=f"issue-{number} privacy", charter=prompts.IMPLEMENTER_CHARTER, tools=prompts.IMPLEMENTER_TOOLS, paths=paths,
            )
            self._git.commit_all(cwd, self._commit_message(number, "address privacy check findings"))
            findings = self._privacy_findings(cwd)
            if findings:
                self._block(number, "implement", "privacy_check_failed",
                            f"{len(findings)} finding(s) remain after one fix attempt")
                return None
        if self._git.count_commits(cwd, self._base_ref()) == 0:
            self._block(number, "implement", "no_changes", "The implementer sessions produced no commits")
            return None
        return "pull_request"

    def _stage_pull_request(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        cwd = self._ensure_worktree(issue)
        branch = issue.get("branch") or self._branch(number)
        plan = self._plan_for(issue)
        if self._git.count_commits(cwd, self._base_ref()) == 0:
            self._store.add_event(number, "pull_request", "warning",
                                  f"The branch has no commits beyond {self._base_ref()}; returning to the implement stage")
            return "implement"
        self._git.push(cwd, "origin", f"HEAD:refs/heads/{branch}")
        existing = self._github.find_pull_request(branch)
        if existing and str(existing.get("state") or "OPEN").upper() == "OPEN":
            pr = existing
            self._store.add_event(number, "pull_request", "info", f"Reusing open PR #{pr['number']}")
        else:
            title = self._public(prompts.pull_request_title(plan, issue))
            body = self._public(prompts.pull_request_body(issue, plan))
            pr = self._github.create_pull_request(branch, self._settings.base_branch, title, body)
            self._store.add_event(number, "pull_request", "success", f"Opened PR #{pr['number']}", {"url": pr.get("url")})
        head = self._git.head(cwd)
        self._store.update_issue(
            number, prNumber=int(pr["number"]), prUrl=str(pr.get("url") or "")[:500], headSha=head,
            ciStatus=None,
        )
        return "verify"

    def _stage_verify(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        head = issue.get("headSha")
        if not head:
            return "pull_request"
        pr_number = issue.get("prNumber")
        if isinstance(pr_number, int) and self._head_moved(number, "verify", pr_number, head):
            return "verify"
        status = self._wait_for_verify(
            head, lambda value: self._store.update_issue(number, ciStatus=value),
            on_warning=lambda message: self._store.add_event(number, "verify", "warning", message),
            cancel=lambda: self._cancel_requested(number),
        )
        if status == "interrupted":
            raise _Interrupted()
        if status == "success":
            self._store.add_event(number, "verify", "success", f"Verify passed on {head[:12]}")
            return "review"
        if status == "failure":
            attempt = int(issue.get("ciFailures") or 0) + 1
            if attempt > self._settings.max_ci_failures:
                # Checked before anything is persisted, so a retry on the same failing head
                # re-blocks without inflating the CI-failure counter past its configured maximum.
                self._store.add_event(number, "verify", "warning", f"Verify failed on {head[:12]}; no CI failures left")
                self._block(number, "verify", "ci_failures_exhausted", f"{attempt - 1} CI failure(s) used; CI still failing")
                return None
            if issue.get("ciRerunRequested") != head:
                failed = [
                    run for run in self._github.list_runs(head)
                    if run.get("status") == "completed" and run.get("conclusion") != "success"
                    and isinstance(run.get("databaseId"), int)
                ]
                for run in failed:
                    self._github.rerun_failed(run["databaseId"])
                self._store.update_issue(number, ciFailures=attempt, ciRerunRequested=head, ciStatus="pending")
                self._store.add_event(number, "verify", "warning", f"Verify failed on {head[:12]}; re-running failed jobs once")
                return "verify"
            log = self._github.failed_run_log(head)
            plan = self._plan_for(issue)
            plan["ci_log"] = log[-prompts.MAX_LOG_CHARS:]
            plan["last_review"] = None
            self._store.update_issue(number, planJson=plan, ciFailures=attempt)
            self._store.add_event(number, "verify", "warning", f"Verify failed on {head[:12]} (CI failure {attempt})")
            return "revise"
        self._block(number, "verify", "ci_timeout", f"Verify did not finish within {self._settings.verify_wait_seconds} s")
        return None

    def _head_moved(self, number: int, stage: str, pr_number: int, head: str) -> bool:
        """True (after recording the new head) when the PR branch no longer points at the verified sha."""
        if not head:
            return False
        try:
            live = self._github.pull_request(pr_number)
        except CodeFactoryError as exc:
            self._store.add_event(number, stage, "warning", f"Could not read the pull request head: {_error_text(exc)}")
            return False
        live_head = str(live.get("headRefOid") or "").strip().lower()
        if not live_head or live_head == head.lower():
            return False
        self._store.update_issue(number, headSha=live_head, ciStatus=None)
        self._store.add_event(number, stage, "warning",
                              f"The pull request head moved from {head[:12]} to {live_head[:12]} since it was verified; re-running Verify")
        return True

    @staticmethod
    def _pending_review(plan: Mapping[str, Any], head: str) -> dict[str, Any] | None:
        """A currently valid review for ``head`` whose GitHub post failed."""
        review = plan.get("last_review")
        if not (
            isinstance(review, dict) and review and plan.get("last_review_head") == head
            and plan.get("last_review_posted") is False
        ):
            return None
        try:
            return prompts.validate_review(review, plan)
        except CodeFactoryError:
            # Legacy/incomplete stored reviews are never trusted or reposted.
            return None

    def _stage_review(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        head = issue.get("headSha") or ""
        pr_number = int(issue["prNumber"])
        if self._head_moved(number, "review", pr_number, head):
            return "verify"
        paths = self._paths(number)
        cwd = self._ensure_worktree(issue)
        plan = self._ready_plan(issue, paths, "review")
        if plan is None:
            return "plan"
        review = self._pending_review(plan, head)
        if review is not None:
            round_number = max(1, int(issue["reviewRound"] or 0))
            self._store.add_event(number, "review", "info", f"Posting the stored review for round {round_number}; the earlier post failed")
        else:
            round_number = int(issue["reviewRound"] or 0) + 1
            if round_number > self._settings.max_review_rounds:
                self._block(number, "review", "review_rounds_exhausted", f"{round_number - 1} review round(s) used")
                return None
            self._store.update_issue(number, reviewRound=round_number)
            view = self._issue_view(issue, paths)
            descriptors = [
                prompts.attachment_descriptor(file)
                for file in sorted(paths.attachments.iterdir()) if file.is_file()
            ]
            images = [item["path"] for item in descriptors if item["isImage"]]
            self._git.fetch()
            if head and self._git.head(cwd) != head:
                self._git.reset_hard(cwd, head)
            diff = self._github.pull_request_diff(pr_number)
            result = self._session(
                issue_number=number, role="reviewer", model=self._settings.planner_model, thinking=self._settings.planner_thinking,
                prompt=prompts.reviewer_prompt(
                    view, plan, {"number": pr_number, "url": issue.get("prUrl")}, diff,
                    issue.get("ciStatus"), plan.get("ci_log"), round_number, descriptors,
                ),
                cwd=cwd, name=f"issue-{number} review {round_number}", charter=prompts.REVIEWER_CHARTER,
                tools=prompts.REVIEWER_TOOLS, paths=paths, attachments=images,
            )
            self._restore_clean_worktree(number, "review", cwd, "reviewer")
            review = prompts.validate_review(prompts.extract_json_block(result.text), plan)
            # Persist before posting: a gh failure must not discard a finished Astra round.
            plan.update(last_review=review, last_review_head=head, last_review_posted=False)
            self._save_plan(issue, plan, paths)
        body = self._public(prompts.review_body(round_number, review))
        comments = [dict(item, body=self._public(item["body"])) for item in review["comments"]]
        self._github.post_review(pr_number, body, comments)
        plan.update(last_review=review, last_review_head=head, last_review_posted=True, ci_log=None)
        self._save_plan(issue, plan, paths)
        self._store.add_event(number, "review", "success" if review["verdict"] == "approve" else "warning",
                              f"Review round {round_number}: {review['verdict']}", {"blocking": review["blocking"][:20]})
        if review["needs_human"]:
            question = review["human_question"] or "The reviewer needs a behavior decision."
            self._comment(number, "review", prompts.human_question_comment(question))
            self._block(number, "review", "human_question", question)
            return None
        if review["plan_adjustment_assessment"]["narrows_request"]:
            plan.pop("progress", None)
            self._save_plan(issue, plan, paths)
            self._store.add_event(
                number, "review", "warning",
                "The review found that the plan narrowed the original request; returning to planning",
            )
            return "plan"
        return "merge" if review["verdict"] == "approve" else "revise"

    def _stage_revise(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        head = issue.get("headSha") or ""
        pr_number = issue.get("prNumber")
        if isinstance(pr_number, int) and self._head_moved(number, "revise", pr_number, head):
            return "verify"
        paths = self._paths(number)
        cwd = self._ensure_worktree(issue)
        plan = self._ready_plan(issue, paths, "revise")
        if plan is None:
            return "plan"
        view = self._issue_view(issue, paths)
        round_number = int(issue["reviewRound"] or 0)
        branch = issue.get("branch") or self._branch(number)
        review = plan.get("last_review") if isinstance(plan.get("last_review"), dict) else None
        if head and self._git.head(cwd) != head and self._resolve_optional(head):
            self._git.reset_hard(cwd, head)
        self._discard_leftovers(number, "revise", cwd, "reviser")
        self._session(
            issue_number=number, role="reviser", model=self._settings.implementer_model,
            thinking=self._settings.implementer_thinking,
            prompt=prompts.reviser_prompt(plan, review, plan.get("ci_log"), view), cwd=cwd,
            name=f"issue-{number} revise {round_number}", charter=prompts.REVISER_CHARTER,
            tools=prompts.IMPLEMENTER_TOOLS, paths=paths,
        )
        sha = self._git.commit_all(cwd, self._commit_message(number, f"address review round {round_number}"))
        self._git.push(cwd, "origin", f"HEAD:refs/heads/{branch}")
        head = self._git.head(cwd)
        self._store.update_issue(number, headSha=head, ciStatus=None)
        self._store.add_event(number, "revise", "info", f"Revision pushed ({head[:12]})", {"committed": sha is not None})
        return "verify"

    def _stage_merge(self, issue: dict[str, Any]) -> str | None:
        number = issue["number"]
        pr_number = int(issue["prNumber"])
        head = issue.get("headSha") or ""
        if self._head_moved(number, "merge", pr_number, head):
            return "verify"
        paths = self._paths(number)
        plan = self._ready_plan(issue, paths, "merge")
        if plan is None:
            return "plan"
        stored_review = plan.get("last_review")
        try:
            review = prompts.validate_review(stored_review, plan)
        except CodeFactoryError as exc:
            self._store.add_event(
                number, "merge", "warning",
                f"Stored approval is no longer valid ({_error_text(exc)}); returning to review",
            )
            return "review"
        if (
            review["verdict"] != "approve" or plan.get("last_review_head") != head
            or plan.get("last_review_posted") is not True
        ):
            self._store.add_event(
                number, "merge", "warning",
                "No posted approval for the exact pull request head; returning to review",
            )
            return "review"
        merged = self._github.merge_pull_request(
            pr_number,
            subject=self._public(prompts.pull_request_title(plan, issue)),
            body=self._public(prompts.pull_request_body(issue, plan)),
            head_sha=head or None,
        )
        merge_sha = str(merged.get("mergeSha") or "") or None
        self._store.update_issue(number, mergeSha=merge_sha)
        self._store.add_event(number, "merge", "success", f"Squash-merged PR #{pr_number}", {"mergeSha": merge_sha})
        self._cleanup_worktree(self._store.get_issue(number) or issue, "merge")
        self._comment(number, "merge", prompts.merged_comment(merge_sha, pr_number, release_enabled=self._settings.release_enabled))
        return "release" if self._settings.release_enabled else "done"

    # -- actions --------------------------------------------------------------------

    def action(self, number: int | None, action: str) -> dict[str, Any]:
        """Apply a dashboard/CLI action; raises ``invalid_request``/``not_found`` on bad input."""
        if action not in ACTIONS:
            raise CodeFactoryError(f"unknown action {str(action)[:40]!r}; expected one of {', '.join(ACTIONS)}", code="invalid_request")
        if action == "release_now":
            started = self._start_release()
            return {"ok": True, "action": action, "issue": None, "releaseStarted": started}
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise CodeFactoryError("issue number must be a positive integer", code="invalid_request")
        issue = self._store.get_issue(number)
        if issue is None:
            raise CodeFactoryError(f"issue #{number} is not tracked", code="not_found")
        queued = False
        if action == "retry":
            if issue["status"] not in ("blocked", "failed"):
                raise CodeFactoryError(f"issue #{number} is {issue['status']}; only blocked or failed issues can be retried", code="invalid_request")
            retry_stage = issue["stage"]
            if issue.get("blockedReason") == "human_question":
                paths = self._paths(number)
                try:
                    remote = self._github.get_issue(number)
                except CodeFactoryError as exc:
                    message = f"Retry could not refresh the issue from GitHub; it remains blocked: {_error_text(exc)}"
                    self._store.add_event(number, retry_stage, "warning", message)
                    raise CodeFactoryError(message, code=exc.code) from exc
                self._write_json(paths.issue_json, remote)
                labels = _label_names(remote) or list(issue.get("labels") or [])
                marker = issue_reports.parse_report_marker(remote.get("body"))
                self._store.update_issue(
                    number,
                    title=prompts.single_line(remote.get("title"))[:500] or issue["title"],
                    url=str(remote.get("url") or issue.get("url") or "")[:500],
                    author=_author_login(remote)[:100] or issue.get("author") or "",
                    labels=labels,
                    kind=_kind_from(labels, marker) if (labels or marker) else issue["kind"],
                )
                prior = issue.get("planJson")
                if isinstance(prior, dict):
                    prior = dict(prior)
                    prior.pop("progress", None)
                    self._save_plan(self._store.get_issue(number) or issue, prior, paths)
                retry_stage = "plan"
                self._store.add_event(
                    number, issue["stage"], "info",
                    "Human-decision retry refreshed the issue description and will create a fresh plan; prior feedback is context, not approval",
                )
            self._store.update_issue(number, status="active", stage=retry_stage, error=None, blockedReason=None)
            self._store.add_event(number, retry_stage, "info", f"Retry requested at {STAGE_LABELS.get(retry_stage, retry_stage)}")
            queued = self._start_release() if retry_stage == "release" else self._submit(number)
        elif action == "skip":
            if issue["status"] == "done":
                raise CodeFactoryError(f"issue #{number} is already done", code="invalid_request")
            self._skip_issue(issue, remove_label=True)
        elif action == "cleanup":
            if self.is_running(number):
                raise CodeFactoryError(f"issue #{number} is being processed; wait for it to pause", code="invalid_request")
            self._cleanup_worktree(issue, issue["stage"])
        return {"ok": True, "action": action, "issue": self._store.get_issue(number), "queued": queued}

    def _skip_issue(self, issue: Mapping[str, Any], *, remove_label: bool) -> None:
        """Mark the issue skipped; a running issue is cancelled and its worktree removed once the worker exits."""
        number = issue["number"]
        stage = issue["stage"]
        with self._lock:
            running = number in self._active
            self._store.update_issue(number, status="skipped", finishedAt=utc_now())
            if running:
                self._cancelled.add(number)
        if running:
            self._store.add_event(number, stage, "warning",
                                  "Skipped; the running session is being cancelled and the worktree is removed once it exits")
            self._log(f"issue #{number}: skip requested while running at {stage}")
        else:
            self._store.add_event(number, stage, "warning", "Skipped")
            self._cleanup_worktree(self._store.get_issue(number) or issue, stage)
        if remove_label and self._settings.comment_on_issues:
            try:
                self._github.remove_labels(number, self._settings.trigger_label)
            except CodeFactoryError as exc:
                self._store.add_event(number, issue["stage"], "warning", f"Could not remove the trigger label: {_error_text(exc)}")

    # -- releases -------------------------------------------------------------------

    def _start_release(self) -> bool:
        """Start a release batch unless one is in flight (background when the daemon runs)."""
        if self._release_lock.locked():
            return False
        self._release_deferred_logged = False
        if self.started:
            with self._lock:
                if self._release_thread is not None and self._release_thread.is_alive():
                    return False
                self._release_thread = threading.Thread(target=self.run_release_batch, name="code-factory-release", daemon=False)
                self._release_thread.start()
            return True
        self.run_release_batch()
        return True

    def run_release_batch(self) -> dict[str, Any]:
        """Release every issue waiting at ``stage=release`` as one signed macOS build (single-flight)."""
        if not self._release_lock.acquire(blocking=False):
            return {"ok": False, "reason": "busy", "issues": []}
        try:
            return self._release_batch()
        finally:
            self._release_lock.release()

    def _release_batch(self) -> dict[str, Any]:
        waiting = [issue for issue in self._store.list_issues("active") if issue["stage"] == "release"]
        numbers = sorted(issue["number"] for issue in waiting)
        if not waiting:
            return {"ok": True, "reason": "nothing_to_release", "issues": []}
        if not self._settings.release_enabled:
            return {"ok": False, "reason": "release_disabled", "issues": numbers}
        settings = self._settings
        label = time.strftime("%Y%m%d-%H%M%S", time.gmtime(self._clock()))
        worktree = settings.worktree_root / f"release-{label}"
        issues = waiting
        tag: str | None = None
        try:
            self._git.fetch()
            self._git.add_worktree(worktree, None, self._base_ref(), detach=True)
            script = load_release_script(worktree)
            version_file = worktree / RELEASE_VERSION_FILE
            current = script.validate_version(json.loads(version_file.read_text(encoding="utf-8")))
            resumed = self._resumable_release(script, current)
            manifest: Path | None = None
            if resumed is not None:
                # The bump commit and its notes already landed: rebuild exactly that source for
                # exactly the issues the notes cover. Issues merged since wait for the next batch.
                tag = str(resumed["tag"])
                version_label = str(resumed["version"])
                notes_rel = str(resumed["notesPath"])
                source_sha = str(resumed["sourceSha"])
                original = {item for item in (resumed.get("issueNumbers") or []) if isinstance(item, int)}
                issues = [issue for issue in waiting if issue["number"] in original]
                numbers = sorted(issue["number"] for issue in issues)
                for issue in waiting:
                    if issue["number"] not in original:
                        self._store.add_event(issue["number"], "release", "info",
                                              f"Waiting for the next batch: release {tag} is being resumed and its notes do not cover this issue")
                if self._git.head(worktree) != source_sha:
                    self._git.checkout_detached(worktree, source_sha)
                self._store.update_release(tag, status="preparing", error=None, finishedAt=None, issueNumbers=numbers)
                for number in numbers:
                    self._store.add_event(number, "release", "info",
                                          f"Resuming release {tag} at {source_sha[:12]} (version already on {settings.base_branch})")
                manifest = self._prepared_manifest(resumed, tag, source_sha)
            else:
                part = "minor" if any(issue["kind"] == "feature" for issue in issues) else "patch"
                expected = script.next_version(current, part, settings.release_channel)
                tag = script.release_tag(expected)
                version_label = tag.removeprefix("macos-v")
                notes_rel = f"release/notes/macos-{version_label}.md"
                commit_message = f"Prepare macOS {version_label}"
                self._store.upsert_release(tag, version=version_label, channel=settings.release_channel, status="preparing",
                                           issueNumbers=numbers, notesPath=notes_rel, error=None, finishedAt=None)
                for number in numbers:
                    self._store.add_event(number, "release", "info", f"Included in release {tag} ({part} bump)")
                self._author_release(worktree, issues, current, part, notes_rel, commit_message, label)
                self._validate_release_worktree(worktree, script, expected, notes_rel, commit_message)
                self._push_base(worktree)
                source_sha = self._git.head(worktree)
            self._store.update_release(tag, sourceSha=source_sha, status="verifying")
            status = self._wait_for_verify(source_sha, on_warning=lambda message: self._log(f"release {tag}: {message}"))
            if status != "success":
                raise CodeFactoryError(f"Verify {status} on {settings.base_branch} commit {source_sha[:12]}", code="ci_failed")
            output = manifest.parent if manifest is not None else self._release_output_dir(version_label, label)
            # outputDir is recorded before publish so a retry can reuse the prepared manifest
            # (the script refuses to overwrite assets from an earlier prepare with different digests).
            self._store.update_release(tag, status="publishing", outputDir=str(output))
            published_tag = self._run_release_script(worktree, notes_rel, output, tag, manifest=manifest)
            url = f"https://github.com/{settings.repository}/releases/tag/{published_tag}"
            self._store.update_release(tag, status="published", url=url, outputDir=str(output), finishedAt=utc_now(), error=None)
            for issue in issues:
                self._finish_released_issue(issue, published_tag, version_label, url)
            self._release_failures = 0
            self._release_failed_at = None
            self._log(f"released {published_tag} with issues {numbers}")
            return {"ok": True, "tag": published_tag, "url": url, "issues": numbers}
        except Exception as exc:
            message = _error_text(exc)
            self._release_failures += 1
            self._release_failed_at = self._clock()
            if tag is not None:
                self._store.update_release(tag, status="failed", error=message, finishedAt=utc_now())
            for number in numbers:
                self._store.add_event(number, "release", "error", f"Release failed: {message}", {"tag": tag})
            self._log(f"release failed: {message}")
            return {"ok": False, "tag": tag, "error": message, "issues": numbers}
        finally:
            try:
                self._git.remove_worktree(worktree)
                self._git.prune_worktrees()
            except CodeFactoryError as exc:
                self._log(f"release worktree cleanup failed: {_error_text(exc)}")

    def _resumable_release(self, script: ModuleType, current: Mapping[str, Any]) -> dict[str, Any] | None:
        """A failed release whose version bump already landed on the base branch, if any.

        Only a row with a resolvable ``sourceSha`` can be resumed: the release ships that
        exact commit (the script pins its tag to it), whatever the base branch holds now.
        """
        tag = script.release_tag(current)
        release = self._store.get_release(tag)
        if release is None or release.get("status") not in RELEASE_RESUMABLE:
            return None
        source = release.get("sourceSha")
        if not isinstance(source, str) or not source or not self._resolve_optional(source):
            self._log(f"release {tag}: no resolvable source commit to resume from; bumping again")
            return None
        return release

    @staticmethod
    def _prepared_manifest(release: Mapping[str, Any], tag: str, source_sha: str) -> Path | None:
        """The earlier ``prepared.json`` for this tag and source, when a previous attempt got that far."""
        output = release.get("outputDir")
        if not isinstance(output, str) or not output:
            return None
        manifest = Path(output) / "prepared.json"
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(data, dict) or data.get("tag") != tag:
            return None
        source = data.get("source")
        if isinstance(source, str) and source and source != source_sha:
            return None
        return manifest

    def _author_release(
        self,
        worktree: Path,
        issues: Sequence[Mapping[str, Any]],
        current: Mapping[str, Any],
        part: str,
        notes_rel: str,
        commit_message: str,
        label: str,
    ) -> None:
        settings = self._settings
        bump_argv = [settings.python, "scripts/release-macos.py", "bump", "--part", part, "--channel", settings.release_channel]
        merged = []
        for issue in issues:
            plan = issue.get("planJson") if isinstance(issue.get("planJson"), dict) else {}
            merged.append({
                "number": issue["number"], "title": issue["title"], "kind": issue["kind"], "url": issue.get("url"),
                "prNumber": issue.get("prNumber"), "prUrl": issue.get("prUrl"),
                "releaseNotesHint": plan.get("release_notes_hint") or issue.get("planSummary") or "",
            })
        paths = self._release_paths(label)
        self._session(
            issue_number=None, role="release-author", model=settings.implementer_model, thinking=settings.implementer_thinking,
            prompt=prompts.release_author_prompt(current, bump_argv, notes_rel, merged, commit_message), cwd=worktree,
            name=f"release {label}", charter=prompts.RELEASE_AUTHOR_CHARTER, tools=prompts.IMPLEMENTER_TOOLS, paths=paths,
        )

    def _validate_release_worktree(
        self, worktree: Path, script: ModuleType, expected: Mapping[str, Any], notes_rel: str, commit_message: str,
    ) -> None:
        """Daemon-side gate on the release author's commit before anything is pushed.

        This commit lands on the base branch and inside a signed release with no review
        and no pull request, so besides the version and notes checks it must touch exactly
        ``release/macos.json`` and the notes file and carry the exact commit subject.
        """

        def failed(message: str) -> CodeFactoryError:
            return CodeFactoryError(message, code="release_failed")

        version_file = worktree / RELEASE_VERSION_FILE
        try:
            actual = script.validate_version(json.loads(version_file.read_text(encoding="utf-8")))
        except (OSError, ValueError) as exc:
            raise failed(f"release/macos.json is invalid after the bump: {_error_text(exc)[:300]}") from exc
        if dict(actual) != dict(expected):
            raise failed(f"release/macos.json does not hold the expected version {expected.get('version')}")
        notes = worktree / notes_rel
        if not notes.is_file():
            raise failed(f"release notes {notes_rel} were not written")
        size = notes.stat().st_size
        if size == 0 or size > MAX_NOTES_BYTES:
            raise failed(f"release notes {notes_rel} must be 1..{MAX_NOTES_BYTES} bytes")
        try:
            notes.read_bytes().decode("utf-8")
        except UnicodeDecodeError as exc:
            raise failed(f"release notes {notes_rel} are not UTF-8") from exc
        if not self._git.is_clean(worktree):
            raise failed("the release worktree has uncommitted changes")
        commits = self._git.count_commits(worktree, self._base_ref())
        if commits != 1:
            raise failed(f"expected exactly one release commit, found {commits}")
        changed = set(self._git.changed_files(worktree, self._base_ref()))
        allowed = {RELEASE_VERSION_FILE, notes_rel}
        if changed != allowed:
            unexpected = sorted(changed - allowed) or sorted(allowed - changed)
            raise failed(f"the release commit must change exactly {RELEASE_VERSION_FILE} and {notes_rel}; "
                         f"unexpected: {', '.join(unexpected)[:500]}")
        subject = str((self._git.log(worktree, 1) or [{}])[0].get("subject") or "")
        if subject != commit_message:
            raise failed(f"the release commit subject must be {commit_message!r}, found {subject[:120]!r}")
        findings = self._privacy_findings(worktree)
        if findings:
            raise failed(f"privacy check reported {len(findings)} finding(s) in the release commit")

    def _push_base(self, worktree: Path) -> None:
        refspec = f"HEAD:refs/heads/{self._settings.base_branch}"
        try:
            self._git.push(worktree, "origin", refspec)
        except CodeFactoryError:
            self._git.fetch()
            self._git.rebase(worktree, self._base_ref())
            self._git.push(worktree, "origin", refspec)

    def _release_output_dir(self, version_label: str, label: str) -> Path:
        root = self._settings.release_output_root
        output = root / version_label
        if output.exists():
            output = root / f"{version_label}-{label}"
        return output

    def _run_release_script(
        self, worktree: Path, notes_rel: str, output: Path, tag: str, *, manifest: Path | None = None,
    ) -> str:
        settings = self._settings
        base = [settings.python, "scripts/release-macos.py"]
        config: list[str] = []
        if settings.config_path:
            config += ["--config", settings.config_path]
        if settings.machine:
            config += ["--machine", settings.machine]
        if manifest is None:
            prepared = self._release_command(
                [*base, "prepare", *config, "--notes", str(worktree / notes_rel), "--output", str(output)], worktree, "prepare",
            )
            value = prepared.get("prepared")
            manifest_path = Path(value) if isinstance(value, str) and value else output / "prepared.json"
            if not manifest_path.is_file():
                raise CodeFactoryError("release prepare did not produce prepared.json", code="release_failed")
        else:
            manifest_path = manifest
            self._log(f"release {tag}: reusing the prepared manifest at {manifest_path}")
        published = self._release_command([*base, "publish", str(manifest_path), *config], worktree, "publish")
        value = published.get("published")
        return value if isinstance(value, str) and value.strip() else tag

    def _default_release_runner(self, argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        """Run a release command in an isolated process group."""
        capture_output = bool(kwargs.pop("capture_output", False))
        text = bool(kwargs.pop("text", False))
        timeout = kwargs.pop("timeout", None)
        if capture_output:
            kwargs["stdout"] = subprocess.PIPE
            kwargs["stderr"] = subprocess.PIPE
        process = subprocess.Popen(argv, text=text, start_new_session=True, **kwargs)
        self._set_release_process(process)
        try:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as exc:
                self._terminate_release_process(process, "timeout")
                stdout, stderr = process.communicate()
                raise subprocess.TimeoutExpired(argv, timeout, output=stdout, stderr=stderr) from exc
            return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        except subprocess.TimeoutExpired:
            raise
        except BaseException:
            self._terminate_release_process(process, "unexpected failure")
            raise
        finally:
            self._clear_release_process(process)

    def _set_release_process(self, process: Any) -> None:
        """Record the default-runner child so a bounded daemon stop can reap it."""
        with self._release_process_lock:
            self._release_process = process

    def _clear_release_process(self, process: Any) -> None:
        with self._release_process_lock:
            if self._release_process is process:
                self._release_process = None

    def _terminate_tracked_release_process(self, reason: str) -> None:
        with self._release_process_lock:
            process = self._release_process
        if process is not None:
            self._terminate_release_process(process, reason)

    def _terminate_release_process(self, process: Any, reason: str) -> None:
        """Terminate a release process group, escalating after the standard grace period."""
        self._signal_release_group(process, signal.SIGTERM, reason, process.terminate)
        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            self._signal_release_group(process, signal.SIGKILL, reason, process.kill)
            try:
                process.wait(timeout=KILL_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
        except OSError:
            pass

    def _signal_release_group(self, process: Any, signum: int, reason: str, fallback: Callable[[], Any]) -> None:
        """Signal the release group, falling back to the direct child when necessary."""
        pid = getattr(process, "pid", None)
        killpg = getattr(os, "killpg", None)
        if callable(killpg) and isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
            try:
                killpg(pid, signum)
            except OSError:
                pass
            else:
                self._log(f"release process group {pid}: signal {signum} ({reason})")
                return
        try:
            fallback()
        except OSError:
            pass

    def _release_command(self, argv: list[str], worktree: Path, step: str) -> dict[str, Any]:
        try:
            result = self._release_runner(
                argv, cwd=str(worktree), capture_output=True, text=True, timeout=RELEASE_TIMEOUT_SECONDS,
                env=self._git.environment(),
            )
        except subprocess.TimeoutExpired as exc:
            raise CodeFactoryError(f"release {step} timed out", code="release_failed") from exc
        except OSError as exc:
            raise CodeFactoryError(f"release {step} could not start: {_error_text(exc)[:300]}", code="release_failed") from exc
        stdout = result.stdout if isinstance(result.stdout, str) else ""
        stderr = (result.stderr if isinstance(result.stderr, str) else "").strip()[-300:]
        if result.returncode != 0:
            raise CodeFactoryError(f"release {step} failed: {stderr or f'exit status {result.returncode}'}", code="release_failed")
        payload: Any = None
        for line in reversed(stdout.strip().splitlines()):
            try:
                payload = json.loads(line)
            except ValueError:
                continue
            if isinstance(payload, dict):
                break
        if not isinstance(payload, dict) or payload.get("ok") is not True:
            raise CodeFactoryError(f"release {step} did not report success", code="release_failed")
        return payload

    def _finish_released_issue(self, issue: Mapping[str, Any], tag: str, version_label: str, url: str) -> None:
        number = issue["number"]
        self._comment(number, "release", prompts.released_comment(tag, url))
        try:
            self._github.add_labels(number, RELEASED_LABEL)
        except CodeFactoryError as exc:
            self._store.add_event(number, "release", "warning", f"Could not add the released label: {_error_text(exc)}")
        try:
            self._github.close_issue(number)
        except CodeFactoryError as exc:
            self._store.add_event(number, "release", "warning", f"Could not close the issue: {_error_text(exc)}")
        self._store.update_issue(
            number, releaseTag=tag, releaseVersion=version_label, releaseUrl=url, stage="done", status="done",
            finishedAt=utc_now(), error=None, blockedReason=None,
        )
        self._store.add_event(number, "done", "success", f"Released in {tag}", {"url": url})
