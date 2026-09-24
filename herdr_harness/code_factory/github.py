"""Thin wrapper around the operator's authenticated ``gh`` CLI for one repository.

Every method builds an explicit argv (never a shell string), runs it through an
injectable ``runner`` with the sanitized agent environment, and converts failures into
``CodeFactoryError(code="github_failed")`` whose message carries at most 300 characters
of stderr and never the environment. The HTTP status ``gh`` printed (if any) is kept on
the error as ``http_status`` so callers can branch on it without parsing the trimmed
message. Read-only commands are retried a few times on timeouts and transient failures
(rate limits, 5xx, network blips); mutating commands are never retried.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

from ..child_environment import agent_environment
from .ci_logs import failed_log_excerpt
from .errors import CodeFactoryError

REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
LABEL_PATTERN = re.compile(r"^[^\x00-\x1f\x7f,]{1,50}$")
BRANCH_PATTERN = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{7,64}$")
COLOR_PATTERN = re.compile(r"^[0-9A-Fa-f]{6}$")
ISSUE_FIELDS = "number,title,body,author,labels,url,createdAt,updatedAt"
ISSUE_VIEW_FIELDS = ISSUE_FIELDS + ",comments,state,closedByPullRequestsReferences"
PR_VIEW_FIELDS = "number,url,state,headRefOid,mergedAt,mergeCommit,baseRefName,headRefName,title,mergeable,mergeStateStatus"
RUN_FIELDS = "status,conclusion,databaseId,url"
VERIFY_WORKFLOW = "Verify"
MAX_STDERR_CHARS = 300
MAX_DIFF_BYTES = 400 * 1024
MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
MAX_BODY_CHARS = 65_000
DOWNLOAD_CHUNK = 64 * 1024
RETRY_DELAYS = (2.0, 5.0, 15.0)
READ_ONLY_COMMANDS = frozenset({
    ("issue", "list"), ("issue", "view"), ("pr", "list"), ("pr", "view"), ("pr", "diff"),
    ("run", "list"), ("run", "view"), ("api", "user"),
})
HTTP_STATUS_RE = re.compile(r"\(HTTP (\d{3})\)")
TRANSIENT_RE = re.compile(
    r"rate limit|HTTP 5\d\d|connection|timed out|timeout|unexpected EOF|temporarily unavailable"
    r"|network is unreachable|no such host|TLS handshake",
    re.IGNORECASE,
)

Runner = Callable[..., Any]


class GitHubCommandError(CodeFactoryError):
    """``github_failed`` carrying the HTTP status ``gh`` reported, when it printed one."""

    def __init__(self, message: str, *, http_status: int | None = None):
        super().__init__(message, code="github_failed")
        self.http_status = http_status


def _trim(text: Any, limit: int = MAX_STDERR_CHARS) -> str:
    value = text if isinstance(text, str) else ""
    value = value.strip()
    return value if len(value) <= limit else value[-limit:]


def _failed(message: str, *, http_status: int | None = None) -> CodeFactoryError:
    return GitHubCommandError(message, http_status=http_status)


def _http_status(*outputs: Any) -> int | None:
    """The ``(HTTP nnn)`` status in ``gh``'s untrimmed output, if present."""
    for text in outputs:
        if isinstance(text, str):
            match = HTTP_STATUS_RE.search(text)
            if match:
                return int(match.group(1))
    return None


def _transient(*outputs: Any) -> bool:
    return any(isinstance(text, str) and TRANSIENT_RE.search(text) for text in outputs)


def _read_only(args: Sequence[str]) -> bool:
    """True for idempotent ``gh`` reads that are safe to run again after a transient failure."""
    return tuple(args[:2]) in READ_ONLY_COMMANDS


def _invalid(message: str) -> CodeFactoryError:
    return CodeFactoryError(message, code="invalid_request")


def _number(value: Any, name: str = "number") -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise _invalid(f"{name} must be a positive integer")
    return value


def _text(value: Any, name: str, *, maximum: int) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum or "\x00" in value:
        raise _invalid(f"{name} must be a non-empty string of at most {maximum} characters")
    return value


def _label(value: Any) -> str:
    text = _text(value, "label", maximum=50)
    if not LABEL_PATTERN.match(text):
        raise _invalid(f"invalid label: {text[:50]!r}")
    return text


