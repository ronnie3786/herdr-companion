"""Revision-pinned Git comparisons shared by review and workspace adapters.

The adapter owns repository authorization and freshness. This module accepts
only full commit IDs selected from its bounded reachable history; user refs
never become Git revision expressions or pathspecs.
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Callable

from .pr_review_diff import parse_unified_diff
from .workspace_tools import WorkspaceToolError

MAX_COMMITS = 1000
SHA = re.compile(r"(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})\Z")


def comparison_request(value: dict | None) -> dict:
    if value is None:
        return {"mode": "all"}
    if not isinstance(value, dict) or set(value) - {"mode", "start_commit", "end_commit"}:
        raise WorkspaceToolError("Invalid Git comparison", code="invalid_git_comparison", status=400)
    mode = value.get("mode", "all")
    if mode not in {"all", "commit", "range", "working-tree"}:
        raise WorkspaceToolError("Invalid comparison mode", code="invalid_git_comparison", status=400)
    start, end = value.get("start_commit"), value.get("end_commit")
    if mode == "all":
        if start is not None or end is not None:
            raise WorkspaceToolError("All changes cannot specify commits", code="invalid_git_comparison", status=400)
        return {"mode": mode}
    if mode == "working-tree":
        if end is not None or (start is not None and (not isinstance(start, str) or not SHA.fullmatch(start))):
            raise WorkspaceToolError("Invalid working tree comparison", code="invalid_git_comparison", status=400)
        return {"mode": mode, **({"start_commit": start.lower()} if start else {})}
    if not isinstance(start, str) or not SHA.fullmatch(start) or (mode == "range" and (not isinstance(end, str) or not SHA.fullmatch(end))):
        raise WorkspaceToolError("Choose full commit IDs from this history", code="invalid_git_comparison", status=400)
    if mode == "commit" and end is not None:
        raise WorkspaceToolError("A single commit cannot specify an end commit", code="invalid_git_comparison", status=400)
    return {"mode": mode, "start_commit": start.lower(), **({"end_commit": end.lower()} if mode == "range" else {})}


def comparison_identity(mode: str, before: str, after: str, commits: list[str]) -> dict:
    digest = hashlib.sha256(json.dumps([mode, before, after], separators=(",", ":")).encode()).hexdigest()
    return {"id": "gitcmp_" + digest, "mode": mode, "before_sha": before, "after_sha": after, "commit_shas": commits}


def first_parent_history(run: Callable[[list[str]], str], head: str, base: str | None = None) -> list[dict]:
    if not SHA.fullmatch(head) or (base is not None and not SHA.fullmatch(base)):
        raise WorkspaceToolError("Git history has no pinned revision", code="invalid_git_revision", status=409)
    arguments = ["log", "--topo-order", "--format=%H%x00%P%x00%s%x00%an%x00%aI", "-z", f"--max-count={MAX_COMMITS + 1}", head]
    if base is not None:
        arguments.append("^" + base)
    raw = run(arguments + ["--"])
    fields = raw.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    if not fields:
        return []
    if len(fields) % 5:
        raise WorkspaceToolError("Git returned invalid history", code="git_invalid_response", status=502)
    commits = []
    for offset in range(0, len(fields), 5):
        sha, parents, subject, author, authored = fields[offset:offset + 5]
        if not SHA.fullmatch(sha) or any(not SHA.fullmatch(parent) for parent in parents.split()):
            raise WorkspaceToolError("Git returned invalid history", code="git_invalid_response", status=502)
        commits.append({"sha": sha, "parents": parents.split(), "subject": subject, "author_name": author, "authored_at": authored})
    if len(commits) > MAX_COMMITS:
        raise WorkspaceToolError("Git history exceeds the comparison limit of 1000 commits", code="git_history_too_large", status=413)
    return list(reversed(commits))


def resolve_comparison(request: dict | None, commits: list[dict], *, before: str, after: str) -> dict:
    request = comparison_request(request)
    mode = request["mode"]
    if mode == "all":
        return comparison_identity(mode, before, after, [item["sha"] for item in commits])
    indexes = {before: -1, **{item["sha"]: index for index, item in enumerate(commits)}}
    start = request.get("start_commit", before)
    end = request.get("end_commit", start)
    if start not in indexes or (mode != "working-tree" and end not in indexes):
        raise WorkspaceToolError("Selected commit is outside this history", code="git_commit_out_of_scope", status=400)
    parents = {item["sha"]: item["parents"] for item in commits}
    def ancestry(sha):
        seen, pending = set(), [sha]
        while pending:
            value = pending.pop()
            if value in seen: continue
            seen.add(value)
            pending.extend(parents.get(value, []))
        return seen
    def included(left, right):
        difference = ancestry(right) - ancestry(left)
        return [item["sha"] for item in commits if item["sha"] in difference]
    if mode == "working-tree":
        return comparison_identity(mode, start, "working-tree", included(start, after))
    if mode == "commit":
        return comparison_identity(mode, before, start, included(before, start))
    first, last = indexes[start], indexes[end]
    if first > last:
        raise WorkspaceToolError("Select endpoints from older to newer revisions", code="invalid_git_comparison", status=400)
    after_ancestors, before_ancestors = ancestry(end), ancestry(start)
    if start != before and start not in after_ancestors:
        raise WorkspaceToolError("The left revision must be an ancestor of the right revision", code="git_endpoints_not_ancestral", status=400)
    return comparison_identity(mode, start, end, [item["sha"] for item in commits if item["sha"] in after_ancestors - before_ancestors])


def empty_tree_sha(length: int) -> str:
    return (hashlib.sha256 if length == 64 else hashlib.sha1)(b"tree 0\0").hexdigest()


def comparison_patch(run: Callable[[list[str]], tuple[str, bool]], comparison: dict, path: str | None = None) -> dict:
    if path is not None and (not isinstance(path, str) or not path or path.startswith("/") or "\0" in path or any(part in {".", ".."} for part in path.split("/"))):
        raise WorkspaceToolError("File must stay within the repository", code="invalid_git_path", status=400)
    # Enumerate metadata first so single-file reads retain both rename paths
    # and late files remain discoverable beyond the textual patch budget.
    revisions = [comparison["before_sha"]] + ([] if comparison["mode"] == "working-tree" else [comparison["after_sha"]])
    common = ["--no-ext-diff", "--no-textconv", "--find-renames", *revisions, "--"]
    metadata, metadata_truncated = run(["-c", "core.quotePath=false", "diff", "--name-status", "-z", *common])
    if metadata_truncated:
        raise WorkspaceToolError("Changed file list exceeds the response limit", code="git_output_too_large", status=413)
    fields = metadata.split("\0")
    catalog = []
    index = 0
    while index < len(fields) and fields[index]:
        status = fields[index]
        index += 1
        count = 2 if status.startswith(("R", "C")) else 1
        if index + count > len(fields) or any(not field for field in fields[index:index + count]):
            raise WorkspaceToolError("Git returned invalid changed files", code="git_invalid_response", status=502)
        names = fields[index:index + count]
        index += count
        catalog.append({"path": names[-1], "old_path": names[0] if count == 2 else None if status == "A" else names[0],
                        "status": {"A": "added", "D": "deleted", "R": "renamed", "C": "copied"}.get(status[:1], "modified")})
    selected_paths = []
    if path is not None:
        selected = next((item for item in catalog if item["path"] == path), None)
        if selected is not None:
            selected_paths = list(dict.fromkeys(value for value in (selected.get("old_path"), path) if value))
        else:
            return {"comparison": comparison, "files": [], "diff": "", "truncated": False}
    patch, truncated = run(["-c", "core.quotePath=false", "diff", "--unified=3", *common, *selected_paths])
    parsed_files = {item["path"]: item for item in parse_unified_diff(patch, truncated=truncated)}
    pieces = re.split(r"(?=^diff --git )", patch, flags=re.MULTILINE)
    for piece in pieces:
        parsed = parse_unified_diff(piece)
        if parsed and parsed[0]["path"] in parsed_files:
            parsed_files[parsed[0]["path"]]["patch"] = piece
    files = []
    for metadata in catalog:
        item = parsed_files.get(metadata["path"])
        if item is None:
            item = {**metadata, "additions": 0, "deletions": 0, "binary": False, "truncated": truncated, "hunks": [], "patch": ""}
        else:
            # Binary output must not erase an added/deleted/renamed identity.
            item.update(metadata)
        files.append(item)
    if path is not None:
        files = [item for item in files if item["path"] == path]
        patch = "".join(item.get("patch", "") for item in files)
    return {"comparison": comparison, "files": files, "diff": patch, "truncated": truncated}


def repository_history(run: Callable[[list[str]], str], baseline: dict | None = None) -> dict:
    """Use the recorded repository's target branch, never a client root/ref."""
    head = run(["rev-parse", "--verify", "HEAD^{commit}"]).strip()
    if baseline is not None:
        sha = baseline.get("sha", "")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise WorkspaceToolError("The saved workspace baseline is invalid", code="invalid_git_revision", status=409)
        try:
            run(["merge-base", "--is-ancestor", sha, head])
        except WorkspaceToolError as error:
            raise WorkspaceToolError("The saved workspace baseline is no longer in this history", code="git_baseline_unavailable", status=409) from error
        return {"head_sha": head, "baseline_sha": sha, "baseline_label": baseline.get("label") or "Feature start", "commits": first_parent_history(run, head, sha)}
    target = repository_baseline(run, head)
    return {"head_sha": head, **target, "commits": first_parent_history(run, head, target["baseline_sha"])}


