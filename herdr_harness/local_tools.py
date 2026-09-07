"""Native Herdr tool services. All workspace operations execute on this server.

The API resolves workspace and pane roots from Herdr's cached snapshot. Client
paths are only preconditions or relative filenames, never root selectors.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Optional

from . import attachments, voice, workspace_tools

LocalToolsError = workspace_tools.WorkspaceToolError
GIT_TIMEOUT_SECONDS = workspace_tools.GIT_TIMEOUT_SECONDS
MAX_GIT_ROOT_BYTES = 4096
_GIT_COMMIT_RE = re.compile(r"^[0-9A-Fa-f]{4,40}$")

def _root_path(root: Path | str) -> str:
    if not isinstance(root, (Path, str)):
        raise LocalToolsError("workspace root is invalid", code="invalid_workspace_root", status=400)
    text = str(root)
    if not text or "\x00" in text or len(text) > 4096:
        raise LocalToolsError("workspace root is invalid", code="invalid_workspace_root", status=400)
    try:
        path = Path(text).expanduser().resolve()
    except (OSError, RuntimeError, ValueError) as exc:
        raise LocalToolsError(
            "workspace root is invalid",
            code="invalid_workspace_root",
            status=400,
        ) from exc
    if not path.is_absolute() or not path.is_dir():
        raise LocalToolsError(
            "workspace root is unavailable",
            code="workspace_root_not_found",
            status=404,
        )
    return str(path)


def _git_root_path(root: Path | str) -> str:
    """Resolve a nested pane cwd to the checkout root used by Herdr Git tools."""

    workspace_root = _root_path(root)
    try:
        # Keep the tiny discovery result out of an unbounded subprocess pipe.
        # A pane can report any nested cwd, while Git operations
        # expect repository-relative filenames rooted at the checkout.
        with tempfile.TemporaryFile(mode="w+b") as stdout_file:
            result = subprocess.run(
                ["git", "-C", workspace_root, "rev-parse", "--show-toplevel"],
                stdout=stdout_file,
                stderr=subprocess.DEVNULL,
                timeout=GIT_TIMEOUT_SECONDS,
                check=False,
            )
            stdout_file.seek(0)
            encoded = stdout_file.read(MAX_GIT_ROOT_BYTES + 1)
    except FileNotFoundError as exc:
        raise LocalToolsError(
            "Git is unavailable on the Herdr server",
            code="git_unavailable",
            status=503,
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise LocalToolsError(
            "Git repository discovery timed out",
            code="git_timeout",
            status=504,
        ) from exc
    except OSError as exc:
        raise LocalToolsError(
            "Git repository discovery failed",
            code="git_failed",
            status=502,
        ) from exc

    if result.returncode != 0:
        raise LocalToolsError(
            "Workspace is not inside a Git repository",
            code="git_repository_not_found",
            status=404,
        )
    if not encoded or len(encoded) > MAX_GIT_ROOT_BYTES:
        raise LocalToolsError(
            "Git returned an invalid repository path",
            code="git_repository_invalid",
            status=502,
        )
    try:
        candidate = Path(encoded.decode("utf-8").strip()).expanduser().resolve()
        if (
            not candidate.is_dir()
            or os.path.commonpath((str(candidate), workspace_root)) != str(candidate)
        ):
            raise ValueError("repository root is not an ancestor of the workspace root")
    except (OSError, RuntimeError, UnicodeDecodeError, ValueError) as exc:
        raise LocalToolsError(
            "Git returned an invalid repository path",
            code="git_repository_invalid",
            status=502,
        ) from exc
    return str(candidate)


def _relative_git_path(root: str, file: Any) -> str:
    if not isinstance(file, str) or not file or "\x00" in file or len(file) > 4096:
        raise LocalToolsError("file is required", code="invalid_git_path", status=400)
    candidate_path = Path(file)
    if candidate_path.is_absolute() or any(
        part in {"", ".", ".."} for part in file.split("/")
    ):
        raise LocalToolsError(
            "file must be a repository-relative path without traversal",
            code="invalid_git_path",
            status=400,
        )
    try:
        # Git addresses the index by repository-relative pathname. Resolve the
        # parent to catch directory symlink escapes, but allow the final inode
        # itself to be a symlink because git stages/diffs that pathname rather
        # than its target.
        parent = (Path(root) / candidate_path.parent).resolve(strict=False)
        if os.path.commonpath((root, str(parent))) != root:
            raise LocalToolsError(
                "file must stay inside the repository",
                code="invalid_git_path",
                status=400,
            )
    except ValueError as exc:
        raise LocalToolsError(
            "file must stay inside the repository",
            code="invalid_git_path",
            status=400,
        ) from exc
    return candidate_path.as_posix()


def _git_commit_hash(value: Any) -> str:
    if not isinstance(value, str) or not _GIT_COMMIT_RE.fullmatch(value):
        raise LocalToolsError(
            "hash must be a 4 to 40 character hexadecimal Git commit ID",
            code="invalid_git_hash",
            status=400,
        )
    return value.lower()


OPEN_TIMEOUT_SECONDS = 10.0


def _open_command(reveal: bool) -> Optional[list[str]]:
    """Return the platform launcher for opening a file or revealing it."""

    if sys.platform == "darwin":
        return ["open", "-R"] if reveal else ["open"]
    if sys.platform.startswith("linux"):
        return ["xdg-open"]
    return None


def _open_repository_file(root: str, relative: str, *, reveal: bool) -> str:
    """Open (or reveal) a repository file with the machine's default tools."""

    absolute = Path(root) / relative
    try:
        exists = absolute.exists()
    except OSError:
        exists = False
    if reveal:
        # Deletions and renames legitimately reference paths that no longer
        # exist; revealing the closest surviving ancestor is still useful.
        target = absolute
        repository_root = Path(root)
        while not target.exists() and target != repository_root and target.parent != target:
            target = target.parent
        target_path = str(target)
    elif not exists:
        raise LocalToolsError(
            "This file is not present in the working tree",
            code="git_file_not_in_working_tree",
            status=404,
        )
    else:
        target_path = str(absolute)

    command = _open_command(reveal)
    if command is None:
        raise LocalToolsError(
            "Opening files is not supported on this platform",
            code="git_open_unsupported_platform",
            status=503,
        )
    try:
        completed = subprocess.run(
            [*command, target_path],
            capture_output=True,
            text=True,
            timeout=OPEN_TIMEOUT_SECONDS,
            check=False,
        )
    except FileNotFoundError as exc:
        raise LocalToolsError(
            "The system opener is unavailable",
            code="git_open_unavailable",
            status=503,
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise LocalToolsError(
            "Opening the file timed out",
            code="git_open_timeout",
            status=504,
        ) from exc
    except OSError as exc:
        raise LocalToolsError(
            "Opening the file failed",
            code="git_open_failed",
            status=502,
        ) from exc
    if completed.returncode != 0:
        message = (completed.stderr or completed.stdout or "").strip().splitlines()
        raise LocalToolsError(
            message[0][:200] if message else "The system could not open the file",
            code="git_open_rejected",
            status=502,
        )
    return target_path


def _require_expected_git_root(current_root: str, expected_root: Any) -> None:
    """Compare a client snapshot root without ever using it as a selector."""

    if (
        not isinstance(expected_root, str)
        or not expected_root
        or "\x00" in expected_root
        or len(expected_root) > 4096
        or not Path(expected_root).is_absolute()
    ):
        raise LocalToolsError(
            "expected_root must be the absolute repository path from Git status",
            code="invalid_git_root_precondition",
            status=400,
        )
    normalized_expected = os.path.normpath(expected_root)
    if normalized_expected != current_root:
        raise LocalToolsError(
            "This pane moved to a different Git repository. Refresh Git status before continuing.",
            code="git_repository_changed",
            status=409,
        )


class LocalTools:
    """One server's native Git, project, provider, and upload services."""

    def __init__(self, environ: Optional[Mapping[str, str]] = None) -> None:
        self.environ = os.environ if environ is None else environ

    @staticmethod
    def _repository(root: Path | str, expected_root: Any = None) -> Path:
        path = _git_root_path(root)
        if expected_root is not None:
            _require_expected_git_root(path, expected_root)
        return Path(path)

    def git_status(self, root: Path | str) -> dict:
        return {"ok": True, **workspace_tools.git_status(self._repository(root))}

    def git_diff(self, root: Path | str, file: Any, section: str, *, expected_root: Any = None) -> dict:
        repository = self._repository(root, expected_root)
        return {"ok": True, **workspace_tools.git_diff(repository, file, section)}

    def git_stage(self, root: Path | str, file: Any, *, expected_root: Any = None) -> dict:
        repository = self._repository(root, expected_root)
        return {"ok": True, "file": workspace_tools.git_stage(repository, file)}

    def git_unstage(self, root: Path | str, file: Any, *, expected_root: Any = None) -> dict:
        repository = self._repository(root, expected_root)
        return {"ok": True, "file": workspace_tools.git_unstage(repository, file)}

    def git_open_file(self, root: Path | str, file: Any, *, reveal: bool = False, expected_root: Any = None) -> dict:
        if not isinstance(reveal, bool):
            raise LocalToolsError("reveal must be a boolean", code="invalid_git_open_reveal", status=400)
        repository = self._repository(root, expected_root)
        relative = _relative_git_path(str(repository), file)
        # Opening a symlink follows its target, unlike staging the symlink's inode.
        target = repository / relative
        if not target.resolve(strict=False).is_relative_to(repository):
            raise LocalToolsError("file must stay inside the repository", code="invalid_git_path", status=400)
        opened = _open_repository_file(str(repository), relative, reveal=reveal)
        return {"ok": True, "path": relative, "absolute_path": opened, "revealed": reveal}

    def git_commit_files(self, root: Path | str, commit_hash: Any, *, expected_root: Any = None) -> dict:
        repository = self._repository(root, expected_root)
        commit = _git_commit_hash(commit_hash)
        raw, truncated = workspace_tools._git(repository, ["diff-tree", "--diff-merges=first-parent", "--root", "--no-commit-id", "--name-status", "-r", "-z", commit])
        if truncated:
            raise LocalToolsError("Commit file list exceeds the response limit", code="git_output_too_large", status=413)
        entries = raw.split("\0")
        files = []
        index = 0
        while index + 1 < len(entries):
            status, name = entries[index:index + 2]
            index += 2
            if status.startswith(("R", "C")):
                if index >= len(entries):
                    raise LocalToolsError("Git returned invalid commit files", code="git_invalid_response", status=502)
                name = entries[index]
                index += 1
            if status and name:
                _relative_git_path(str(repository), name)
                files.append({"status": status, "file": name})
        return {"ok": True, "hash": commit, "files": files}

    def git_commit_diff(self, root: Path | str, commit_hash: Any, file: Any, *, expected_root: Any = None) -> dict:
        repository = self._repository(root, expected_root)
        commit = _git_commit_hash(commit_hash)
        relative = _relative_git_path(str(repository), file)
        output, truncated = workspace_tools._git(repository, ["show", "--format=", "--first-parent", "--no-ext-diff", "--no-textconv", commit, "--", relative], maximum_bytes=workspace_tools.MAX_DIFF_BYTES)
        return {"ok": True, "hash": commit, "file": relative, "diff": output, "truncated": truncated}

    def skills(self, root: Path | str) -> dict:
        return {"ok": True, **workspace_tools.skills(Path(_root_path(root)), environ=self.environ)}

    def search_files(self, root: Path | str, query: str, limit: int = 80) -> dict:
        if not isinstance(query, str) or "\x00" in query or len(query) > 512:
            raise LocalToolsError("query is invalid", code="invalid_file_query", status=400)
        maximum = _limit(limit, 500, "invalid_file_limit")
        return {"ok": True, **workspace_tools.search_files(Path(_root_path(root)), query, limit=maximum)}

    def jira_assigned(self, project: Optional[str] = None, limit: int = 50) -> dict:
        maximum = _limit(limit, 100, "invalid_jira_limit")
        return {"ok": True, **workspace_tools.jira_assigned(project=project or "", limit=maximum, environ=self.environ)}

    def jira_issue(self, query: str) -> dict:
        if not isinstance(query, str) or "\x00" in query or len(query) > 2048:
            raise LocalToolsError("Jira query is invalid", code="invalid_jira_key", status=400)
        return {"ok": True, **workspace_tools.jira_issue(query, environ=self.environ)}

    def github_review_requests(self) -> dict:
        return workspace_tools.github_review_requests(environ=self.environ)

    def upload_attachment(self, *, workspace_id: str, filename: str, content_type: str, data: bytes) -> dict:
        try:
            return {"ok": True, "attachment": attachments.store_attachment(workspace_id=workspace_id, filename=filename, content_type=content_type, data=data, environ=self.environ)}
        except attachments.AttachmentError as exc:
            raise LocalToolsError(str(exc), code=exc.code, status=exc.status) from exc

    def transcribe_voice(self, *, filename: str, mime_type: str, data: bytes) -> dict:
        try:
            return voice.transcribe(filename=filename, mime_type=mime_type, data=data, environ=self.environ)
        except voice.VoiceError as exc:
            raise LocalToolsError(str(exc), code=exc.code, status=exc.status) from exc


def _limit(value: Any, maximum: int, code: str) -> int:
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise LocalToolsError("limit is invalid", code=code, status=400) from exc
    if isinstance(value, bool) or not 1 <= result <= maximum:
        raise LocalToolsError("limit is invalid", code=code, status=400)
    return result
