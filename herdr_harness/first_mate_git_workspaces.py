"""Present recorded checkouts once and resolve an unambiguous feature branch."""
from __future__ import annotations

from pathlib import Path
from typing import Callable

from .git_comparison import repository_baseline
from .local_tools import _git_root_path
from .workspace_tools import WorkspaceToolError, _git


def inspect_checkout(path: str) -> dict:
    """Local Git evidence only. Never fetch, checkout, or infer from task titles."""
    if not path or "\0" in path or not Path(path).is_absolute():
        return {"available": False}
    try:
        root = _git_root_path(path)
        run = lambda args: _git(Path(root), args)[0].strip()
        head = run(["rev-parse", "--verify", "HEAD^{commit}"])
        common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        try:
            branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        except WorkspaceToolError:
            branch = None
        try:
            upstream = run(["rev-parse", "--symbolic-full-name", "@{upstream}"])
        except WorkspaceToolError:
            upstream = None
        target = repository_baseline(run, head)["baseline_label"]
        return {"path": root, "available": True, "branch": branch,
                "upstream": upstream, "target_branch": target, "common_dir": common}
    except (WorkspaceToolError, OSError, RuntimeError, ValueError):
        return {"available": False}


def workspace_catalog(feature: dict, assignments: list[dict], *,
                      inspect: Callable[[str], dict] = inspect_checkout) -> dict:
    sources = [{"id": "project", "path": feature["cwd"]}]
    for assignment in assignments:
        metadata = assignment.get("metadata") or {}
        path = metadata.get("worktree_path") if isinstance(metadata, dict) else None
        if assignment.get("feature_id") == feature["id"] and isinstance(path, str) and path:
            sources.append({"id": assignment["id"], "path": path})

    by_path: dict[str, dict] = {}
    inspections: dict[str, dict] = {}
    for source in sources:
        path = source["path"]
        try:
            key = str(Path(path).resolve()) if Path(path).is_absolute() and "\0" not in path else path
        except (OSError, RuntimeError, ValueError):
            key = path
        if key not in inspections:
            inspections[key] = inspect(path)
        facts = inspections[key]
        key = facts.get("path", key)
        if key in by_path:
            by_path[key]["aliases"].append(source["id"])
            continue
        branch = facts.get("branch")
        by_path[key] = {**source, **facts, "aliases": [],
                        "title": branch or Path(path).name or "Unavailable checkout"}

    rows = list(by_path.values())
    project = rows[0]
    # Tracking is an explicit Git relationship. Task names, timestamps, and
    # assignment order cannot establish which of many workers is canonical.
    tracked = [row for row in rows if row.get("available") and row.get("branch")
               and row.get("common_dir") == project.get("common_dir")
               and str(row.get("upstream") or "").startswith("refs/remotes/")
               and row["upstream"].removeprefix("refs/remotes/") != row.get("target_branch")
               and row["branch"] != str(row.get("target_branch") or "").removeprefix("origin/")]
    default = tracked[0] if len(tracked) == 1 else None
    if not tracked:
        workers = [row for row in rows if row["id"] != "project"]
        if len(workers) == 1 and workers[0].get("available") and workers[0].get("common_dir") == project.get("common_dir"):
            default = workers[0]
        elif not workers:
            default = project

    for row in rows:
        if row is default and (row["id"] != "project" or row in tracked):
            row["title"] = "Feature branch · " + row["title"]
        elif row["id"] == "project":
            row["title"] = "Project checkout · " + row["title"]
        if not row.get("available"):
            row["title"] += " (unavailable)"
        row.pop("common_dir", None)
    return {"ok": True, "workspaces": rows,
            "default_workspace_id": default["id"] if default else None,
            "selection_message": None if default else
                "Choose the checkout to review. This feature has multiple checkouts and no unique tracked feature branch."}
