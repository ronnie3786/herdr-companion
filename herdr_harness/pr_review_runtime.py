"""PR-review orchestration, kept separate from HTTP and persistence.

This worker uses the same child-environment discipline as agent runs.  In
particular, neither GitHub nor terminal agents inherit Herdr control tokens.
"""
from __future__ import annotations

import base64
import contextlib
import fcntl
import hashlib
import html
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Callable, Iterator, Mapping
from urllib.parse import urlsplit

from .agent_runs import _assistant_text, _child_path
from .child_environment import agent_environment
from .normalization import pane_index
from .pr_review_diff import line_window, parse_unified_diff
from .pr_review_store import PRReviewError


MAX_DIFF_BYTES = 8 * 1024 * 1024
MAX_FILE_BYTES = 512 * 1024
MAX_DOCUMENT_BYTES = 2 * 1024 * 1024 * 1024
MAX_UPLOAD_BYTES = 20 * 1024 * 1024
MAX_FINDINGS_DOCUMENT_BYTES = 4 * 1024 * 1024
ALLOWED_EXTENSIONS = frozenset({".md", ".markdown", ".txt", ".html", ".htm", ".json", ".pdf", ".mp3", ".wav", ".m4a", ".aac", ".mp4", ".mov", ".m4v", ".webm", ".png", ".jpg", ".jpeg", ".gif", ".svg"})
_PR_PATH = re.compile(r"^/([^/]+)/([^/]+)/pull/(\d+)(?:/.*)?$")


