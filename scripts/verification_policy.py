"""Which commits still need their tests run. Shared by Verify's plan job and
scripts/local-verify.py, so CI and the local Mac sign-off skip the same commits.

A commit needs no new test run when code that already passed is exactly the same
(the same Git tree, such as a squash merge of an up-to-date pull request), or when
it changes only files no build or test reads (docs, design studies, top-level
Markdown, release notes and the Mac version metadata) on top of a parent that
passed. The privacy scan is not governed by this: it runs on every new commit.

`is_verified` is given a `passed(sha)` predicate for the evidence that counts:
a successful push run of Verify in CI, or a success status from local-verify.py.
"""
from __future__ import annotations

import re
import subprocess
from typing import Callable, Iterable

# The commit status local-verify.py posts; publication and landing require it.
LOCAL_CONTEXT = "Mac tests (local)"
# Anything the iOS app builds from. Other changes cannot break its tests.
IOS_PATHS = re.compile(r"^(herdr-harness-ios/|HerdrFirstMateShared/|HerdrFirstMateSharedTests/|HerdrNotesShared/)")
# Files no build, package or test reads. release/macos.json is read only by the
# release script, which stamps the version into the app it builds.
UNTESTED_PATHS = re.compile(r"^(docs/|design/|release/notes/|release/macos\.json$|[^/]+\.md$)")

Git = Callable[..., subprocess.CompletedProcess]


def git(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *arguments], capture_output=True, text=True)


def untested_only(paths: Iterable[str]) -> bool:
    """True for a non-empty change that touches only files no test reads."""
    paths = [path for path in paths if path]
    return bool(paths) and all(UNTESTED_PATHS.match(path) for path in paths)


def tree(sha: str, run_git: Git = git) -> str | None:
    result = run_git("rev-parse", f"{sha}^{{tree}}")
    return result.stdout.strip() if result.returncode == 0 else None


def is_verified(sha: str, *, passed: Callable[[str], bool], pull_heads: Callable[[str], list[str]],
                head_tree: Callable[[str], str | None], run_git: Git = git) -> str | None:
    """Why `sha` already counts as tested, or None.

    Either it passed itself, or it is the merge of a pull request whose head
    passed with exactly the same tree.
    """
    if passed(sha):
        return f"{sha[:12]} already passed"
    own = tree(sha, run_git)
    for head in pull_heads(sha):
        if head != sha and own and head_tree(head) == own and passed(head):
            return f"same code as {head[:12]}, which passed"
    return None


def reusable_result(sha: str, *, passed: Callable[[str], bool], pull_heads: Callable[[str], list[str]],
                    head_tree: Callable[[str], str | None], run_git: Git = git) -> str | None:
    """Why `sha` needs no new test run, or None when its tests must run."""
    reason = is_verified(sha, passed=passed, pull_heads=pull_heads, head_tree=head_tree, run_git=run_git)
    if reason:
        return reason
    parent = run_git("rev-parse", "--verify", "--quiet", f"{sha}^1")
    if parent.returncode != 0 or run_git("rev-parse", "--verify", "--quiet", f"{sha}^2").returncode == 0:
        return None  # a root or merge commit changes more than one parent shows
    parent_sha = parent.stdout.strip()
    changed = run_git("diff", "--name-only", parent_sha, sha)
    if changed.returncode != 0 or not untested_only(changed.stdout.splitlines()):
        return None
    base = is_verified(parent_sha, passed=passed, pull_heads=pull_heads, head_tree=head_tree, run_git=run_git)
    return f"only docs or release metadata changed since {parent_sha[:12]} ({base})" if base else None