def _branch(value: Any, name: str = "branch") -> str:
    text = _text(value, name, maximum=200)
    if not BRANCH_PATTERN.match(text) or ".." in text or text.startswith("-"):
        raise _invalid(f"invalid {name}: {text[:80]!r}")
    return text


def _sha(value: Any) -> str:
    text = _text(value, "sha", maximum=64).lower()
    if not SHA_PATTERN.match(text):
        raise _invalid("sha must be a hexadecimal commit id")
    return text


class GitHubClient:
    """Repository-scoped ``gh`` operations with an injectable process runner."""

    def __init__(
        self,
        repository: str,
        *,
        runner: Runner = subprocess.run,
        environ: Mapping[str, str] | None = None,
        timeout: int = 60,
        urlopen: Callable[..., Any] = urllib.request.urlopen,
        gh_binary: str = "gh",
        sleep: Callable[[float], None] = time.sleep,
    ):
        if not isinstance(repository, str) or not REPOSITORY_PATTERN.match(repository) or ".." in repository:
            raise CodeFactoryError("repository must look like OWNER/NAME", code="invalid_settings")
        self.repository = repository
        self._runner = runner
        self._environ = dict(environ) if environ is not None else dict(os.environ)
        self.timeout = max(5, int(timeout))
        self._urlopen = urlopen
        self._gh = gh_binary
        self._sleep = sleep

    # -- process plumbing ---------------------------------------------------------

    def environment(self) -> dict[str, str]:
        """The child environment: provider credentials kept, ``HERDR_*`` settings stripped."""
        return agent_environment(self._environ, integration=False)

    def _run(
        self,
        args: Sequence[str],
        *,
        input_text: str | None = None,
        timeout: int | None = None,
        check: bool = True,
    ) -> Any:
        """Run ``gh``; read-only commands are retried on timeouts and transient failures."""
        argv = [self._gh, *args]
        kwargs: dict[str, Any] = {
            "capture_output": True,
            "text": True,
            "errors": "replace",
            "timeout": timeout or self.timeout,
            "env": self.environment(),
        }
        if input_text is not None:
            kwargs["input"] = input_text
        delays = RETRY_DELAYS if check and _read_only(args) else ()
        attempt = 0
        while True:
            try:
                result = self._runner(argv, **kwargs)
            except subprocess.TimeoutExpired as exc:
                if attempt < len(delays):
                    self._sleep(delays[attempt])
                    attempt += 1
                    continue
                raise _failed(f"gh {args[0]} timed out after {kwargs['timeout']} seconds") from exc
            except OSError as exc:
                raise _failed(f"gh could not start: {_trim(str(exc))}") from exc
            if not check or result.returncode == 0:
                return result
            if attempt < len(delays) and _transient(result.stderr, result.stdout):
                self._sleep(delays[attempt])
                attempt += 1
                continue
            detail = _trim(result.stderr) or _trim(result.stdout) or f"exit status {result.returncode}"
            raise _failed(
                f"gh {' '.join(args[:2])} failed: {detail}",
                http_status=_http_status(result.stderr, result.stdout),
            )

    def _json(self, args: Sequence[str], *, input_text: str | None = None, timeout: int | None = None) -> Any:
        result = self._run(args, input_text=input_text, timeout=timeout)
        stdout = result.stdout if isinstance(result.stdout, str) else ""
        if not stdout.strip():
            return None
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise _failed(f"gh {' '.join(args[:2])} returned invalid JSON") from exc

    @staticmethod
    def _dict_list(value: Any) -> list[dict[str, Any]]:
        if not isinstance(value, list):
            return []
        return [item for item in value if isinstance(item, dict)]

    # -- issues -------------------------------------------------------------------

    def list_issues(self, label: str) -> list[dict[str, Any]]:
        """Open issues carrying ``label`` (at most 100)."""
        payload = self._json([
            "issue", "list", "--repo", self.repository, "--label", _label(label),
            "--state", "open", "--limit", "100", "--json", ISSUE_FIELDS,
        ])
        return [item for item in self._dict_list(payload) if isinstance(item.get("number"), int)]

    def get_issue(self, number: int) -> dict[str, Any]:
        payload = self._json([
            "issue", "view", str(_number(number)), "--repo", self.repository,
            "--json", ISSUE_VIEW_FIELDS,
        ])
        if not isinstance(payload, dict):
            raise _failed(f"gh issue view #{number} returned no issue")
        return payload

    def add_labels(self, number: int, *labels: str) -> None:
        names = [_label(item) for item in labels]
        if not names:
            return
        args = ["issue", "edit", str(_number(number)), "--repo", self.repository]
        for name in names:
            args += ["--add-label", name]
        self._run(args)

    def remove_labels(self, number: int, *labels: str) -> None:
        names = [_label(item) for item in labels]
        if not names:
            return
        args = ["issue", "edit", str(_number(number)), "--repo", self.repository]
        for name in names:
            args += ["--remove-label", name]
        self._run(args)

    def comment_issue(self, number: int, body: str) -> None:
        text = _text(body, "body", maximum=MAX_BODY_CHARS)
        with tempfile.TemporaryDirectory(prefix="herdr-cf-comment-") as directory:
            path = Path(directory) / "comment.md"
            path.write_text(text, encoding="utf-8")
            self._run(["issue", "comment", str(_number(number)), "--repo", self.repository, "--body-file", str(path)])

    def close_issue(self, number: int, *, comment: str | None = None) -> None:
        args = ["issue", "close", str(_number(number)), "--repo", self.repository, "--reason", "completed"]
        if comment is not None:
            args += ["--comment", _text(comment, "comment", maximum=MAX_BODY_CHARS)]
        self._run(args)

    # -- attachments --------------------------------------------------------------

    def allowed_download(self, url: str) -> bool:
        """True for this repository's release assets and GitHub user-attachments only."""
        try:
            parts = urllib.parse.urlsplit(url)
        except ValueError:
            return False
        if parts.scheme != "https" or parts.netloc.lower() != "github.com" or parts.username or parts.password:
            return False
        path = parts.path
        if ".." in path or "\\" in path:
            return False
        prefixes = (f"/{self.repository}/releases/download/", "/user-attachments/")
        return any(path.startswith(prefix) and len(path) > len(prefix) for prefix in prefixes)

    def download(self, url: str, destination: str | Path) -> Path:
        """Fetch an attachment (≤ 20 MiB) into ``destination`` with 0o600 permissions."""
        if not isinstance(url, str) or len(url) > 2048 or not self.allowed_download(url):
            raise CodeFactoryError("attachment URL host is not allowed", code="download_failed")
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers={"User-Agent": "herdr-code-factory"})
        written = 0
        try:
            with self._urlopen(request, timeout=self.timeout) as response:
                status = getattr(response, "status", 200)
                if status != 200:
                    raise CodeFactoryError(f"attachment download returned HTTP {status}", code="download_failed")
                with open(target, "wb", opener=lambda p, f: os.open(p, f, 0o600)) as handle:
                    while True:
                        chunk = response.read(DOWNLOAD_CHUNK)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > MAX_DOWNLOAD_BYTES:
                            raise CodeFactoryError("attachment exceeds 20 MiB", code="download_failed")
                        handle.write(chunk)
        except CodeFactoryError:
            target.unlink(missing_ok=True)
            raise
        except (OSError, ValueError, http.client.HTTPException) as exc:
            target.unlink(missing_ok=True)
            raise CodeFactoryError(f"attachment download failed: {_trim(str(exc))}", code="download_failed") from exc
        os.chmod(target, 0o600)
        return target

    # -- pull requests ------------------------------------------------------------

    def create_pull_request(self, head: str, base: str, title: str, body: str) -> dict[str, Any]:
        head_branch = _branch(head, "head")
        base_branch = _branch(base, "base")
        title_text = _text(title, "title", maximum=256)
        body_text = _text(body, "body", maximum=MAX_BODY_CHARS)
        with tempfile.TemporaryDirectory(prefix="herdr-cf-pr-") as directory:
            path = Path(directory) / "body.md"
            path.write_text(body_text, encoding="utf-8")
            self._run([
                "pr", "create", "--repo", self.repository, "--head", head_branch, "--base", base_branch,
                "--title", title_text, "--body-file", str(path),
            ], timeout=max(self.timeout, 120))
        payload = self._json(["pr", "view", head_branch, "--repo", self.repository, "--json", "number,url"])
        if not isinstance(payload, dict) or not isinstance(payload.get("number"), int):
            raise _failed("gh pr view did not return the new pull request")
        return {"number": payload["number"], "url": str(payload.get("url") or "")}

    def find_pull_request(self, head_branch: str) -> dict[str, Any] | None:
        payload = self._json([
            "pr", "list", "--repo", self.repository, "--head", _branch(head_branch, "head"),
            "--state", "all", "--json", "number,url,state,headRefOid",
        ])
        candidates = [item for item in self._dict_list(payload) if isinstance(item.get("number"), int)]
        if not candidates:
            return None
        candidates.sort(key=lambda item: (0 if item.get("state") == "OPEN" else 1, -int(item["number"])))
        chosen = candidates[0]
        return {
            "number": chosen["number"],
            "url": str(chosen.get("url") or ""),
            "state": str(chosen.get("state") or ""),
            "headRefOid": str(chosen.get("headRefOid") or ""),
        }

    def pull_request(self, number: int) -> dict[str, Any]:
        payload = self._json(["pr", "view", str(_number(number)), "--repo", self.repository, "--json", PR_VIEW_FIELDS])
        if not isinstance(payload, dict):
            raise _failed(f"gh pr view #{number} returned no pull request")
        return payload

    def pull_request_diff(self, number: int) -> str:
        result = self._run(["pr", "diff", str(_number(number)), "--repo", self.repository], timeout=max(self.timeout, 120))
        diff = result.stdout if isinstance(result.stdout, str) else ""
        encoded = diff.encode("utf-8")
        if len(encoded) > MAX_DIFF_BYTES:
            diff = encoded[:MAX_DIFF_BYTES].decode("utf-8", errors="ignore") + "\n[diff truncated at 400 KiB]\n"
        return diff

    # -- checks -------------------------------------------------------------------

    def _runs_for(self, sha: str) -> list[dict[str, Any]]:
        payload = self._json([
            "run", "list", "--repo", self.repository, "--commit", _sha(sha), "--workflow", VERIFY_WORKFLOW,
            "--json", RUN_FIELDS, "--limit", "20",
        ])
        return self._dict_list(payload)

    def list_runs(self, sha: str) -> list[dict[str, Any]]:
        """Verify workflow runs for ``sha`` (at most 20)."""
        return self._runs_for(sha)

    @staticmethod
    def classify_runs(runs: Iterable[Mapping[str, Any]]) -> str:
        """Fold workflow runs into ``success|failure|pending|none``."""
        items = list(runs)
        if not items:
            return "none"
        completed = [run for run in items if run.get("status") == "completed"]
        if any(run.get("conclusion") != "success" for run in completed):
            return "failure"
        if len(completed) < len(items):
            return "pending"
        return "success"

    def verify_status(self, sha: str) -> str:
        return self.classify_runs(self.list_runs(sha))

    def failed_run_log(self, sha: str) -> str:
        """Bounded failure diagnostics from the first failed Verify run, or ``""``."""
        failed = [
            run for run in self.list_runs(sha)
            if run.get("status") == "completed" and run.get("conclusion") != "success"
            and isinstance(run.get("databaseId"), int)
        ]
        if not failed:
            return ""
        run_id = str(failed[0]["databaseId"])
        result = self._run(["run", "view", run_id, "--repo", self.repository, "--log-failed"],
                           timeout=max(self.timeout, 120), check=False)
        text = result.stdout if isinstance(result.stdout, str) else ""
        if result.returncode != 0 and not text.strip():
            text = result.stderr if isinstance(result.stderr, str) else ""
        return failed_log_excerpt(text)

    def rerun_failed(self, run_id: int) -> None:
        """Ask GitHub to re-run only the failed jobs in one workflow run."""
        self._run(["run", "rerun", str(_number(run_id, "run_id")), "--repo", self.repository, "--failed"])

    # -- reviews and merges -------------------------------------------------------

    @staticmethod
    def _normalize_comments(comments: Iterable[Mapping[str, Any]] | None) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for item in comments or ():
            if not isinstance(item, Mapping):
                continue
            path = item.get("path")
            line = item.get("line")
            body = item.get("body")
            if not isinstance(path, str) or not path.strip() or len(path) > 512 or path.startswith("/") or ".." in path:
                continue
            if isinstance(line, bool) or not isinstance(line, int) or line <= 0:
                continue
            if not isinstance(body, str) or not body.strip():
                continue
            result.append({"path": path, "line": line, "side": "RIGHT", "body": body[:MAX_BODY_CHARS]})
            if len(result) >= 50:
                break
        return result

    def post_review(self, number: int, body: str, comments: Iterable[Mapping[str, Any]] | None = None) -> dict[str, Any]:
        """Post a COMMENT review; when inline comments are rejected (422) fold them into the body."""
        pr_number = _number(number)
        body_text = _text(body, "body", maximum=MAX_BODY_CHARS)
        inline = self._normalize_comments(comments)
        endpoint = f"repos/{self.repository}/pulls/{pr_number}/reviews"
        args = ["api", endpoint, "--method", "POST", "--input", "-"]
        payload = {"event": "COMMENT", "body": body_text, "comments": inline}
        try:
            response = self._json(args, input_text=json.dumps(payload))
        except CodeFactoryError as exc:
            # The status comes from the untrimmed output: gh prints it on the first line,
            # followed by one line per rejected comment, so the message tail may lack it.
            if not inline or getattr(exc, "http_status", None) != 422:
                raise
            folded = body_text + "\n\n" + "\n".join(
                f"- `{item['path']}:{item['line']}` — {item['body']}" for item in inline
            )
            payload = {"event": "COMMENT", "body": folded[:MAX_BODY_CHARS], "comments": []}
            response = self._json(args, input_text=json.dumps(payload))
        return response if isinstance(response, dict) else {}

    @staticmethod
    def _is_merged(payload: Mapping[str, Any]) -> bool:
        return str(payload.get("state") or "").upper() == "MERGED"

    @staticmethod
    def _with_merge_sha(payload: dict[str, Any]) -> dict[str, Any]:
        commit = payload.get("mergeCommit")
        payload["mergeSha"] = str(commit.get("oid") or "") if isinstance(commit, dict) else ""
        return payload

    def merge_pull_request(
        self,
        number: int,
        *,
        subject: str | None = None,
        body: str | None = None,
        head_sha: str | None = None,
    ) -> dict[str, Any]:
        """Squash-merge, delete the remote branch, and return the PR with ``mergeSha``.

        Idempotent: a pull request that already landed (a retry after a timed-out or
        interrupted first attempt) is returned without running ``gh pr merge`` again,
        and a merge that leaves the pull request unmerged (queued, rejected) raises
        instead of reporting an empty ``mergeSha``. ``body`` replaces the squashed
        commit messages (which may carry closing keywords) as the merge commit body;
        ``head_sha`` makes ``gh`` refuse the merge when the branch moved past the
        commit that was verified and reviewed (``--match-head-commit``).
        """
        pr_number = _number(number)
        current = self.pull_request(pr_number)
        if self._is_merged(current):
            return self._with_merge_sha(current)
        title = subject if isinstance(subject, str) and subject.strip() else str(current.get("title") or "")
        title = title.strip()[:256] or f"Merge pull request #{pr_number}"
        args = ["pr", "merge", str(pr_number), "--repo", self.repository, "--squash", "--delete-branch", "--subject", title]
        if isinstance(body, str) and body.strip():
            args += ["--body", _text(body, "body", maximum=MAX_BODY_CHARS)]
        if head_sha is not None:
            args += ["--match-head-commit", _sha(head_sha)]
        self._run(args, timeout=max(self.timeout, 120))
        merged = self.pull_request(pr_number)
        if not self._is_merged(merged):
            state = str(merged.get("state") or "unknown")
            raise _failed(f"gh pr merge #{pr_number} did not merge the pull request (state {state})")
        return self._with_merge_sha(merged)

    # -- misc ---------------------------------------------------------------------

    def login(self) -> str:
        result = self._run(["api", "user", "--jq", ".login"])
        login = (result.stdout or "").strip() if isinstance(result.stdout, str) else ""
        if not login:
            raise _failed("gh api user returned no login")
        return login

    def ensure_label(self, name: str, color: str, description: str) -> None:
        if not isinstance(color, str) or not COLOR_PATTERN.match(color):
            raise _invalid("label color must be a 6-digit hex value")
        self._run([
            "label", "create", _label(name), "--repo", self.repository, "--color", color,
            "--description", _text(description, "description", maximum=100), "--force",
        ])