@dataclass
class PRReviewDocumentContent:
    """A validated private document handle for the HTTP streaming handler."""

    document: dict[str, Any]
    handle: BinaryIO
    byte_size: int
    media_type: str

    def __enter__(self) -> "PRReviewDocumentContent":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.handle.close()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _bounded_int(environ: Mapping[str, str], name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return value if minimum <= value <= maximum else default


def _enabled(environ: Mapping[str, str], name: str, default: bool) -> bool:
    value = environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _trim_error(value: object, fallback: str) -> str:
    text = str(value or "").strip()
    return (text or fallback)[:300]


def _resolve_binary(environ: Mapping[str, str], override_name: str, executable: str) -> str | None:
    override = environ.get(override_name)
    if override:
        candidate = Path(override).expanduser()
        try:
            candidate = candidate.resolve()
        except OSError:
            return None
        return str(candidate) if candidate.exists() and os.access(candidate, os.X_OK) else None
    resolved = shutil.which(executable, path=environ.get("PATH"))
    if resolved:
        return resolved
    for value in (f"~/.npm-global/bin/{executable}", f"/opt/homebrew/bin/{executable}", f"/usr/local/bin/{executable}", f"~/.local/bin/{executable}"):
        candidate = Path(value).expanduser()
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _run_process_group(argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess:
    """Bound the whole command, including Git children launched by gh."""
    timeout = kwargs.pop("timeout", None)
    data = kwargs.pop("input", None)
    if kwargs.pop("capture_output", False):
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if data is not None:
        kwargs["stdin"] = subprocess.PIPE
    with subprocess.Popen(argv, start_new_session=True, **kwargs) as process:
        try:
            stdout, stderr = process.communicate(input=data, timeout=timeout)
        except BaseException:
            # Killing only gh leaves its clone/fetch children writing into the
            # checkout after the review reports failure.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def parse_pr_url(url: str) -> dict[str, Any]:
    value = url if "://" in url else f"https://{url}"
    parsed = urlsplit(value)
    match = _PR_PATH.match(parsed.path)
    if parsed.scheme not in {"https", "http"} or parsed.hostname != "github.com" or match is None:
        raise PRReviewError("Use a GitHub pull request URL", code="invalid_pr_url", status=400)
    owner, repo, number = match.groups()
    return {"url": f"https://github.com/{owner}/{repo}/pull/{number}", "host": "github.com", "owner": owner, "repo": repo, "number": int(number)}


class PRReviewRuntime:
    def __init__(self, service: Any, store: Any, *, environ: Mapping[str, str], runtime_root: str | Path | None = None, runner: Callable[..., Any] = _run_process_group, popen: Callable[..., Any] = subprocess.Popen) -> None:
        self.service = service
        self.store = store
        self.environ = dict(environ)
        self.runs_root = Path(runtime_root or self.environ.get("HERDR_HARNESS_PR_REVIEW_RUNS_ROOT") or ".").resolve()
        self.runs_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.checkout_root = Path(self.environ.get("HERDR_PR_REVIEW_CHECKOUT_ROOT") or self.runs_root / "checkouts").resolve()
        self.workspace_label = self.environ.get("HERDR_PR_REVIEW_WORKSPACE_LABEL", "PR Reviews")
        self.workspace_root = Path(self.environ.get("HERDR_PR_REVIEW_WORKSPACE_ROOT") or self.runs_root).resolve()
        self.runner = runner
        self.popen = popen
        self.gh_timeout_seconds = _bounded_int(self.environ, "HERDR_PR_REVIEW_GH_TIMEOUT_SECONDS", 120, 10, 900)
        self.checkout_timeout_seconds = _bounded_int(self.environ, "HERDR_PR_REVIEW_CHECKOUT_TIMEOUT_SECONDS", 900, 10, 3600)
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None
        self._manager_lock: Any = None
        self._lock = threading.RLock()
        self._processes: dict[str, tuple[Any, Any]] = {}
        self._preparing_reviews: set[str] = set()
        self._checkout_locks: dict[str, threading.Lock] = {}
        self._last_heavy_scan = 0.0

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        handle = (self.runs_root / "manager.lock").open("a")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            return
        self._manager_lock = handle
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="pr-review-runtime", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
        if self._manager_lock is not None:
            self._manager_lock.close()
            self._manager_lock = None

    def wake(self) -> None:
        self._wake.set()

    def _loop(self) -> None:
        # Preparation runs in a process-local thread. Its durable review and
        # selected runs survive a restart, so give interrupted work a new worker.
        for review in self.store.list_reviews("active"):
            if self._stop.is_set():
                return
            self._schedule_preparation(review["id"])
        while not self._stop.is_set():
            try:
                self.reconcile()
            except Exception:
                pass
            self._wake.wait(2)
            self._wake.clear()

    def _child_environment(self, *, pi_bin: str | None = None) -> dict[str, str]:
        environment = agent_environment(self.environ, integration=False)
        if pi_bin:
            environment["PI_SKIP_VERSION_CHECK"] = "1"
            environment["PATH"] = _child_path(pi_bin, environment.get("PATH"))
        return environment

    def _run(self, argv: list[str], *, cwd: Path | None = None, timeout: int | None = None, kind: str = "git", input: str | None = None) -> Any:
        timeout = self.gh_timeout_seconds if timeout is None and kind == "gh" else timeout or 120
        try:
            result = self.runner(argv, capture_output=True, text=False, timeout=timeout, cwd=str(cwd) if cwd else None, env=self._child_environment(), input=input.encode("utf-8") if input is not None else None)
        except (OSError, subprocess.TimeoutExpired) as exc:
            code = "github_failed" if kind == "gh" else "git_failed"
            raise PRReviewError(f"{kind} command failed", code=code, status=502) from exc
        result.stdout = self._decode_output(getattr(result, "stdout", ""))
        result.stderr = self._decode_output(getattr(result, "stderr", ""))
        if getattr(result, "returncode", 0):
            code = "github_failed" if kind == "gh" else "git_failed"
            raise PRReviewError(_trim_error(getattr(result, "stderr", ""), f"{kind} command failed"), code=code, status=502)
        return result

    @staticmethod
    def _decode_output(value: str | bytes | None) -> str:
        return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value or "")

    def capabilities(self) -> dict[str, Any]:
        runner = self.environ.get("HERDR_PR_REVIEW_RUNNER", "pi")
        override_name = {"pi": "HERDR_PR_REVIEW_PI_BIN", "claude": "HERDR_PR_REVIEW_CLAUDE_BIN"}.get(runner)
        runner_bin = _resolve_binary(self.environ, override_name, runner) if override_name else None
        pi_bin = _resolve_binary(self.environ, "HERDR_PR_REVIEW_PI_BIN", "pi")
        gh_bin = shutil.which("gh", path=self.environ.get("PATH"))
        reason = ""
        if not gh_bin:
            reason = "The gh CLI is not installed"
        elif runner not in {"pi", "claude"}:
            reason = "The configured PR review runner is unsupported"
        elif not runner_bin:
            reason = "The configured PR review runner is not installed"
        return {"available": bool(gh_bin and runner_bin and runner in {"pi", "claude"}), "gh_available": bool(gh_bin), "runner": runner, "runner_available": bool(runner_bin), "pi_available": bool(pi_bin), "workspace_label": self.workspace_label, "checkout_root": str(self.checkout_root), "auto_rank": _enabled(self.environ, "HERDR_PR_REVIEW_AUTO_RANK", True), "sync_viewed_to_github": _enabled(self.environ, "HERDR_PR_REVIEW_SYNC_VIEWED", True), "reason": reason}

    def _review_dir(self, review_id: str) -> Path:
        return self.runs_root / "reviews" / review_id

    def _review_worktree(self, review_id: str) -> Path:
        return self.checkout_root / "reviews" / review_id

    def _checkout_lock(self, review: Mapping[str, Any]) -> threading.Lock:
        key = f"{review['owner']}/{review['repo']}"
        with self._lock:
            return self._checkout_locks.setdefault(key, threading.Lock())

    @staticmethod
    def _quarantine_incomplete_checkout(path: Path) -> Path | None:
        """Preserve a non-checkout path beside its managed destination."""
        if not path.is_symlink() and (not path.exists() or (path / ".git").exists()):
            return None
        while True:
            quarantine = path.with_name(f".{path.name}.incomplete-{time.time_ns()}-{os.urandom(4).hex()}")
            if not quarantine.exists() and not quarantine.is_symlink():
                path.rename(quarantine)
                return quarantine

    def create_review(self, url: str, request_id: str, skill_ids: list[str] | None = None, actor: str = "") -> dict[str, Any]:
        review = self.store.create_review(parse_pr_url(url) | {"request_id": request_id})
        for skill_id in skill_ids or []:
            if review["status"] == "ready":
                self.start_run(review["id"], skill_id, f"{request_id}:{skill_id}", actor)
            elif not any(run["skill_id"] == skill_id for run in self.store.runs_for_review(review["id"])):
                self.store.queue_run(review["id"], skill_id, f"{request_id}:{skill_id}", actor)
        self._schedule_preparation(review["id"])
        return review

    def _schedule_preparation(self, review_id: str) -> None:
        with self._lock:
            # Receipts and startup snapshots can predate completion or archival.
            review = self.store.get_review(review_id, True)
            if (review["status"] != "preparing" or review.get("prepared_at") is not None
                    or review.get("archived_at") is not None or review_id in self._preparing_reviews):
                return
            self._preparing_reviews.add(review_id)
            try:
                threading.Thread(target=self._prepare_once, args=(review_id,), daemon=True).start()
            except Exception:
                self._preparing_reviews.discard(review_id)
                raise

    def _prepare_once(self, review_id: str) -> None:
        try:
            self.prepare(review_id)
        finally:
            with self._lock:
                self._preparing_reviews.discard(review_id)

    def _write_json(self, path: Path, value: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(path, 0o600)

    def _metadata(self, review: Mapping[str, Any], directory: Path) -> dict[str, Any]:
        fields = "number,url,state,title,body,author,baseRefName,headRefName,headRefOid,baseRefOid,isDraft,mergedAt,updatedAt,additions,deletions,changedFiles,files,id"
        result = self._run(["gh", "pr", "view", str(review["number"]), "--repo", f"{review['owner']}/{review['repo']}", "--json", fields], kind="gh")
        try:
            metadata = json.loads(result.stdout)
        except (TypeError, json.JSONDecodeError) as exc:
            raise PRReviewError("GitHub returned invalid PR metadata", code="github_failed", status=502) from exc
        self._write_json(directory / "pr.json", metadata)
        return metadata

    def _checkout(self, review: Mapping[str, Any], metadata: Mapping[str, Any]) -> tuple[Path, str]:
        clone = self.checkout_root / "repos" / f"{review['owner']}__{review['repo']}"
        worktree = self._review_worktree(str(review["id"]))
        base_ref = str(metadata.get("baseRefName") or review.get("base_ref") or "")
        head_sha = str(metadata.get("headRefOid") or review.get("head_sha") or "")
        if not base_ref or not head_sha:
            raise PRReviewError("GitHub PR metadata is incomplete", code="github_failed", status=502)
        with self._checkout_lock(review):
            clone.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._quarantine_incomplete_checkout(clone)
            if not clone.exists():
                try:
                    self._run(["gh", "repo", "clone", f"{review['owner']}/{review['repo']}", str(clone), "--", "--quiet", "--filter=blob:none", "--no-checkout"], timeout=self.checkout_timeout_seconds, kind="gh")
                except Exception:
                    self._quarantine_incomplete_checkout(clone)
                    raise
            self._run(["git", "-C", str(clone), "fetch", "--quiet", "origin"], timeout=self.checkout_timeout_seconds, kind="git")
            self._run(["git", "-C", str(clone), "fetch", "--quiet", "origin", f"pull/{review['number']}/head:refs/herdr-pr/{review['number']}"], timeout=self.checkout_timeout_seconds, kind="git")
            worktree.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._quarantine_incomplete_checkout(worktree)
            if worktree.exists():
                self._run(["git", "-C", str(worktree), "checkout", "--detach", head_sha], timeout=self.checkout_timeout_seconds, kind="git")
            else:
                # A timed-out worktree add may leave an administrative entry
                # after its incomplete directory is quarantined.
                self._run(["git", "-C", str(clone), "worktree", "prune", "--expire", "now"], timeout=self.checkout_timeout_seconds, kind="git")
                self._run(["git", "-C", str(clone), "worktree", "add", "--detach", str(worktree), head_sha], timeout=self.checkout_timeout_seconds, kind="git")
            merge_base = self._run(["git", "-C", str(worktree), "merge-base", f"origin/{base_ref}", head_sha], kind="git").stdout.strip()
        if not merge_base:
            raise PRReviewError("Git could not find a merge base", code="git_failed", status=502)
        return worktree, merge_base

    def _diff(self, review: Mapping[str, Any], worktree: Path, merge_base: str, head_sha: str, directory: Path) -> list[dict[str, Any]]:
        result = self._run(["git", "-C", str(worktree), "diff", "-M", "--no-color", merge_base, head_sha], kind="git")
        raw = (result.stdout or "").encode("utf-8", "replace")
        truncated = len(raw) > MAX_DIFF_BYTES
        patch = raw[:MAX_DIFF_BYTES].decode("utf-8", "ignore")
        patch_path = directory / "diff.patch"
        patch_path.write_text(patch, encoding="utf-8")
        os.chmod(patch_path, 0o600)
        files = parse_unified_diff(patch, truncated=truncated)
        self._write_json(directory / "diff.json", {"truncated": truncated, "files": files})
        self.store.upsert_files(str(review["id"]), files)
        return files

    def _native(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        result = self.service.invoke(method, params)
        return result.get("result", result) if isinstance(result, dict) else {}

    def _workspace(self, review: Mapping[str, Any], metadata: Mapping[str, Any], worktree: Path) -> tuple[str | None, str | None, str | None, str | None]:
        try:
            with self.service._quick_session_lock:
                snapshot = self.service.refresh_snapshot(force=True)
                workspace = self.service._quick_exact_workspace(snapshot, self.workspace_label)
                if workspace is None:
                    response = self._native("workspace.create", {"label": self.workspace_label, "cwd": str(self.workspace_root), "focus": False})
                    before_workspaces = {str(item.get("workspace_id")) for item in snapshot.get("workspaces", []) if isinstance(item, dict)}
                    before_tabs = {str(item.get("tab_id")) for item in snapshot.get("tabs", []) if isinstance(item, dict)}
                    before_panes = {str(item.get("pane_id")) for item in snapshot.get("panes", []) if isinstance(item, dict)}
                    workspace_id, _, _ = self.service._quick_created_workspace_ids(response, before_workspace_ids=before_workspaces, before_tab_ids=before_tabs, before_pane_ids=before_panes, desired_label=self.workspace_label)
                else:
                    workspace_id = str(workspace["workspace_id"])
                snapshot = self.service.refresh_snapshot(force=True)
                title = str(metadata.get("title") or "")[:60]
                label = f"PR #{review['number']} · {title}".rstrip(" ·")
                before_tabs = {str(item.get("tab_id")) for item in snapshot.get("tabs", []) if isinstance(item, dict)}
                before_panes = {str(item.get("pane_id")) for item in snapshot.get("panes", []) if isinstance(item, dict)}
                created = self._native("tab.create", {"workspace_id": workspace_id, "cwd": str(worktree), "focus": False, "label": label, "env": {"HERDR_PR_REVIEW_ID": review["id"], "HERDR_PR_REVIEW_URL": review["url"]}})
                tab_id, pane_id = self.service._quick_created_tab_ids(created, workspace_id=workspace_id, before_tab_ids=before_tabs, before_pane_ids=before_panes)
                return workspace_id, tab_id, pane_id, None
        except Exception as exc:
            return None, None, None, _trim_error(exc, "Could not create PR review workspace")

    def _pull_viewed(self, review: Mapping[str, Any]) -> list[str]:
        cursor: str | None = None
        viewed: list[str] = []
        query = "query($owner:String!,$repo:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){files(first:100,after:$cursor){nodes{path viewerViewedState} pageInfo{hasNextPage endCursor}}}}}"
        while True:
            command = ["gh", "api", "graphql", "-f", f"query={query}", "-f", f"owner={review['owner']}", "-f", f"repo={review['repo']}", "-F", f"number={review['number']}"]
            if cursor is not None:
                command.extend(["-f", f"cursor={cursor}"])
            result = self._run(command, kind="gh")
            try:
                payload = json.loads(result.stdout)
                files = payload["data"]["repository"]["pullRequest"]["files"]
            except (KeyError, TypeError, json.JSONDecodeError) as exc:
                raise PRReviewError("GitHub returned invalid viewed-file data", code="github_failed", status=502) from exc
            viewed.extend(str(node["path"]) for node in files.get("nodes", []) if node.get("viewerViewedState") == "VIEWED")
            page = files.get("pageInfo") or {}
            if not page.get("hasNextPage"):
                break
            cursor = page.get("endCursor")
        paths = {item["path"] for item in self.store.files(str(review["id"]))}
        matching = [path for path in viewed if path in paths]
        if matching:
            self.store.set_viewed(str(review["id"]), matching, True, f"github-pull:{int(time.time() * 1000)}", source="github")
        return matching

    def prepare(self, review_id: str, *, refresh: bool = False) -> None:
        review = self.store.get_review(review_id, True)
        directory = self._review_dir(review_id)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        stage = "metadata"
        try:
            metadata = self._metadata(review, directory)
            stage = "checkout"
            worktree, merge_base = self._checkout(review, metadata)
            stage = "diff"
            files = self._diff(review, worktree, merge_base, str(metadata["headRefOid"]), directory)
            stage = "workspace"
            workspace_id = tab_id = anchor_pane_id = None
            workspace_error = review.get("workspace_error")
            if not refresh and all(review.get(key) for key in ("workspace_id", "tab_id", "anchor_pane_id")):
                workspace_id, tab_id, anchor_pane_id = (review[key] for key in ("workspace_id", "tab_id", "anchor_pane_id"))
            elif not refresh:
                workspace_id, tab_id, anchor_pane_id, workspace_error = self._workspace(review, metadata, worktree)
            self.store.update_review(review_id, title=str(metadata.get("title") or ""), body=str(metadata.get("body") or "")[:65_536], author=str((metadata.get("author") or {}).get("login") or ""), base_ref=metadata.get("baseRefName"), head_ref=metadata.get("headRefName"), base_sha=metadata.get("baseRefOid"), head_sha=metadata.get("headRefOid"), merge_base_sha=merge_base, github_state=metadata.get("state"), is_draft=int(bool(metadata.get("isDraft"))), additions=int(metadata.get("additions") or 0), deletions=int(metadata.get("deletions") or 0), changed_files=int(metadata.get("changedFiles") or len(files)), checkout_path=str(worktree), **({"workspace_id": workspace_id, "tab_id": tab_id, "anchor_pane_id": anchor_pane_id, "workspace_error": workspace_error} if not refresh else {}))
            stage = "viewed-file sync"
            self._pull_viewed(self.store.get_review(review_id, True))
            self.store.update_review(review_id, status="ready", error=None, prepared_at=_now())
            self.store.add_event(review_id, "review.refreshed" if refresh else "review.prepared", "PR review refreshed" if refresh else "PR review prepared")
            self._changed(review_id)
            if not refresh:
                stage = "skill launch"
                for run in self.store.runs_for_review(review_id):
                    if run["state"] == "queued":
                        self._launch_existing_run(review_id, run["id"])
                if _enabled(self.environ, "HERDR_PR_REVIEW_AUTO_RANK", True):
                    self.rank_review(review_id, f"auto-rank:{int(time.time() * 1000)}")
        except Exception as exc:
            # Git and native-client errors can contain checkout locations, which
            # are never safe to surface through the review API.
            timed_out = isinstance(exc, subprocess.TimeoutExpired) or isinstance(exc.__cause__, subprocess.TimeoutExpired)
            error = f"PR review preparation {'timed out' if timed_out else 'failed'} during {stage}. Use Refresh to retry."
            self.store.update_review(review_id, status="failed", error=error)
            self.store.add_event(review_id, "review.failed", error)
            self._changed(review_id)

    def refresh_review(self, review_id: str, request_id: str) -> dict[str, Any]:
        scope = f"refresh:{review_id}"
        cached = self.store.receipt(scope, request_id, {})
        if cached is not None:
            return cached
        review = self.store.get_review(review_id)
        if review.get("archived_at") is not None:
            raise PRReviewError("Review is archived", code="review_archived")
        if review.get("prepared_at") is None and review["status"] in {"preparing", "failed"}:
            self.store.update_review(review_id, status="preparing", error=None)
            self._schedule_preparation(review_id)
        else:
            threading.Thread(target=self.prepare, args=(review_id,), kwargs={"refresh": True}, daemon=True).start()
        result = self.store.get_review(review_id, True)
        self.store.save_receipt(scope, request_id, {}, result)
        return result

    def _render(self, template: str, review: Mapping[str, Any], run_id: str) -> str:
        return template.format(number=review["number"], url=review["url"], owner=review["owner"], repo=review["repo"], review_id=review["id"], run_id=run_id, checkout=review.get("checkout_path") or "")

    @staticmethod
    def _runner_prompt(prompt: str, skill_id: str, runner: str) -> str:
        if runner != "pi":
            return prompt
        legacy = f"/{skill_id}"
        if prompt == legacy or (prompt.startswith(legacy) and prompt[len(legacy):len(legacy) + 1].isspace()):
            return f"/skill:{skill_id}{prompt[len(legacy):]}"
        return prompt

    def _snapshot_outputs(self, worktree: Path, outputs: list[str]) -> list[str]:
        result = self._run(["git", "-C", str(worktree), "ls-files", "--others", "--exclude-standard"], cwd=worktree, kind="git")
        candidates = [line for line in (result.stdout or "").splitlines() if line]
        return [path for path in candidates if self._matches_output(path, outputs)]

    @staticmethod
    def _matches_output(path: str, patterns: list[str]) -> bool:
        from fnmatch import fnmatch
        return any(fnmatch(path, pattern) or fnmatch(path, f"**/{pattern}") for pattern in patterns)

    def start_run(self, review_id: str, skill_id: str, request_id: str, actor: str = "") -> dict[str, Any]:
        run = self.store.create_run(review_id, skill_id, request_id, actor)
        if run["state"] == "queued":
            self._launch_existing_run(review_id, run["id"])
        return self.store.run(review_id, run["id"])

    def _launch_existing_run(self, review_id: str, run_id: str) -> None:
        review = self.store.get_review(review_id, True)
        run = self.store.run(review_id, run_id)
        if run["state"] != "queued" or run.get("started_at") is not None:
            return
        skill = self.store.skill(run["skill_id"])
        worktree = Path(str(review.get("checkout_path") or self._review_worktree(review_id)))
        outputs = list(skill.get("outputs") or [])
        snapshot = self._snapshot_outputs(worktree, outputs)
        run_dir = self._review_dir(review_id) / "runs" / run_id
        run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        if skill["runner"] == "shell":
            command = self._render(str(skill.get("command_template") or ""), review, run_id)
            self.store.update_run(review_id, run_id, launch="shell", command=command, output_snapshot_json=json.dumps(snapshot), started_at=_now(), state="running")
            self.store.add_event(review_id, "run.started", "Skill run started", {"run_id": run_id})
            thread = threading.Thread(target=self._shell_utility, args=(review_id, run_id, command, worktree), daemon=True)
            thread.start()
            self._changed(review_id)
            return
        runner = self.environ.get("HERDR_PR_REVIEW_RUNNER", "pi")
        prompt = self._runner_prompt(self._render(str(skill.get("prompt_template") or ""), review, run_id), str(skill["id"]), runner)
        override_name = {"pi": "HERDR_PR_REVIEW_PI_BIN", "claude": "HERDR_PR_REVIEW_CLAUDE_BIN"}.get(runner)
        runner_bin = _resolve_binary(self.environ, override_name, runner) if override_name else None
        executable = runner_bin or runner
        workspace_id = review.get("workspace_id")
        tab_id = review.get("tab_id")
        anchor = review.get("anchor_pane_id")
        if workspace_id and tab_id and anchor:
            try:
                with self.service._quick_session_lock:
                    native_snapshot = self.service.refresh_snapshot(force=True)
                    before_pane_ids = {
                        str(item.get("pane_id"))
                        for item in native_snapshot.get("panes", [])
                        if isinstance(item, dict) and item.get("pane_id")
                    }
                    split = self._native("pane.split", {"target_pane_id": anchor, "direction": "right", "cwd": str(worktree), "focus": False, "env": {"HERDR_PR_REVIEW_ID": review_id, "HERDR_PR_REVIEW_URL": review["url"], "HERDR_PR_REVIEW_RUN_ID": run_id}})
                    pane_id = self.service._quick_new_identifier(split, "pane_id", before_ids=before_pane_ids)
                    pane_id = pane_id or self.service._quick_split_pane_id(split, tab_id=tab_id, before_pane_ids=before_pane_ids)
                    if not pane_id:
                        raise RuntimeError("pane.split did not return a pane")
                    # Persist ownership before a native request can make the pane live.
                    self.store.update_run(review_id, run_id, launch="none", command=prompt, workspace_id=workspace_id, tab_id=tab_id, pane_id=pane_id, output_snapshot_json=json.dumps(snapshot), started_at=_now(), state="running")
                    try:
                        self._native("agent.start", {"pane_id": pane_id, "name": f"prr-{run_id[5:13]}", "kind": runner, "args": [prompt], "timeout_ms": 30_000})
                        launch = "agent"
                    except Exception:
                        self._native("pane.send_input", {"pane_id": pane_id, "text": shlex.join([executable, prompt]), "keys": ["enter"]})
                        launch = "input"
                    self.store.update_run(review_id, run_id, launch=launch)
                    self.store.add_event(review_id, "run.started", "Skill run started", {"run_id": run_id})
                    self._changed(review_id)
                    return
            except Exception as exc:
                self.store.update_run(review_id, run_id, error=_trim_error(exc, "Could not start review pane"))
        log_path = run_dir / "output.log"
        log = log_path.open("w", encoding="utf-8")
        try:
            process = self.popen([executable, "-p", prompt], cwd=str(worktree), env=self._child_environment(pi_bin=runner_bin if runner == "pi" else None), stdout=log, stderr=subprocess.STDOUT, text=True)
        except OSError as exc:
            log.close()
            self.store.update_run(review_id, run_id, state="failed", error=_trim_error(exc, "Review runner could not start"), finished_at=_now())
            self._changed(review_id)
            return
        with self._lock:
            self._processes[run_id] = (process, log)
        self.store.update_run(review_id, run_id, launch="shell", command=prompt, output_snapshot_json=json.dumps(snapshot), started_at=_now(), state="running")
        self.store.add_event(review_id, "run.started", "Skill run started", {"run_id": run_id})
        self._changed(review_id)

    def _shell_utility(self, review_id: str, run_id: str, command: str, worktree: Path) -> None:
        log_path = self._review_dir(review_id) / "runs" / run_id / "output.log"
        try:
            with log_path.open("w", encoding="utf-8") as log:
                result = self.runner(shlex.split(command), stdout=log, stderr=subprocess.STDOUT, text=True, timeout=600, cwd=str(worktree), env=self._child_environment())
            state = "finished" if result.returncode == 0 else "failed"
            self.store.update_run(review_id, run_id, state=state, finished_at=_now(), error=None if state == "finished" else "Utility command failed")
            self._register_output_documents(review_id, run_id)
            self.sync_viewed(review_id, f"utility-sync:{run_id}")
        except (OSError, subprocess.TimeoutExpired, PRReviewError) as exc:
            self.store.update_run(review_id, run_id, state="failed", finished_at=_now(), error=_trim_error(exc, "Utility command failed"))
        self._changed(review_id)

    def _changed(self, review_id: str) -> None:
        callback = getattr(self.service, "pr_review_changed", None)
        if callable(callback):
            callback(review_id)

    def _document_kind(self, filename: str) -> tuple[str, str]:
        extension = Path(filename).suffix.lower()
        if extension in {".md", ".markdown", ".txt"}:
            return "markdown", "text/markdown"
        if extension in {".html", ".htm"}:
            return "html", "text/html"
        if extension in {".mp3", ".wav", ".m4a", ".aac"}:
            return "audio", "audio/mpeg"
        if extension in {".mp4", ".mov", ".m4v", ".webm"}:
            return "video", "video/mp4"
        return "file", "application/octet-stream"

    def _safe_name(self, value: str) -> str:
        return re.sub(r"[^A-Za-z0-9._-]", "_", Path(value).name)[:160] or "document"

    def _register_output_documents(self, review_id: str, run_id: str) -> bool:
        review = self.store.get_review(review_id, True)
        run = self.store.run(review_id, run_id)
        skill = self.store.skill(run["skill_id"])
        worktree = Path(str(review.get("checkout_path") or self._review_worktree(review_id)))
        try:
            before = set(json.loads(run.get("output_snapshot_json") or "[]"))
        except json.JSONDecodeError:
            before = set()
        changed = False
        for candidate in worktree.rglob("*"):
            if not candidate.is_file() or ".git" in candidate.parts or "node_modules" in candidate.parts:
                continue
            try:
                relative = candidate.relative_to(worktree).as_posix()
            except ValueError:
                continue
            if relative in before or not self._matches_output(relative, list(skill.get("outputs") or [])):
                continue
            # ``git ls-files`` returns a nonzero status for untracked files; run it
            # directly without translating that expected status to a PRReviewError.
            raw = self.runner(["git", "-C", str(worktree), "ls-files", "--error-unmatch", "--", relative], capture_output=True, text=True, timeout=30, cwd=str(worktree), env=self._child_environment())
            if raw.returncode == 0:
                continue
            byte_size = candidate.stat().st_size
            if byte_size > MAX_DOCUMENT_BYTES:
                continue
            digest = self._file_hash(candidate)
            if self.store.document_for_hash(review_id, digest) is not None:
                continue
            docs_dir = self._review_dir(review_id) / "documents"
            docs_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            document_id = f"prdoc_{os.urandom(6).hex()}"
            destination = docs_dir / f"{document_id}-{self._safe_name(relative)}"
            shutil.copyfile(candidate, destination)
            os.chmod(destination, 0o600)
            kind, media_type = self._document_kind(candidate.name)
            document = self.store.add_document(review_id, {"id": document_id, "run_id": run_id, "kind": kind, "title": candidate.name, "media_type": media_type, "filename": candidate.name, "stored_path": str(destination), "byte_size": byte_size, "content_hash": digest, "origin": "skill", "origin_path": relative})
            if document["id"] == document_id:
                changed = True
        return changed

    def reconcile(self) -> None:
        heavy = time.monotonic() - self._last_heavy_scan >= 20
        if heavy:
            self._last_heavy_scan = time.monotonic()
        snapshot: dict[str, Any] = {}
        if any(run["launch"] in {"agent", "input"} and run["state"] == "running" for review in self.store.list_reviews("active") for run in self.store.runs_for_review(review["id"])):
            try:
                snapshot = self.service.refresh_snapshot()
            except Exception:
                snapshot = {}
        panes = pane_index(snapshot)
        for review in self.store.list_reviews("active"):
            changed = False
            for run in self.store.runs_for_review(review["id"]):
                if run["state"] != "running":
                    continue
                if heavy:
                    changed = self._register_output_documents(review["id"], run["id"]) or changed
                if run["launch"] in {"agent", "input"}:
                    pane = panes.get(str(run.get("pane_id") or ""))
                    if pane is None and snapshot:
                        self.store.update_run(review["id"], run["id"], state="ended", note="Pane closed before the run reported an outcome", finished_at=_now())
                        changed = True
                    elif pane is not None and str(pane.get("agent_status") or (pane.get("agent_info") or {}).get("agent_status") or "") in {"done", "idle"}:
                        started = run.get("started_at")
                        try:
                            age = datetime.now(timezone.utc) - datetime.fromisoformat(str(started).replace("Z", "+00:00"))
                        except (TypeError, ValueError):
                            age = None
                        if age is not None and age.total_seconds() >= 60:
                            self.finish_run(review["id"], run["id"], "finished", "", f"reconcile:{run['id']}")
                            changed = True
                elif run["launch"] == "shell":
                    with self._lock:
                        record = self._processes.get(run["id"])
                    if record and record[0].poll() is not None:
                        process, log = record
                        log.close()
                        with self._lock:
                            self._processes.pop(run["id"], None)
                        self.finish_run(review["id"], run["id"], "finished" if process.returncode == 0 else "failed", "", f"reconcile:{run['id']}")
                        changed = True
            if changed:
                self._changed(review["id"])

    def finish_run(self, review_id: str, run_id: str, state: str, note: str, request_id: str) -> dict[str, Any]:
        scope = f"finish:{review_id}:{run_id}"
        payload = {"state": state, "note": note}
        cached = self.store.receipt(scope, request_id, payload)
        if cached is not None:
            return cached
        if state not in {"finished", "failed"}:
            raise PRReviewError("Invalid run state", code="invalid_request", status=400)
        run = self.store.run(review_id, run_id)
        if run["state"] not in {"queued", "running"}:
            raise PRReviewError("Run is not running", code="run_not_running")
        self._register_output_documents(review_id, run_id)
        result = self.store.update_run(review_id, run_id, state=state, note=note, finished_at=_now())
        self.store.add_event(review_id, "run.finished", "Skill run finished", {"run_id": run_id, "state": state})
        self._changed(review_id)
        self.store.save_receipt(scope, request_id, payload, result)
        return result

    def diff(self, review_id: str, path: str | None = None) -> dict[str, Any]:
        review = self.store.get_review(review_id, True)
        document = self._review_dir(review_id) / "diff.json"
        payload = json.loads(document.read_text(encoding="utf-8")) if document.exists() else {"files": [], "truncated": False}
        files = [item for item in payload.get("files", []) if path is None or item.get("path") == path]
        return {"review_id": review_id, "base_sha": review.get("base_sha"), "head_sha": review.get("head_sha"), "truncated": bool(payload.get("truncated")) or any(item.get("truncated") for item in files), "files": files}

    def file_text(self, review_id: str, path: str, side: str, start: int, end: int) -> dict[str, Any]:
        review = self.store.get_review(review_id, True)
        sha = review.get("base_sha") if side == "before" else review.get("head_sha")
        if side not in {"before", "after"} or not sha:
            raise PRReviewError("File side is unavailable", code="invalid_request", status=400)
        result = self._run(["git", "-C", str(review["checkout_path"]), "show", f"{sha}:{path}"], timeout=30, kind="git")
        text = (result.stdout or "").encode("utf-8", "replace")[:MAX_FILE_BYTES].decode("utf-8", "ignore")
        return {"path": path, "side": side, **line_window(text, start, end)}

    def findings_for_path(self, review_id: str, path: str, limit: int = 8192) -> dict[str, Any]:
        needles = {path.casefold(), Path(path).name.casefold()}
        blocks: list[str] = []
        document_ids: list[str] = []
        for document in self.store.documents(review_id):
            if document["kind"] not in {"markdown", "html"} or not document["downloadable"]:
                continue
            if int(document.get("byte_size") or 0) > MAX_FINDINGS_DOCUMENT_BYTES:
                continue
            with self.open_document(review_id, document["id"]) as content:
                text = content.handle.read(MAX_FINDINGS_DOCUMENT_BYTES).decode("utf-8", "ignore")
            if document["kind"] == "html":
                text = re.sub(r"<[^>]+>", " ", html.unescape(text))
            matching = [block.strip() for block in re.split(r"\n\s*\n|\n(?=[*-]\s)|\n(?=\|)", text) if any(needle in block.casefold() for needle in needles)]
            if matching:
                blocks.append(f"## {document['title']}\n" + "\n".join(matching))
                document_ids.append(document["id"])
        return {"path": path, "text": "\n\n".join(blocks)[:limit], "document_ids": document_ids}

    def _save_document(self, review_id: str, filename: str, data: bytes, media_type: str | None, title: str, origin: str, request_id: str, *, origin_path: str | None = None) -> dict[str, Any]:
        if not data or len(data) > MAX_DOCUMENT_BYTES:
            raise PRReviewError("Invalid document data", code="invalid_request", status=400)
        directory = self._review_dir(review_id) / "documents"
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        document_id = f"prdoc_{os.urandom(6).hex()}"
        stored = directory / f"{document_id}-{self._safe_name(filename)}"
        stored.write_bytes(data)
        os.chmod(stored, 0o600)
        kind, default_media_type = self._document_kind(filename)
        return self.store.add_document(review_id, {"id": document_id, "kind": kind, "title": title or filename, "media_type": media_type or default_media_type, "filename": filename, "stored_path": str(stored), "byte_size": len(data), "content_hash": hashlib.sha256(data).hexdigest(), "origin": origin, "origin_path": origin_path, "request_id": request_id})

    def add_document_upload(self, review_id: str, filename: str, content_type: str, data_base64: str, title: str, origin: str, request_id: str) -> dict[str, Any]:
        try:
            data = base64.b64decode(data_base64, validate=True)
        except ValueError as exc:
            raise PRReviewError("Invalid document data", code="invalid_request", status=400) from exc
        if len(data) > MAX_UPLOAD_BYTES:
            raise PRReviewError("Document exceeds 20 MB limit", code="invalid_request", status=400)
        return self._save_document(review_id, filename, data, content_type, title, origin, request_id)

    def add_document_path(self, review_id: str, path: str, title: str, origin: str, request_id: str) -> dict[str, Any]:
        candidate = Path(path)
        if not candidate.is_absolute() or not candidate.is_file() or candidate.suffix.lower() not in ALLOWED_EXTENSIONS or not 0 < candidate.stat().st_size <= MAX_DOCUMENT_BYTES:
            raise PRReviewError("Invalid document path", code="invalid_request", status=400)
        digest = self._file_hash(candidate)
        existing = self.store.document_for_hash(review_id, digest)
        if existing is not None:
            return existing
        document_id = f"prdoc_{os.urandom(6).hex()}"
        directory = self._review_dir(review_id) / "documents"
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        stored = directory / f"{document_id}-{self._safe_name(candidate.name)}"
        shutil.copyfile(candidate, stored)
        os.chmod(stored, 0o600)
        kind, media_type = self._document_kind(candidate.name)
        return self.store.add_document(review_id, {"id": document_id, "kind": kind, "title": title or candidate.name, "media_type": media_type, "filename": candidate.name, "stored_path": str(stored), "byte_size": candidate.stat().st_size, "content_hash": digest, "origin": origin, "origin_path": str(candidate), "request_id": request_id})

    @staticmethod
    def _file_hash(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def add_document_link(self, review_id: str, url: str, title: str, origin: str, request_id: str) -> dict[str, Any]:
        if urlsplit(url).scheme not in {"http", "https"}:
            raise PRReviewError("Document link must be HTTP(S)", code="invalid_request", status=400)
        return self.store.add_document(review_id, {"kind": "link", "title": title or url, "media_type": "text/uri-list", "url": url, "origin": origin, "request_id": request_id})

    @contextlib.contextmanager
    def open_document(self, review_id: str, document_id: str) -> Iterator[PRReviewDocumentContent]:
        document = self.store.document(review_id, document_id, include_storage=True)
        stored_path = document.get("stored_path")
        if not stored_path:
            raise PRReviewError("Document is not downloadable", code="document_not_downloadable")
        root = (self._review_dir(review_id) / "documents").resolve()
        path = Path(str(stored_path)).resolve()
        try:
            path.relative_to(root)
        except ValueError as exc:
            raise PRReviewError("Document is not downloadable", code="document_not_downloadable") from exc
        handle = path.open("rb")
        try:
            yield PRReviewDocumentContent(self.store.document(review_id, document_id), handle, int(document.get("byte_size") or 0), str(document.get("media_type") or "application/octet-stream"))
        finally:
            handle.close()

    def run_output(self, review_id: str, run_id: str, lines: int = 200) -> dict[str, Any]:
        run = self.store.run(review_id, run_id)
        if run.get("pane_id"):
            try:
                response = self.service.read_pane(str(run["pane_id"]), lines=lines)
                output = response.get("output", response)
                text = output.get("text") if isinstance(output, dict) else output
                return {"run_id": run_id, "lines": str(text or "").splitlines()[-lines:], "source": "pane"}
            except Exception:
                pass
        log = self._review_dir(review_id) / "runs" / run_id / "output.log"
        if log.exists():
            return {"run_id": run_id, "lines": log.read_text(encoding="utf-8", errors="replace").splitlines()[-lines:], "source": "log"}
        return {"run_id": run_id, "lines": [], "source": "none"}

    def rank_review(self, review_id: str, request_id: str) -> dict[str, Any]:
        review, should_launch = self.store.start_ranking(review_id, request_id)
        if should_launch:
            threading.Thread(target=self._rank_worker, args=(review_id, request_id), daemon=True).start()
        self._changed(review_id)
        return review

    def _rank_worker(self, review_id: str, request_id: str) -> None:
        try:
            review = self.store.get_review(review_id, True)
            files = self.store.files(review_id)
            diff = self.diff(review_id)["files"]
            snippets = {item["path"]: json.dumps(item, ensure_ascii=False)[:1200] for item in diff}
            prompt = "Return strict JSON {\"files\":[{\"path\",\"impact\":\"low|medium|high\",\"reason\"}],\"guided\":[{\"path\",\"reason\"}]}.\n" + json.dumps({"title": review["title"], "body": str(review.get("body") or "")[:4096], "files": [{"path": item["path"], "status": item["status"], "additions": item["additions"], "deletions": item["deletions"], "diff": snippets.get(item["path"], "")} for item in files]}, ensure_ascii=False)[:96 * 1024]
            pi_bin = _resolve_binary(self.environ, "HERDR_PR_REVIEW_PI_BIN", "pi")
            if not pi_bin:
                raise PRReviewError("Pi is not installed", code="github_failed", status=502)
            command = [pi_bin, "-p", "--mode", "json", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-approve"]
            model = self.environ.get("HERDR_PR_REVIEW_MODEL", "")
            if model:
                command.extend(["--model", model])
            thinking = self.environ.get("HERDR_PR_REVIEW_THINKING", "medium")
            if thinking:
                command.extend(["--thinking", thinking])
            result = self.runner(command, capture_output=True, text=False, input=prompt.encode("utf-8"), timeout=600, cwd=str(self._review_dir(review_id)), env=self._child_environment(pi_bin=pi_bin))
            if result.returncode:
                raise PRReviewError(_trim_error(self._decode_output(result.stderr), "Pi ranking failed"), code="github_failed", status=502)
            assistant = ""
            for line in self._decode_output(result.stdout).splitlines():
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(event, dict) and event.get("type") == "message_end":
                    assistant = _assistant_text(event.get("message")) or _assistant_text(event.get("data", {}).get("message") if isinstance(event.get("data"), dict) else None)
            start = assistant.find("{")
            if start < 0:
                raise PRReviewError("Pi ranking returned no JSON", code="invalid_request", status=400)
            ranking, _ = json.JSONDecoder().raw_decode(assistant[start:])
            ranked = ranking.get("files")
            guided = {item["path"]: item.get("reason") for item in ranking.get("guided", []) if isinstance(item, dict) and isinstance(item.get("path"), str)}
            if not isinstance(ranked, list):
                raise PRReviewError("Pi ranking returned invalid files", code="invalid_request", status=400)
            valid_paths = {item["path"] for item in files}
            normalized = []
            for order, item in enumerate(ranked, 1):
                if not isinstance(item, dict) or item.get("path") not in valid_paths or item.get("impact") not in {"low", "medium", "high"}:
                    raise PRReviewError("Pi ranking returned an unknown path", code="invalid_request", status=400)
                normalized.append({"path": item["path"], "impact": item["impact"], "reason": item.get("reason"), "guided_order": order if item["path"] in guided else None, "guided_reason": guided.get(item["path"])})
            self._write_json(self._review_dir(review_id) / "ranking.json", ranking)
            self.store.set_rankings(review_id, normalized, request_id)
            self.store.add_event(review_id, "review.ranked", "PR files ranked")
        except (PRReviewError, OSError, json.JSONDecodeError) as exc:
            self.store.set_ranking_state(review_id, "failed", _trim_error(exc, "PR ranking failed"))
        self._changed(review_id)

    def set_rankings(self, review_id: str, files: list[dict[str, Any]], request_id: str) -> list[dict[str, Any]]:
        result = self.store.set_rankings(review_id, files, request_id)
        self._changed(review_id)
        return result

    def set_viewed(self, review_id: str, paths: list[str], viewed: bool, sync_github: bool, request_id: str, source: str = "user") -> list[dict[str, Any]]:
        result = self.store.set_viewed(review_id, paths, viewed, request_id, source)
        if sync_github and _enabled(self.environ, "HERDR_PR_REVIEW_SYNC_VIEWED", True):
            review = self.store.get_review(review_id, True)
            try:
                metadata = json.loads((self._review_dir(review_id) / "pr.json").read_text(encoding="utf-8"))
                mutation = "mutation($pullRequestId:ID!,$path:String!){" + ("markFileAsViewed" if viewed else "unmarkFileAsViewed") + "(input:{pullRequestId:$pullRequestId,path:$path}){clientMutationId}}"
                for path in paths:
                    self._run(["gh", "api", "graphql", "-f", f"query={mutation}", "-f", f"pullRequestId={metadata['id']}", "-f", f"path={path}"], kind="gh")
            except (OSError, KeyError, json.JSONDecodeError, PRReviewError) as exc:
                self.store.add_event(review_id, "github.viewed_push_failed", "Could not sync viewed files to GitHub", {"error": _trim_error(exc, "GitHub sync failed")})
        self._changed(review_id)
        return result

    def sync_viewed(self, review_id: str, request_id: str) -> list[dict[str, Any]]:
        review = self.store.get_review(review_id, True)
        self._pull_viewed(review)
        result = self.store.files(review_id)
        self._changed(review_id)
        return result
