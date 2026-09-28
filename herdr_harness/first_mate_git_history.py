"""Retain observed Git intervals for workflow visits, without guessing old history."""
from __future__ import annotations

from pathlib import Path
import re
import subprocess
from typing import Callable

from .git_comparison import repository_baseline
from .workspace_tools import WorkspaceToolError

_SHA = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
MAX_VISIT_COMMITS = 1000


def recorded_comparison_baseline(snapshot: dict, workspace_id: str) -> dict | None:
    """Keep the first observed target boundary when its branch later moves."""
    for visit in sorted(snapshot.get("visits", []), key=lambda item: (item.get("created_at", ""), item["id"])):
        for record in [*(visit.get("git_baselines") or []), *(visit.get("git_evidence") or [])]:
            if record.get("workspace_id") == workspace_id and _SHA.fullmatch(record.get("comparison_baseline_sha") or ""):
                return record
    return None


def capture_comparison_baseline(path: str, revision: str | None, git: Callable[..., str], *,
                                prior: dict | None = None) -> dict:
    """The target tree is distinct from the revision where a step starts."""
    if prior and _SHA.fullmatch(prior.get("comparison_baseline_sha") or ""):
        return {"comparison_baseline_sha": prior["comparison_baseline_sha"],
                "comparison_baseline_label": prior.get("comparison_baseline_label") or "Target branch"}
    if not isinstance(revision, str) or not _SHA.fullmatch(revision):
        return {}
    try:
        def run(arguments: list[str]) -> str:
            try:
                return git(path, *arguments)
            except (RuntimeError, OSError, subprocess.SubprocessError) as error:
                raise WorkspaceToolError("Recorded workspace Git is unavailable", code="git_unavailable", status=409) from error
        baseline = repository_baseline(run, revision)
        return {"comparison_baseline_sha": baseline["baseline_sha"],
                "comparison_baseline_label": baseline["baseline_label"]}
    except WorkspaceToolError:
        return {}


def workspace_sources(snapshot: dict) -> list[dict]:
    """Canonical routes come from stored feature/assignment IDs, never labels."""
    sources = [{"workspace_id": "project", "path": snapshot["feature"]["cwd"]}]
    seen = {str(Path(sources[0]["path"]).resolve())}
    for assignment in snapshot["assignments"]:
        metadata = assignment.get("metadata", {})
        path = metadata.get("worktree_path")
        if not isinstance(path, str) or not path:
            continue
        identity = str(Path(path).resolve())
        if identity in seen:
            continue
        seen.add(identity)
        sources.append({"workspace_id": assignment["id"], "path": path,
                        "visit_id": assignment["visit_id"], "base_revision": metadata.get("base_revision"),
                        **{key: metadata[key] for key in ("comparison_baseline_sha", "comparison_baseline_label") if key in metadata}})
    return sources


def capture_baselines(snapshot: dict, git: Callable[..., str]) -> list[dict]:
    records = []
    for source in workspace_sources(snapshot):
        record = {"workspace_id": source["workspace_id"], "start_sha": None}
        try:
            revision = git(source["path"], "rev-parse", "HEAD")
            if _SHA.fullmatch(revision):
                record["start_sha"] = revision
                prior = recorded_comparison_baseline(snapshot, source["workspace_id"]) or source
                record.update(capture_comparison_baseline(source["path"], revision, git, prior=prior))
        except (RuntimeError, OSError, subprocess.SubprocessError):
            pass
        records.append(record)
    return records


def capture_commits(snapshot: dict, visit: dict, git: Callable[..., str], *,
                    end_baselines: list[dict] | None = None) -> list[dict]:
    baselines = {record["workspace_id"]: record
                 for record in visit.get("git_baselines", [])}
    ends = ({record["workspace_id"]: record.get("start_sha") for record in end_baselines}
            if end_baselines is not None else None)
    records = []
    for source in workspace_sources(snapshot):
        baseline = baselines.get(source["workspace_id"], {})
        start = baseline.get("start_sha")
        # A newly created worktree has its exact pre-launch revision retained.
        # A legacy visit has no observed interval and must remain unknown.
        if (source["workspace_id"] not in baselines and visit.get("git_baselines")
                and source.get("visit_id") == visit["id"]):
            start = source.get("base_revision")
            baseline = source
        record = {"workspace_id": source["workspace_id"], "start_sha": start,
                  "end_sha": None, "status": "unavailable", "commits": [], "truncated": False,
                  **{key: baseline[key] for key in ("comparison_baseline_sha", "comparison_baseline_label") if key in baseline}}
        records.append(record)
        if not isinstance(start, str) or not _SHA.fullmatch(start):
            continue
        try:
            end = ends.get(source["workspace_id"]) if ends is not None else git(source["path"], "rev-parse", "HEAD")
            if not isinstance(end, str) or not _SHA.fullmatch(end):
                continue
            record["end_sha"] = end
            # Rebase/reset cannot establish which changes this visit produced.
            git(source["path"], "merge-base", "--is-ancestor", start, end)
            rows = git(source["path"], "log", "--reverse", "--topo-order",
                       f"--max-count={MAX_VISIT_COMMITS + 1}", "--format=%H%x00%s%x00%cI",
                       f"{start}..{end}").splitlines()
            commits = []
            for row in rows:
                sha, subject, committed_at = row.split("\x00", 2)
                if not _SHA.fullmatch(sha):
                    raise ValueError("Unexpected Git revision")
                commits.append({"sha": sha, "subject": subject, "committed_at": committed_at})
            record.update(status="captured", commits=commits[-MAX_VISIT_COMMITS:],
                          truncated=len(commits) > MAX_VISIT_COMMITS)
        except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
            pass
    return records
