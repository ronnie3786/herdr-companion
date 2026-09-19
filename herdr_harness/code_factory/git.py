"""Git worktree and branch operations against the configured checkout.

Repository-wide commands run as ``git -C <checkout> ...``; worktree-scoped helpers
take an explicit ``cwd``. A module-level lock serializes the worktree bookkeeping
commands (``add``/``remove``/``prune``), which git itself does not make safe to run
concurrently from several threads, and a second one serializes ``fetch`` so parallel
issue and release threads never race on ref locks in the shared checkout.

Every command runs with repository hooks disabled (``core.hooksPath`` pointed at the
null device through ``GIT_CONFIG_*``): the worktrees hold content written by model
sessions fed untrusted issue text, so nothing committed there may execute under the
daemon. Messages are forced to English (``LC_ALL=C``) because a few tolerant paths
recognise git's wording.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from ..child_environment import agent_environment
from .errors import CodeFactoryError

BRANCH_PATTERN = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
REF_PATTERN = re.compile(r"^[A-Za-z0-9._/@{}^~-]{1,256}$")
MAX_STDERR_CHARS = 300
DEFAULT_TIMEOUT = 600

Runner = Callable[..., Any]
_WORKTREE_LOCK = threading.Lock()
_FETCH_LOCK = threading.Lock()


def _failed(message: str) -> CodeFactoryError:
    return CodeFactoryError(message, code="git_failed")


def _invalid(message: str) -> CodeFactoryError:
    return CodeFactoryError(message, code="invalid_request")


def _trim(text: Any, limit: int = MAX_STDERR_CHARS) -> str:
    value = text.strip() if isinstance(text, str) else ""
    return value if len(value) <= limit else value[-limit:]


def _disable_hooks(env: dict[str, str]) -> None:
    """Append ``core.hooksPath=<null device>`` to the ``GIT_CONFIG_*`` overrides of ``env``."""
    try:
        count = max(0, int(env.get("GIT_CONFIG_COUNT") or 0))
    except ValueError:
        count = 0
    env[f"GIT_CONFIG_KEY_{count}"] = "core.hooksPath"
    env[f"GIT_CONFIG_VALUE_{count}"] = os.devnull
    env["GIT_CONFIG_COUNT"] = str(count + 1)


def validate_branch(value: Any, name: str = "branch") -> str:
    if not isinstance(value, str) or not BRANCH_PATTERN.match(value) or ".." in value \
            or value.startswith("-") or value.endswith("/") or value.endswith(".lock") or "//" in value:
        raise _invalid(f"invalid {name}")
    return value


def validate_ref(value: Any, name: str = "ref") -> str:
    if not isinstance(value, str) or not REF_PATTERN.match(value) or ".." in value or value.startswith("-"):
        raise _invalid(f"invalid {name}")
    return value


class GitRepository:
    """Worktree-aware git operations with an injectable runner and environment."""

    def __init__(
        self,
        checkout: str | Path,
        *,
        runner: Runner = subprocess.run,
        environ: Mapping[str, str] | None = None,
        git_binary: str = "git",
        timeout: int = DEFAULT_TIMEOUT,
    ):
        self.checkout = Path(checkout)
        self._runner = runner
        self._environ = dict(environ) if environ is not None else dict(os.environ)
        self._git = git_binary
        self.timeout = max(5, int(timeout))

    # -- plumbing -----------------------------------------------------------------

    def environment(self) -> dict[str, str]:
        """The child environment: ``HERDR_*`` stripped, no prompts, English messages, no hooks."""
        env = agent_environment(self._environ, integration=False)
        env.setdefault("GIT_TERMINAL_PROMPT", "0")
        env["LC_ALL"] = "C"
        env["LANGUAGE"] = "C"
        _disable_hooks(env)
        return env

    def _run(
        self,
        args: Sequence[str],
        *,
        cwd: str | Path | None = None,
        check: bool = True,
        timeout: int | None = None,
    ) -> Any:
        argv = [self._git, "-C", str(cwd if cwd is not None else self.checkout), *args]
        try:
            result = self._runner(
                argv,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=timeout or self.timeout,
                env=self.environment(),
            )
        except subprocess.TimeoutExpired as exc:
            raise _failed(f"git {args[0]} timed out") from exc
        except OSError as exc:
            raise _failed(f"git could not start: {_trim(str(exc))}") from exc
        if check and result.returncode != 0:
            detail = _trim(result.stderr) or _trim(result.stdout) or f"exit status {result.returncode}"
            raise _failed(f"git {' '.join(args[:2])} failed: {detail}")
        return result

    def _stdout(self, args: Sequence[str], *, cwd: str | Path | None = None, timeout: int | None = None) -> str:
        result = self._run(args, cwd=cwd, timeout=timeout)
        return result.stdout if isinstance(result.stdout, str) else ""

    # -- repository-wide ----------------------------------------------------------

    def fetch(self, remote: str = "origin") -> None:
        """``git fetch --prune``; serialized because concurrent fetches race on ref and packed-refs locks."""
        with _FETCH_LOCK:
            self._run(["fetch", "--prune", validate_ref(remote, "remote")], timeout=max(self.timeout, 900))

    def remote_url(self, remote: str = "origin") -> str:
        return self._stdout(["remote", "get-url", validate_ref(remote, "remote")]).strip()

    def resolve(self, ref: str) -> str:
        """The commit sha that ``ref`` points to."""
        return self._stdout(["rev-parse", "--verify", "--quiet", validate_ref(ref) + "^{commit}"]).strip()

    def branch_exists(self, branch: str) -> bool:
        result = self._run(["rev-parse", "--verify", "--quiet", "refs/heads/" + validate_branch(branch)], check=False)
        return result.returncode == 0

    def git_common_dir(self) -> Path:
        text = self._stdout(["rev-parse", "--path-format=absolute", "--git-common-dir"]).strip()
        return Path(text)

    def add_worktree(self, path: str | Path, branch: str | None, base_ref: str, *, detach: bool = False) -> dict[str, Any]:
        """Create a worktree at ``path``.

        With ``detach`` the worktree checks out ``base_ref`` detached. Otherwise the
        branch is created from ``base_ref`` when it does not exist yet, or checked out
        as-is when it does (so an interrupted run keeps its commits). Stale registrations
        (a worktree whose directory was deleted) are pruned first so they cannot block
        the new one.
        """
        target = Path(path)
        base = validate_ref(base_ref, "base_ref")
        if target.exists() and any(target.iterdir()):
            raise _invalid(f"worktree path already exists and is not empty: {target.name}")
        with _WORKTREE_LOCK:
            target.parent.mkdir(parents=True, exist_ok=True)
            self._run(["worktree", "prune"], check=False)
            if detach:
                self._run(["worktree", "add", "--detach", str(target), base], timeout=max(self.timeout, 900))
                name = None
            else:
                name = validate_branch(branch)
                if self.branch_exists(name):
                    self._run(["worktree", "add", str(target), name], timeout=max(self.timeout, 900))
                else:
                    self._run(["worktree", "add", "-b", name, str(target), base], timeout=max(self.timeout, 900))
        return {"path": str(target), "branch": name, "head": self.head(target)}

    def _orphaned_worktree(self, path: Path) -> bool:
        """True when ``path`` holds a ``.git`` pointer file into this checkout's worktree store."""
        pointer = path / ".git"
        if not pointer.is_file():
            return False
        try:
            text = pointer.read_text(encoding="utf-8", errors="ignore").strip()
        except OSError:
            return False
        if not text.startswith("gitdir:"):
            return False
        gitdir = Path(text[len("gitdir:"):].strip())
        try:
            common = self.git_common_dir().resolve()
            return gitdir.resolve().is_relative_to(common / "worktrees")
        except (OSError, CodeFactoryError):
            return False

    def remove_worktree(self, path: str | Path) -> bool:
        """Remove a worktree (``--force``); returns False when it was already gone.

        A locked worktree (``git worktree add`` locks the new tree while it initializes,
        so an interrupted add leaves the lock behind) is removed with a second ``--force``.
        """
        target = Path(path)
        with _WORKTREE_LOCK:
            result = self._run(["worktree", "remove", "--force", str(target)], check=False, timeout=max(self.timeout, 900))
            if result.returncode == 0:
                return True
            stderr = result.stderr if isinstance(result.stderr, str) else ""
            if "locked working tree" in stderr:
                result = self._run(["worktree", "remove", "--force", "--force", str(target)],
                                   check=False, timeout=max(self.timeout, 900))
                if result.returncode == 0:
                    return True
                stderr = result.stderr if isinstance(result.stderr, str) else ""
            if not target.exists():
                self._run(["worktree", "prune"], check=False)
                return False
            if "is not a working tree" in stderr and self._orphaned_worktree(target):
                shutil.rmtree(target, ignore_errors=True)
                self._run(["worktree", "prune"], check=False)
                return True
            raise _failed(f"git worktree remove failed: {_trim(stderr) or f'exit status {result.returncode}'}")

    def delete_branch(self, branch: str) -> bool:
        """Delete a local branch; returns False when it did not exist."""
        name = validate_branch(branch)
        result = self._run(["branch", "-D", name], check=False)
        if result.returncode == 0:
            return True
        stderr = result.stderr if isinstance(result.stderr, str) else ""
        if "not found" in stderr or "No such file" in stderr:
            return False
        raise _failed(f"git branch -D failed: {_trim(stderr) or f'exit status {result.returncode}'}")

    def prune_worktrees(self) -> None:
        with _WORKTREE_LOCK:
            self._run(["worktree", "prune"])

    def list_worktrees(self) -> list[dict[str, Any]]:
        """Registered worktrees as ``{path, head, branch, detached, bare, locked, prunable}``.

        ``prunable`` marks a registration whose directory no longer exists (what
        ``git worktree prune`` would drop); ``locked`` marks one git refuses to remove
        with a single ``--force``.
        """
        output = self._stdout(["worktree", "list", "--porcelain"])
        result: list[dict[str, Any]] = []
        current: dict[str, Any] | None = None
        for line in output.splitlines():
            if line.startswith("worktree "):
                current = {
                    "path": line[len("worktree "):], "head": None, "branch": None,
                    "detached": False, "bare": False, "locked": False, "prunable": False,
                }
                result.append(current)
            elif current is None:
                continue
            elif line.split(" ", 1)[0] == "locked":
                current["locked"] = True
            elif line.split(" ", 1)[0] == "prunable":
                current["prunable"] = True
            elif line.startswith("HEAD "):
                current["head"] = line[len("HEAD "):]
            elif line.startswith("branch "):
                ref = line[len("branch "):]
                current["branch"] = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
            elif line == "detached":
                current["detached"] = True
            elif line == "bare":
                current["bare"] = True
        return result

    def find_worktree(self, path: str | Path) -> dict[str, Any] | None:
        """The live registration at ``path``; stale ones (prunable or directory gone) count as absent."""
        wanted = Path(path)
        for entry in self.list_worktrees():
            if entry["prunable"]:
                continue
            try:
                registered = Path(entry["path"])
                if registered.is_dir() and registered.resolve() == wanted.resolve():
                    return entry
            except OSError:
                continue
        return None

    # -- worktree-scoped ----------------------------------------------------------

    def status_porcelain(self, cwd: str | Path) -> str:
        return self._stdout(["status", "--porcelain", "--untracked-files=all"], cwd=cwd)

    def is_clean(self, cwd: str | Path) -> bool:
        return not self.status_porcelain(cwd).strip()

    def head(self, cwd: str | Path) -> str:
        return self._stdout(["rev-parse", "HEAD"], cwd=cwd).strip()

    def current_branch(self, cwd: str | Path) -> str | None:
        result = self._run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd=cwd, check=False)
        text = result.stdout.strip() if isinstance(result.stdout, str) else ""
        return text or None

    def commit_all(self, cwd: str | Path, message: str) -> str | None:
        """``git add -A`` then commit; returns the new sha or ``None`` when nothing was staged."""
        if not isinstance(message, str) or not message.strip() or len(message) > 4000 or "\x00" in message:
            raise _invalid("commit message must be a non-empty string")
        self._run(["add", "-A"], cwd=cwd)
        staged = self._run(["diff", "--cached", "--quiet"], cwd=cwd, check=False)
        if staged.returncode == 0:
            return None
        if staged.returncode != 1:
            raise _failed(f"git diff --cached failed: {_trim(staged.stderr)}")
        self._run(["commit", "--quiet", "--no-verify", "-m", message], cwd=cwd)
        return self.head(cwd)

    def push(self, cwd: str | Path, remote: str, refspec: str, *, force: bool = False) -> None:
        if not isinstance(refspec, str) or not refspec or len(refspec) > 512 or refspec.startswith("-") or " " in refspec:
            raise _invalid("invalid refspec")
        args = ["push", "--quiet", "--no-verify"]
        if force:
            args.append("--force")
        args += [validate_ref(remote, "remote"), refspec]
        self._run(args, cwd=cwd, timeout=max(self.timeout, 900))

    def reset_hard(self, cwd: str | Path, ref: str = "HEAD") -> None:
        self._run(["reset", "--hard", "--quiet", validate_ref(ref)], cwd=cwd)

    def clean(self, cwd: str | Path) -> None:
        self._run(["clean", "-fd", "--quiet"], cwd=cwd)

    def checkout_detached(self, cwd: str | Path, ref: str) -> None:
        """Detach the worktree at ``ref`` (used to review a pull request head)."""
        self._run(["checkout", "--quiet", "--detach", validate_ref(ref)], cwd=cwd)

    def rebase(self, cwd: str | Path, onto: str) -> None:
        """Rebase the current branch onto ``onto``; aborts and raises on conflict."""
        result = self._run(["rebase", "--quiet", validate_ref(onto, "onto")], cwd=cwd, check=False)
        if result.returncode != 0:
            self._run(["rebase", "--abort"], cwd=cwd, check=False)
            raise _failed(f"git rebase failed: {_trim(result.stderr) or _trim(result.stdout) or 'conflict'}")

    def count_commits(self, cwd: str | Path, base_ref: str) -> int:
        """Commits reachable from HEAD but not from ``base_ref``."""
        text = self._stdout(["rev-list", "--count", validate_ref(base_ref, "base_ref") + "..HEAD"], cwd=cwd).strip()
        try:
            return int(text)
        except ValueError as exc:
            raise _failed("git rev-list returned no count") from exc

    def merge_base(self, cwd: str | Path, ref: str) -> str:
        """The merge base of ``ref`` and HEAD in ``cwd``."""
        text = self._stdout(["merge-base", validate_ref(ref), "HEAD"], cwd=cwd).strip()
        if not text:
            raise _failed("git merge-base returned no commit")
        return text

    def changed_files(self, cwd: str | Path, base_ref: str) -> list[str]:
        """Tracked paths whose working-tree content differs from the merge base of ``base_ref`` and HEAD.

        Committed, staged and unstaged changes all count; untracked files do not
        (``is_clean`` covers those). The merge base, not ``base_ref`` itself, is the
        reference so a branch that is merely behind the base is not reported as having
        changed files the base changed after it was created.
        """
        base = self.merge_base(cwd, base_ref)
        output = self._stdout(["diff", "--name-only", "--no-renames", "-z", base], cwd=cwd)
        return sorted({item for item in output.split("\0") if item})

    def log(self, cwd: str | Path, n: int = 20) -> list[dict[str, str]]:
        """Recent commits as ``{sha, subject}`` newest first."""
        count = max(1, min(int(n), 500))
        output = self._stdout(["log", f"--max-count={count}", "--format=%H%x09%s"], cwd=cwd)
        entries: list[dict[str, str]] = []
        for line in output.splitlines():
            sha, _, subject = line.partition("\t")
            if sha:
                entries.append({"sha": sha, "subject": subject})
        return entries
