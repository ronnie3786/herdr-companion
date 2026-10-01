"""Feature-owned Git workspaces, independent of assignment/session lifetimes."""
from __future__ import annotations

import hashlib
from pathlib import Path

from .first_mate_store import FirstMateError


def path_key(path: str | Path) -> str:
    return str(Path(path).resolve())


def lock_path(root: Path, cwd: str) -> Path:
    identity = hashlib.sha256(path_key(cwd).encode()).hexdigest()
    return root / "workspace-locks" / (identity + ".lock")


def independent_path(root: Path, metadata: dict) -> str:
    value = metadata.get("execution_path")
    if not isinstance(value, str) or not value:
        raise FirstMateError("Independent workspace has no execution path", code="workspace_identity_mismatch")
    path = Path(value)
    parent = root / "independent-workspaces"
    if (not path.is_absolute() or path.is_symlink() or parent.is_symlink() or path.parent.resolve() != parent.resolve()
            or not path.resolve().is_relative_to(root.resolve())):
        raise FirstMateError("Independent workspace identity changed", code="workspace_identity_mismatch")
    if not path.is_dir():
        raise FirstMateError("The retained independent workspace is missing", code="workspace_missing")
    return str(path)


class FeatureWorkspaces:
    def __init__(self, runtime, read, write):
        self.runtime, self.read, self.write = runtime, read, write

    def record_path(self, feature: dict) -> Path:
        return self.runtime.root / "feature-workspaces" / (hashlib.sha256(feature["id"].encode()).hexdigest() + ".json")

    def identity(self, feature: dict, path: str, expected: dict | None = None) -> dict:
        """Validate a linked checkout's identity, allowing commits and branch renames."""
        git = self.runtime._git
        root = Path(path).resolve()
        managed = (self.runtime.root / "worktrees").resolve()
        if root == managed or not root.is_relative_to(managed) or root == Path(feature["cwd"]).resolve():
            raise FirstMateError("This is not a managed feature worktree", code="workspace_identity_mismatch")
        if not root.is_dir():
            raise FirstMateError("The retained feature worktree is missing. Inspect its saved branch and recovery evidence; it will not be recreated or reset automatically.", code="workspace_missing")
        actual = git(str(root), "rev-parse", "--show-toplevel")
        git_dir = path_key(git(str(root), "rev-parse", "--absolute-git-dir"))
        common = path_key(root / git(str(root), "rev-parse", "--git-common-dir"))
        project_common = path_key(Path(feature["cwd"]) / git(feature["cwd"], "rev-parse", "--git-common-dir"))
        if path_key(actual) != str(root) or common != project_common or git_dir == common:
            raise FirstMateError("The retained worktree no longer belongs to this feature's repository", code="workspace_identity_mismatch")
        branch = git(str(root), "branch", "--show-current")
        if not branch:
            raise FirstMateError("The feature worktree has a detached HEAD. Preserve its changes and select its feature branch before continuing.", code="workspace_detached")
        if expected and (expected.get("git_dir") != git_dir or expected.get("common_dir") != common):
            raise FirstMateError("The retained worktree's Git identity changed", code="workspace_identity_mismatch")
        return {"path": str(root), "git_dir": git_dir, "common_dir": common, "branch": branch}

    def _owned(self, feature: dict) -> tuple[list[dict], dict[str, list[dict]]]:
        assignments = self.runtime.store.list_assignments(feature_id=feature["id"])
        paths: dict[str, list[dict]] = {}
        for assignment in assignments:
            metadata = assignment.get("metadata", {})
            if metadata.get("workspace_mode") == "isolated" and metadata.get("worktree_path"):
                paths.setdefault(path_key(metadata["worktree_path"]), []).append(assignment)
        return assignments, paths

    def select(self, feature: dict, params: dict) -> dict:
        """Choose from durable ownership/lineage, never labels, age, or commit counts."""
        strategy = params.get("workspace_strategy", "feature")
        mode = params.get("workspace_mode", "read_only")
        if strategy not in {"feature", "fork"}:
            raise FirstMateError("workspace_strategy must be feature or fork", code="invalid_request", status=400)
        reason = params.get("fork_reason")
        if strategy == "fork" and (mode != "isolated" or not isinstance(reason, str) or not reason.strip() or len(reason) > 1000):
            raise FirstMateError("A fork needs an isolated assignment and a bounded fork_reason explaining the independent work", code="invalid_request", status=400)
        if strategy != "fork" and reason is not None:
            raise FirstMateError("fork_reason is only valid with workspace_strategy=fork", code="invalid_request", status=400)
        assignments, owned = self._owned(feature)
        record = self.record_path(feature)
        primary = self.read(record)
        if record.exists() and (not isinstance(primary, dict) or not all(isinstance(primary.get(k), str) and primary[k] for k in ("feature_id", "path", "git_dir", "common_dir"))):
            raise FirstMateError("The retained feature workspace record is unreadable; inspect it before continuing", code="workspace_identity_mismatch")
        if primary and primary.get("feature_id") != feature["id"]:
            raise FirstMateError("Feature workspace ownership changed", code="workspace_identity_mismatch")
        source_id = params.get("source_assignment_id")
        source = self.runtime.store.get_assignment(source_id) if source_id else None
        if source and source["feature_id"] != feature["id"]:
            raise FirstMateError("Source assignment belongs to another feature")
        if source and source.get("metadata", {}).get("workspace_mode") == "independent":
            raise FirstMateError("Independent assignments have no source checkout; omit source_assignment_id or select a code assignment", code="workspace_selection_required")
        if source:
            path = source.get("metadata", {}).get("worktree_path") or feature["cwd"]
        elif primary:
            path = primary["path"]
        elif owned:
            by_id = {a["id"]: a for a in assignments}
            ancestors = set()
            for assignment in assignments:
                metadata = assignment.get("metadata", {})
                parent = by_id.get(metadata.get("source_assignment_id"))
                if parent and metadata.get("workspace_strategy") != "fork":
                    child_path = path_key(metadata.get("worktree_path") or feature["cwd"])
                    parent_path = path_key(parent.get("metadata", {}).get("worktree_path") or feature["cwd"])
                    if child_path in owned and parent_path in owned and child_path != parent_path:
                        ancestors.add(parent_path)
            leaves = set(owned) - ancestors
            if len(leaves) != 1:
                choices = [{"tool": "fm_delegate", "source_assignment_id": owned[p][-1]["id"]} for p in sorted(leaves or owned)]
                raise FirstMateError("This feature has independent retained worktrees. Select the exact source_assignment_id to continue; no new checkout was created.", code="workspace_selection_required", next_permitted_actions=choices)
            path = next(iter(leaves))
        else:
            path = feature["cwd"]
        key = path_key(path)
        managed = key in owned or bool(primary and key == path_key(primary["path"]))
        if managed:
            expected = primary if primary and key == path_key(primary["path"]) else None
            identity = self.identity(feature, path, expected)
            if not source_id and owned.get(key):
                source_id = owned[key][-1]["id"]
            for record in owned.get(key, []):
                if record["status"] == "recovering":
                    raise FirstMateError("Continue the interrupted assignment with fm_recover before delegating replacement work in its workspace.", code="workspace_recovery_required", next_permitted_actions=record.get("next_permitted_actions", []))
        else:
            identity = None
        if mode == "isolated" and strategy != "fork" and not managed and (owned or primary):
            raise FirstMateError("The requested source is outside the feature workspace. Continue an owned source_assignment_id, or explicitly fork independent work.", code="workspace_selection_required")
        if strategy == "fork" and self.runtime._git(path, "status", "--porcelain"):
            raise FirstMateError("Commit the source workspace before forking. A fork copies committed history, never drops or copies dirty edits implicitly.", code="workspace_dirty")
        return {"source": path, "source_assignment_id": source_id, "identity": identity,
                "reuse": managed and strategy != "fork", "strategy": strategy,
                "make_primary": mode == "isolated" and (strategy != "fork" or primary is None and not owned)}

    def remember(self, feature: dict, metadata: dict, *, primary: bool) -> None:
        identity = self.identity(feature, metadata["worktree_path"], metadata.get("workspace_identity"))
        if primary:
            self.write(self.record_path(feature), {"feature_id": feature["id"], **identity})

    def integrated_forks(self, feature: dict, assignments: list[dict]) -> dict[str, str]:
        """Only Git ancestry plus settled ownership can retire a fork's evidence."""
        primary = self.read(self.record_path(feature))
        if not isinstance(primary, dict) or not primary.get("path"):
            return {}
        candidates = {a["metadata"]["worktree_path"] for a in assignments
                      if a.get("metadata", {}).get("workspace_strategy") == "fork"}
        result = {}
        for path in candidates:
            if path_key(path) == path_key(primary["path"]):
                continue
            owners = [a for a in assignments if path_key(a.get("metadata", {}).get("worktree_path") or feature["cwd"]) == path_key(path)]
            if any(a["status"] not in {"completed", "superseded", "cancelled"} for a in owners):
                continue
            try:
                self.identity(feature, primary["path"], primary)
                self.identity(feature, path)
                if self.runtime._git(path, "status", "--porcelain"):
                    continue
                tip = self.runtime._git(path, "rev-parse", "HEAD")
                self.runtime._git(primary["path"], "merge-base", "--is-ancestor", tip, "HEAD")
            except (FirstMateError, OSError):
                continue
            result[path] = primary["path"]
        return result
