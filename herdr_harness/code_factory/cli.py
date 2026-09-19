"""``herdr-code-factory``: run, inspect and repair the Code Factory pipeline.

Subcommands:

- ``run``          – start the daemon (poller, worker pool, dashboard) until SIGINT/SIGTERM.
- ``once``         – one discovery poll, then process every runnable issue synchronously.
- ``status``       – print the ledger snapshot (or one issue with ``--issue``).
- ``enqueue N``    – track an issue manually and process it (``--queue-only`` to skip processing).
- ``action N …``   – ``retry``/``skip``/``cleanup`` an issue; ``release-now`` starts a release batch.
- ``cleanup``      – remove worktrees left behind by finished issues and prune git's bookkeeping.
- ``doctor``       – check the local setup (``gh``, labels, Pi, models, releases, dashboard, disk).

Every external process goes through an injectable runner so the test-suite never
touches a real ``gh``, ``pi``, ``tailscale`` or the operator's checkout. The pipeline
module is imported lazily: commands that only read the ledger work without it.

Only one process may drive stages or touch worktrees at a time: ``run`` holds the
daemon lock (``<state dir>/code-factory/daemon.lock``) for its lifetime and ``once``,
``enqueue`` (unless ``--queue-only``), ``action``, ``release-now`` and ``cleanup``
refuse to start while it is held.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence, TextIO

try:
    import fcntl
except ImportError:  # pragma: no cover - the daemon targets macOS/Linux
    fcntl = None  # type: ignore[assignment]

from ..config import Configuration, ConfigurationError, load_configuration
from .dashboard import DashboardServer, host_resolves, resolve_dashboard_host, tailscale_ipv4
from .errors import CodeFactoryError
from .git import GitRepository
from .github import GitHubClient
from .pi import PiRunner
from .settings import CodeFactorySettings
from .store import CodeFactoryStore, utc_now

REQUIRED_LABELS: tuple[tuple[str, str, str], ...] = (
    ("herdr-autofix", "AAA6F4", "Code Factory may implement and release this automatically"),
    ("herdr-app-report", "8A7FD8", "Filed from the Herdr Mac app"),
    ("released", "9CCDB9", "Shipped in a Code Factory release"),
)
ISSUE_ACTIONS = ("retry", "skip", "cleanup")
RUNNABLE_EXCLUDED_STAGES = frozenset({"release", "done"})
# Stages whose progress lives in the worktree; re-enqueueing a skipped issue there starts over.
WORKTREE_STAGES = frozenset({"plan", "implement", "pull_request", "verify", "review", "revise", "merge"})
MIN_FREE_BYTES = 5 * 1024 ** 3
PROBE_TIMEOUT = 60
OLLAMA_PREFIX = "ollama-cloud/"
DAEMON_LOCK_NAME = "daemon.lock"
SHUTDOWN_GRACE_SECONDS = 60

Runner = Callable[..., Any]


@dataclass
class Dependencies:
    """Injectable process, filesystem and pipeline hooks (defaults are the real ones)."""

    runner: Runner = subprocess.run
    popen: Callable[..., Any] = subprocess.Popen
    factory_builder: Callable[..., Any] | None = None
    dashboard_builder: Callable[..., Any] | None = None
    disk_usage: Callable[[str], Any] = shutil.disk_usage
    stdout: TextIO | None = None
    stderr: TextIO | None = None
    wait: Callable[[], None] | None = None
    now: Callable[[], str] = utc_now


def _default_factory_builder(settings: CodeFactorySettings, store: CodeFactoryStore, *, github: GitHubClient,
                             git: GitRepository, pi: PiRunner, log: Callable[[str], None]) -> Any:
    from .pipeline import CodeFactory  # imported lazily: the ledger commands do not need it

    return CodeFactory(settings, store, github=github, git=git, pi=pi, log=log)


def wait_for_shutdown_signal() -> None:
    """Block the main thread until SIGINT or SIGTERM arrives."""
    stop = threading.Event()

    def handler(signum: int, frame: Any) -> None:
        stop.set()

    previous: dict[int, Any] = {}
    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            previous[signum] = signal.signal(signum, handler)
        except (ValueError, OSError):  # not the main thread; rely on KeyboardInterrupt
            continue
    try:
        while not stop.wait(0.5):
            pass
    finally:
        for signum, handler_before in previous.items():
            try:
                signal.signal(signum, handler_before)
            except (ValueError, OSError):
                continue


class DaemonLock:
    """Exclusive cross-process lock: one process at a time drives stages or touches worktrees.

    ``run`` holds it for its lifetime; the mutating subcommands hold it while they work,
    so a cron-driven ``once`` can never start a second implementer session in a worktree
    the daemon is using, and ``cleanup`` cannot delete a worktree under a live session.
    Implemented as ``flock`` on a file that records the holder's pid and command for the
    refusal message. Without ``fcntl`` (non-POSIX) the lock is a no-op.
    """

    def __init__(self, path: Path, *, now: Callable[[], str] = utc_now):
        self.path = path
        self._now = now
        self._handle: Any = None

    @property
    def held(self) -> bool:
        return self._handle is not None

    def acquire(self, command: str) -> "DaemonLock":
        """Take the lock or raise ``CodeFactoryError(code="daemon_running")``."""
        if self._handle is not None or fcntl is None:
            return self
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        handle = os.fdopen(os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600), "r+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            holder = self._describe_holder(handle)
            handle.close()
            raise CodeFactoryError(
                f"another herdr-code-factory process is running ({holder}); use the dashboard, "
                f"or stop it before running {command}",
                code="daemon_running",
            )
        try:
            handle.seek(0)
            handle.truncate()
            handle.write(json.dumps({"pid": os.getpid(), "command": command, "startedAt": self._now()}))
            handle.flush()
        except OSError:
            pass  # the lock is what matters; the holder note is best effort
        self._handle = handle
        return self

    def release(self) -> None:
        handle, self._handle = self._handle, None
        if handle is None:
            return
        try:
            handle.seek(0)
            handle.truncate()
            handle.flush()
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        finally:
            handle.close()

    @staticmethod
    def _describe_holder(handle: Any) -> str:
        try:
            handle.seek(0)
            info = json.loads(handle.read() or "{}")
        except (OSError, ValueError):
            info = {}
        if not isinstance(info, dict):
            info = {}
        pid = info.get("pid")
        command = info.get("command")
        parts = [f"pid {pid}" if isinstance(pid, int) and not isinstance(pid, bool) else "pid unknown"]
        if isinstance(command, str) and command.strip():
            parts.append(f"command {command.strip()[:40]}")
        return ", ".join(parts)


class Context:
    """Settings plus lazily constructed clients shared by the subcommands."""

    def __init__(self, settings: CodeFactorySettings, configuration: Configuration, deps: Dependencies):
        self.settings = settings
        self.configuration = configuration
        self.environ: dict[str, str] = dict(configuration.environ)
        self.deps = deps
        self.out: TextIO = deps.stdout or sys.stdout
        self.err: TextIO = deps.stderr or sys.stderr
        self._store: CodeFactoryStore | None = None
        self._github: GitHubClient | None = None
        self._git: GitRepository | None = None
        self._pi: PiRunner | None = None
        self._factory: Any = None
        self._daemon_lock: DaemonLock | None = None

    # -- output -------------------------------------------------------------------

    def log(self, message: str) -> None:
        print(f"[{self.deps.now()}] {message}", file=self.err, flush=True)

    def emit(self, payload: Any) -> None:
        print(json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=False), file=self.out, flush=True)

    # -- clients ------------------------------------------------------------------

    @property
    def store(self) -> CodeFactoryStore:
        if self._store is None:
            self._store = CodeFactoryStore(self.settings.state_path)
        return self._store

    @property
    def github(self) -> GitHubClient:
        if self._github is None:
            self._github = GitHubClient(self.settings.repository, runner=self.deps.runner, environ=self.environ)
        return self._github

    @property
    def git(self) -> GitRepository:
        if self._git is None:
            self._git = GitRepository(self.settings.validate_checkout(), runner=self.deps.runner, environ=self.environ)
        return self._git

    @property
    def pi(self) -> PiRunner:
        if self._pi is None:
            self._pi = PiRunner(self.settings.pi_binary, popen=self.deps.popen, environ=self.environ)
        return self._pi

    @property
    def factory(self) -> Any:
        if self._factory is None:
            builder = self.deps.factory_builder or _default_factory_builder
            self._factory = builder(self.settings, self.store, github=self.github, git=self.git, pi=self.pi, log=self.log)
        return self._factory

    @property
    def daemon_lock(self) -> DaemonLock:
        if self._daemon_lock is None:
            self._daemon_lock = DaemonLock(self.settings.state_path.parent / DAEMON_LOCK_NAME, now=self.deps.now)
        return self._daemon_lock

    def close(self) -> None:
        if self._daemon_lock is not None:
            self._daemon_lock.release()
            self._daemon_lock = None
        if self._store is not None:
            self._store.close()
            self._store = None


# -- helpers ------------------------------------------------------------------------


def _probe(runner: Runner, argv: Sequence[str], env: Mapping[str, str]) -> tuple[int, str, str]:
    """Run a diagnostic command; returns ``(returncode, stdout, stderr)`` (-1 when it could not run)."""
    try:
        result = runner(list(argv), capture_output=True, text=True, timeout=PROBE_TIMEOUT, env=dict(env))
    except (OSError, subprocess.TimeoutExpired) as exc:
        return -1, "", f"{argv[0]} could not run: {exc.__class__.__name__}"
    stdout = result.stdout if isinstance(result.stdout, str) else ""
    stderr = result.stderr if isinstance(result.stderr, str) else ""
    return int(result.returncode), stdout, stderr


def _last_line(*texts: str, limit: int = 200) -> str:
    for text in texts:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if lines:
            return lines[-1][:limit]
    return ""


def _issue_labels(issue: Mapping[str, Any]) -> list[str]:
    labels = issue.get("labels")
    if not isinstance(labels, list):
        return []
    return [item["name"] for item in labels if isinstance(item, dict) and isinstance(item.get("name"), str)]


def _runnable_issues(store: CodeFactoryStore) -> list[dict[str, Any]]:
    return [issue for issue in store.list_issues("active") if issue["stage"] not in RUNNABLE_EXCLUDED_STAGES]


def _release_pending(store: CodeFactoryStore) -> bool:
    return any(issue["stage"] == "release" for issue in store.list_issues("active"))


def _release_failure(result: Any) -> dict[str, Any] | None:
    """The error entry for a release batch result that reports ``ok: false`` (never raises)."""
    if not isinstance(result, dict) or result.get("ok") is not False:
        return None
    error = result.get("error")
    if not isinstance(error, str) or not error.strip():
        reason = result.get("reason")
        error = f"release batch did not run ({reason if isinstance(reason, str) and reason else 'unknown reason'})"
    entry: dict[str, Any] = {"error": error, "code": "release_failed"}
    if isinstance(result.get("tag"), str):
        entry["tag"] = result["tag"]
    return entry


def _reactivation_fields(existing: Mapping[str, Any]) -> tuple[dict[str, Any], str | None]:
    """Extra fields (and an event message) when re-enqueueing an issue whose worktree is gone.

    A skipped issue had its worktree and local branch removed; resuming it at its old
    stage would find no commits and dead-end in ``no_changes``. Restart implementation
    from the saved plan (or re-plan when the plan was never accepted). Once a pull
    request exists the branch history cannot be rebuilt, so that case is refused.
    """
    if not existing.get("worktreeCleaned") or existing["stage"] not in WORKTREE_STAGES:
        return {}, None
    number = existing["number"]
    if existing.get("prNumber"):
        raise CodeFactoryError(
            f"issue #{number} is {existing['status']} after PR #{existing['prNumber']} was opened and its worktree "
            "and branch are gone; finish or close that pull request by hand instead of enqueueing the issue again",
            code="invalid_request",
        )
    fields: dict[str, Any] = {"finishedAt": None, "headSha": None, "ciStatus": None}
    plan = existing.get("planJson")
    if existing["stage"] != "plan" and isinstance(plan, dict) and isinstance(plan.get("tasks"), list) and plan["tasks"]:
        plan = dict(plan)
        plan.pop("progress", None)
        fields.update(stage="implement", planJson=plan)
        return fields, "Re-enqueued after the worktree was removed; implementation restarts from the saved plan"
    fields.update(stage="worktree", planJson=None)
    return fields, "Re-enqueued after the worktree was removed; restarting from the worktree stage"


def _stop_factory(ctx: Context, factory: Any) -> None:
    """Stop the pipeline and wait (bounded) for running stages so their ledger writes land."""
    limit = ctx.settings.session_timeout_seconds + SHUTDOWN_GRACE_SECONDS
    if not factory.wait_idle(timeout=0):
        ctx.log(f"waiting for running stages to finish their current step (up to {limit} s)")
    factory.stop(wait=True, timeout=limit)
    if not factory.wait_idle(timeout=0):
        ctx.log("warning: stages are still running after the shutdown grace period; their ledger updates may be lost")


# -- subcommands --------------------------------------------------------------------


def cmd_run(ctx: Context, args: argparse.Namespace) -> int:
    settings = ctx.settings
    settings.validate_checkout()
    ctx.daemon_lock.acquire("run")
    store = ctx.store
    factory = ctx.factory
    dashboard: DashboardServer | None = None
    try:
        if not args.no_dashboard:
            host = resolve_dashboard_host(settings.dashboard_host, runner=ctx.deps.runner, log=ctx.log, environ=ctx.environ)
            builder = ctx.deps.dashboard_builder or DashboardServer
            dashboard = builder(
                store, factory, host=host, port=settings.dashboard_port, token=settings.dashboard_token,
                settings=settings, log=ctx.log, allowed_hosts=(settings.dashboard_host,),
            )
            dashboard.start()
            # ``dashboard_url`` is the key the pipeline publishes in issue comments. The daemon's
            # address is private (tailnet or loopback), so it is recorded under ``dashboard_bind_url``
            # for ``status`` and the page, and never under the published key.
            store.set_daemon("dashboard_bind_url", dashboard.url)
        else:
            store.set_daemon("dashboard_bind_url", None)
        store.set_daemon("dashboard_url", None)
        print(f"Herdr Code Factory: {settings.repository}", file=ctx.out, flush=True)
        print(f"Dashboard:  {dashboard.url if dashboard else 'disabled (--no-dashboard)'}", file=ctx.out, flush=True)
        print(f"Planner:    {settings.planner_model} ({settings.planner_thinking})", file=ctx.out, flush=True)
        print(f"Implementer: {settings.implementer_model} ({settings.implementer_thinking})", file=ctx.out, flush=True)
        if dashboard and not settings.dashboard_token:
            print("warning: code_factory.dashboard_token is empty; anyone who can reach the dashboard can trigger actions",
                  file=ctx.err, flush=True)
        factory.start()
        store.set_daemon("started_at", ctx.deps.now())
        try:
            (ctx.deps.wait or wait_for_shutdown_signal)()
        except KeyboardInterrupt:
            pass
        finally:
            ctx.log("shutting down")
            _stop_factory(ctx, factory)
    finally:
        if dashboard is not None:
            dashboard.stop()
    return 0


def cmd_once(ctx: Context, args: argparse.Namespace) -> int:
    ctx.settings.validate_checkout()
    ctx.daemon_lock.acquire("once")
    factory = ctx.factory
    counts = factory.poll_once()
    processed: list[int] = []
    errors: list[dict[str, Any]] = []
    for issue in _runnable_issues(ctx.store):
        number = int(issue["number"])
        try:
            factory.run_issue(number)
            processed.append(number)
        except CodeFactoryError as exc:
            errors.append({"number": number, "error": str(exc), "code": exc.code})
    release_batch = False
    release: dict[str, Any] | None = None
    if ctx.settings.release_enabled and _release_pending(ctx.store):
        release_batch = True
        try:
            result = factory.run_release_batch()
        except CodeFactoryError as exc:
            errors.append({"release": True, "error": str(exc), "code": exc.code})
        else:
            release = result if isinstance(result, dict) else None
            failure = _release_failure(release)
            if failure is not None:
                errors.append({"release": True, **failure})
    ctx.emit({"ok": not errors, "poll": counts, "processed": processed, "releaseBatch": release_batch,
              "release": release, "errors": errors})
    return 0 if not errors else 1


def cmd_status(ctx: Context, args: argparse.Namespace) -> int:
    if args.issue is not None:
        detail = ctx.store.issue_detail(args.issue)
        if detail is None:
            raise CodeFactoryError(f"issue #{args.issue} is not tracked", code="not_found")
        ctx.emit(detail)
        return 0
    ctx.emit(ctx.store.snapshot())
    return 0


def cmd_enqueue(ctx: Context, args: argparse.Namespace) -> int:
    number = int(args.number)
    if not args.queue_only:
        ctx.settings.validate_checkout()
        ctx.daemon_lock.acquire("enqueue (use --queue-only to record the issue for the daemon)")
    issue = ctx.github.get_issue(number)
    state = str(issue.get("state") or "").upper()
    if state != "OPEN":
        raise CodeFactoryError(
            f"issue #{number} is {state.lower() or 'in an unknown state'}; only open issues can be enqueued",
            code="invalid_request",
        )
    labels = _issue_labels(issue)
    author = issue.get("author")
    login = author.get("login") if isinstance(author, dict) and isinstance(author.get("login"), str) else None
    store = ctx.store
    existing = store.get_issue(number)
    if existing is not None and existing["status"] == "done":
        raise CodeFactoryError(f"issue #{number} is already done; it cannot be enqueued again", code="invalid_request")
    record: dict[str, Any] = {
        "number": number,
        "title": str(issue.get("title") or ""),
        "kind": "feature" if "enhancement" in labels else "bug",
        "author": login,
        "url": str(issue.get("url") or "") or None,
        "labels": labels,
    }
    restart_message: str | None = None
    if existing is not None and existing["status"] != "active":
        record.update({"status": "active", "error": None, "blockedReason": None})
        restart_fields, restart_message = _reactivation_fields(existing)
        record.update(restart_fields)
    tracked = store.upsert_issue(record)
    store.add_event(number, tracked["stage"], "info", "Enqueued manually with herdr-code-factory enqueue")
    if restart_message:
        store.add_event(number, tracked["stage"], "warning", restart_message)
    processed = False
    if not args.queue_only:
        ctx.factory.run_issue(number)
        processed = True
    ctx.emit({"ok": True, "processed": processed, "issue": store.get_issue(number)})
    return 0


def cmd_action(ctx: Context, args: argparse.Namespace) -> int:
    number = int(args.number)
    if ctx.store.get_issue(number) is None:
        raise CodeFactoryError(f"issue #{number} is not tracked", code="not_found")
    ctx.settings.validate_checkout()
    ctx.daemon_lock.acquire(f"action {number} {args.action}")
    result = ctx.factory.action(number, args.action)
    payload: dict[str, Any] = {"ok": True, "action": args.action}
    if args.action == "retry":
        # Without a running worker pool the pipeline only re-activates the issue; process it here
        # (``enqueue`` semantics) so the CLI never reports a retry that nothing will pick up.
        queued = bool(result.get("queued")) if isinstance(result, dict) else False
        issue = ctx.store.get_issue(number)
        processed = False
        if not queued and issue is not None and issue["status"] == "active" and issue["stage"] not in RUNNABLE_EXCLUDED_STAGES:
            ctx.factory.run_issue(number)
            processed = True
        payload["processed"] = processed
    payload["issue"] = ctx.store.get_issue(number)
    ctx.emit(payload)
    return 0


def cmd_release_now(ctx: Context, args: argparse.Namespace) -> int:
    ctx.settings.validate_checkout()
    ctx.daemon_lock.acquire("release-now")
    result = ctx.factory.run_release_batch()
    release = result if isinstance(result, dict) else None
    failure = _release_failure(release)
    payload: dict[str, Any] = {"ok": failure is None, "action": "release_now", "result": release}
    if failure is not None:
        payload["error"] = failure
    ctx.emit(payload)
    return 0 if failure is None else 1


def cmd_cleanup(ctx: Context, args: argparse.Namespace) -> int:
    git = ctx.git
    ctx.daemon_lock.acquire("cleanup")
    store = ctx.store
    removed: list[int] = []
    failed: list[dict[str, Any]] = []
    for status in ("done", "skipped"):
        for issue in store.list_issues(status):
            number = int(issue["number"])
            if not issue.get("worktreePath") or issue.get("worktreeCleaned"):
                continue
            try:
                git.remove_worktree(issue["worktreePath"])
                if issue.get("branch"):
                    git.delete_branch(issue["branch"])
                store.update_issue(number, worktreeCleaned=True)
                store.add_event(number, issue["stage"], "info", "Worktree removed by herdr-code-factory cleanup")
                removed.append(number)
            except CodeFactoryError as exc:
                store.add_event(number, issue["stage"], "warning", f"Worktree cleanup failed: {exc}")
                failed.append({"number": number, "error": str(exc), "code": exc.code})
    git.prune_worktrees()
    ctx.emit({"ok": not failed, "removed": removed, "failed": failed})
    return 0 if not failed else 1


def doctor_checks(ctx: Context, *, fix: bool = False) -> list[dict[str, Any]]:
    """Run every environment check; each entry is ``{"check", "ok", "detail"}`` (+ ``"warning"``)."""
    settings = ctx.settings
    deps = ctx.deps
    checks: list[dict[str, Any]] = []

    def add(check: str, ok: bool, detail: str, *, warning: bool = False) -> None:
        entry: dict[str, Any] = {"check": check, "ok": bool(ok), "detail": detail[:500]}
        if warning:
            entry["warning"] = True
        checks.append(entry)

    add("repository", True, f"{settings.repository} (trigger label {settings.trigger_label!r})")

    try:
        checkout = settings.validate_checkout()
        remote = ctx.git.remote_url("origin")
        matches = settings.repository.lower() in remote.lower()
        add("checkout", matches, f"{checkout} → origin {remote or '(no url)'}" if matches
            else f"origin of {checkout} is {remote or '(no url)'}, expected {settings.repository}")
    except CodeFactoryError as exc:
        add("checkout", False, str(exc))

    gh_env = ctx.github.environment()
    code, out, err = _probe(deps.runner, ["gh", "auth", "status"], gh_env)
    add("gh_auth", code == 0, _last_line(err, out) or ("authenticated" if code == 0 else f"exit status {code}"))

    code, out, err = _probe(deps.runner, ["gh", "label", "list", "--repo", settings.repository, "--json", "name",
                                          "--limit", "200"], gh_env)
    if code != 0:
        add("labels", False, _last_line(err, out) or f"gh label list failed with exit status {code}")
    else:
        try:
            payload = json.loads(out or "[]")
        except json.JSONDecodeError:
            payload = None
        names = {item.get("name") for item in payload if isinstance(item, dict)} if isinstance(payload, list) else set()
        missing = [name for name, _, _ in REQUIRED_LABELS if name not in names]
        created: list[str] = []
        label_error: str | None = None
        if missing and fix:
            for name, color, description in REQUIRED_LABELS:
                if name in missing:
                    try:
                        ctx.github.ensure_label(name, color, description)
                        created.append(name)
                    except CodeFactoryError as exc:
                        label_error = f"could not create {name}: {exc}"
                        break
            missing = [name for name in missing if name not in created]
        if label_error:
            add("labels", False, label_error + (f" (created: {', '.join(created)})" if created else ""))
        elif missing:
            add("labels", False, "missing labels: " + ", ".join(missing) + " (run doctor --fix to create them)")
        elif created:
            add("labels", True, "created labels: " + ", ".join(created))
        else:
            add("labels", True, "all labels present: " + ", ".join(name for name, _, _ in REQUIRED_LABELS))

    pi_env = ctx.pi.environment()
    code, out, err = _probe(deps.runner, [settings.pi_binary, "--version"], pi_env)
    add("pi_binary", code == 0, _last_line(out, err) or (f"{settings.pi_binary} answered" if code == 0 else f"exit status {code}"))

    for role, model in (("planner_model", settings.planner_model), ("implementer_model", settings.implementer_model)):
        code, out, err = _probe(deps.runner, [settings.pi_binary, "--list-models", model], pi_env)
        listed = code == 0 and model in out
        add(role, listed, f"{model} is available" if listed else f"{model} not found in pi --list-models output"
            + (f" ({_last_line(err)})" if code != 0 and _last_line(err) else ""))

    if settings.implementer_model.startswith(OLLAMA_PREFIX):
        present = bool((ctx.environ.get("OLLAMA_API_KEY") or "").strip())
        add("ollama_api_key", present, "OLLAMA_API_KEY is set" if present
            else "OLLAMA_API_KEY is not set; ollama-cloud sessions will fail to authenticate", warning=not present)

    if settings.release_enabled:
        deployment = ctx.configuration.section("deployment")
        macos = deployment.get("macos_release") if isinstance(deployment, dict) else None
        present = isinstance(macos, dict) and bool(macos)
        add("macos_release", present, "[deployment.macos_release] is configured" if present
            else "release_enabled is true but [deployment.macos_release] is missing from the configuration")
    else:
        add("macos_release", True, "releases are disabled")

    if settings.dashboard_host.strip().lower() == "tailscale":
        address, detail = tailscale_ipv4(deps.runner, environ=ctx.environ)
        add("dashboard_host", address is not None, detail if address is not None
            else f"tailscale could not be resolved ({detail}); the daemon will bind 127.0.0.1")
    else:
        resolvable = host_resolves(settings.dashboard_host)
        add("dashboard_host", resolvable, f"{settings.dashboard_host} resolves" if resolvable
            else f"{settings.dashboard_host} does not resolve")

    root = settings.worktree_root
    try:
        root.mkdir(parents=True, exist_ok=True)
        writable = os.access(root, os.W_OK)
        usage = deps.disk_usage(str(root))
        free = int(getattr(usage, "free", 0))
        free_gib = free / (1024 ** 3)
        ok = writable and free >= MIN_FREE_BYTES
        add("worktree_root", ok, f"{root} writable={'yes' if writable else 'no'} free={free_gib:.1f} GiB"
            + ("" if free >= MIN_FREE_BYTES else " (need at least 5 GiB)"))
    except OSError as exc:
        add("worktree_root", False, f"{root}: {exc.__class__.__name__}: {exc}")
    return checks


def cmd_doctor(ctx: Context, args: argparse.Namespace) -> int:
    checks = doctor_checks(ctx, fix=bool(args.fix))
    failures = [check for check in checks if not check["ok"] and not check.get("warning")]
    warnings = [check for check in checks if not check["ok"] and check.get("warning")]
    ctx.emit({"ok": not failures, "failures": len(failures), "warnings": len(warnings), "checks": checks})
    return 0 if not failures else 1


# -- argument parsing -----------------------------------------------------------------


def _positive_int(value: str) -> int:
    try:
        number = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="herdr-code-factory",
        description="Automated GitHub issue → worktree → pull request → release pipeline for Herdr.",
        allow_abbrev=False,
    )
    parser.add_argument("--config", help="Private cluster TOML file (env: HERDR_CONFIG)")
    parser.add_argument("--machine", help="Machine ID in the cluster file (env: HERDR_MACHINE)")
    commands = parser.add_subparsers(dest="command", metavar="command", required=True)

    run = commands.add_parser("run", help="start the daemon and the dashboard until SIGINT/SIGTERM")
    run.add_argument("--no-dashboard", action="store_true", help="do not serve the dashboard")
    run.set_defaults(handler=cmd_run)

    once = commands.add_parser("once", help="poll once and process every runnable issue synchronously")
    once.set_defaults(handler=cmd_once)

    status = commands.add_parser("status", help="print the ledger snapshot as JSON")
    status.add_argument("--issue", type=_positive_int, metavar="N", help="print one issue with its events and sessions")
    status.set_defaults(handler=cmd_status)

    enqueue = commands.add_parser("enqueue", help="track an open issue manually, bypassing the label filter")
    enqueue.add_argument("number", type=_positive_int, metavar="N")
    enqueue.add_argument("--queue-only", action="store_true", help="record the issue without processing it")
    enqueue.set_defaults(handler=cmd_enqueue)

    action = commands.add_parser("action", help="retry, skip or clean up one issue")
    action.add_argument("number", type=_positive_int, metavar="N")
    action.add_argument("action", choices=ISSUE_ACTIONS)
    action.set_defaults(handler=cmd_action)

    release_now = commands.add_parser("release-now", help="start a release batch when one is not running")
    release_now.set_defaults(handler=cmd_release_now)

    cleanup = commands.add_parser("cleanup", help="remove worktrees of finished issues and prune git bookkeeping")
    cleanup.set_defaults(handler=cmd_cleanup)

    doctor = commands.add_parser("doctor", help="check gh, labels, Pi, models, releases, dashboard host and disk")
    doctor.add_argument("--fix", action="store_true", help="create missing GitHub labels")
    doctor.set_defaults(handler=cmd_doctor)
    return parser


def main(argv: Sequence[str] | None = None, *, environ: Mapping[str, str] | None = None,
         deps: Dependencies | None = None) -> int:
    """Entry point registered as ``herdr-code-factory``; returns the process exit status."""
    deps = deps or Dependencies()
    err = deps.stderr or sys.stderr
    parser = build_parser()
    try:
        args = parser.parse_args(list(argv) if argv is not None else None)
    except SystemExit as exc:
        code = exc.code
        return code if isinstance(code, int) else (0 if code is None else 2)
    try:
        configuration = load_configuration(args.config, args.machine, environ=environ if environ is not None else os.environ)
    except ConfigurationError as exc:
        print(f"error: {exc}", file=err, flush=True)
        return 2
    try:
        settings = CodeFactorySettings.from_environ(configuration.environ)
    except CodeFactoryError as exc:
        print(f"error: {exc}", file=err, flush=True)
        return 2
    context = Context(settings, configuration, deps)
    try:
        return int(args.handler(context, args))
    except CodeFactoryError as exc:
        print(f"error: {exc}", file=err, flush=True)
        return 1
    except KeyboardInterrupt:
        return 130
    finally:
        context.close()


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