def repository_baseline(run: Callable[[list[str]], str], head: str) -> dict:
    """Resolve the target tree at an observed commit without enumerating history.

    Workflow inception persists this separately from the step's start revision,
    so feature commits that predate the step remain visible after target moves.
    """
    if not isinstance(head, str) or not SHA.fullmatch(head):
        raise WorkspaceToolError("Git baseline has no pinned revision", code="invalid_git_revision", status=409)
    candidates = ["refs/remotes/origin/develop", "refs/heads/develop"]
    try:
        candidates.append(run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]).strip())
    except WorkspaceToolError:
        pass
    candidates += ["refs/remotes/origin/develop", "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/develop", "refs/heads/main", "refs/heads/master"]
    for candidate in dict.fromkeys(candidates):
        if not candidate:
            continue
        try:
            baseline = run(["merge-base", head, candidate]).strip()
        except WorkspaceToolError:
            continue
        if SHA.fullmatch(baseline):
            return {"baseline_sha": baseline, "baseline_label": candidate.removeprefix("refs/remotes/").removeprefix("refs/heads/")}
    roots = run(["rev-list", "--max-parents=0", "--reverse", head, "--"]).splitlines()
    baseline = next((sha for sha in roots if SHA.fullmatch(sha)), head)
    return {"baseline_sha": baseline, "baseline_label": "Initial commit"}
