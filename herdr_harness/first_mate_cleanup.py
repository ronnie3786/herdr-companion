"""Host-local cleanup of resources created and owned by First Mate.

No recursive search for candidates, force Git commands, or caller-supplied
deletion paths. One resource is processed per scheduler pass. SQL transactions
fence archive/unarchive and resource allocation against each destructive step.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

from . import first_mate_archive as archive
from .first_mate_store import FirstMateError


class RetainResource(Exception):
    pass


class FirstMateCleanup:
    def __init__(self, runtime):
        self.runtime = runtime
        self.store = runtime.store
        self.root = runtime.root

    @staticmethod
    def _identity(path):
        info = Path(path).lstat()
        return {"device": info.st_dev, "inode": info.st_ino}

    @staticmethod
    def _git(cwd, *args, input=None, no_optional_locks=False):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if no_optional_locks:
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        process = subprocess.run(["git", "-C", str(cwd), *args], input=input, text=True,
                                 capture_output=True, timeout=30, env=environment)
        if process.returncode:
            raise RetainResource("Git safety check did not succeed: " + process.stderr.strip()[:400])
        return process.stdout.strip()

    def register_worktree(self, feature, path, branch):
        """Only called immediately after this runtime creates a new worktree."""
        path = Path(path)
        if path.parent != self.root / "worktrees" or path.is_symlink():
            raise ValueError("Invalid managed worktree location")
        repository = Path(self._git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
        try:
            integration = self._git(feature["cwd"], "symbolic-ref", "-q", "HEAD")
        except RetainResource:
            integration = ""
        metadata = {"repository": str(repository), "repository_identity": self._identity(repository),
                    "integration_ref": integration, "branch": branch, "worktree_path": str(path)}
        with self.store._transaction():
            self._register(feature["id"], "worktree", str(path), self._identity(path), metadata)
            self._register(feature["id"], "branch", str(repository) + "#refs/heads/" + branch,
                           self._identity(repository), metadata)

    def _register(self, feature_id, kind, path, identity, metadata):
        resource_id = "resource_" + hashlib.sha256((kind + path).encode()).hexdigest()[:32]
        self.store._db.execute("""INSERT INTO fm_owned_resources
            (id,feature_id,kind,path,identity_json,metadata_json,created_at) VALUES(?,?,?,?,?,?,?)""",
            (resource_id, feature_id, kind, path, archive.encoded(identity), archive.encoded(metadata), archive.now()))
        return resource_id

    def allocate(self, feature_id, kind, request_id):
        """Allocate disposable build/cache space. Never adopt an existing path."""
        if not isinstance(kind, str) or kind not in {"temporary_build", "cache"}:
            raise FirstMateError("Use temporary_build or cache", code="invalid_request", status=400)
        from .first_mate_store import _text
        request_id = _text(request_id, "request_id", 200)
        with self.store._transaction():
            cached = self.store._receipt("resource:" + feature_id, request_id, {"kind": kind})
            if cached is not None:
                return cached
            feature = self.store._one("fm_features", feature_id)
            if feature["archived_at"] or feature["status"] in {"completed", "cancelled"}:
                raise FirstMateError("Disposable space requires an open, unarchived session")
            token = hashlib.sha256((feature_id + request_id).encode()).hexdigest()[:32]
            parent = self.root / "disposable" / feature_id
            parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if parent.resolve() != parent:
                raise FirstMateError("Disposable resource parent must not be a symbolic link")
            path = parent / token
            # A crash before the ownership transaction commits leaves an orphan
            # which is deliberately not adopted on retry.
            path.mkdir(mode=0o700)
            resource_id = self._register(feature_id, kind, str(path), self._identity(path), {})
            result = {"id": resource_id, "kind": kind, "path": str(path),
                      "retention": "Disposable. Removed after completion and archive. Save final deliverables elsewhere."}
            return self.store._save_receipt("resource:" + feature_id, request_id, {"kind": kind}, result)

    def _resources(self, feature_id):
        with self.store._lock:
            return [dict(row) for row in self.store._db.execute("""SELECT * FROM fm_owned_resources WHERE feature_id=?
                ORDER BY CASE kind WHEN 'branch' THEN 1 ELSE 0 END,created_at,id""", (feature_id,))]

    def preview(self, feature_id):
        """Build the same conservative resource inventory used by cleanup."""
        with self.store._lock:
            feature = self.store._one("fm_features", feature_id)
            rows = self._resources(feature_id)
            documents = self.store._db.execute(
                "SELECT id,content_hash FROM fm_documents WHERE feature_id=? ORDER BY id", (feature_id,)).fetchall()
            messages = self.store._db.execute(
                "SELECT id,updated_at FROM fm_messages WHERE feature_id=? ORDER BY id", (feature_id,)).fetchall()
            document_count, message_count = len(documents), len(messages)
            inspected = []
            by_id = {}
            for row in rows:
                if row["kind"] == "branch":
                    continue
                item = self._inspect_resource(row, feature)
                inspected.append(item)
                by_id[row["id"]] = item
            for row in rows:
                if row["kind"] != "branch":
                    continue
                item = self._inspect_resource(row, feature, inspected=by_id)
                inspected.append(item)
                by_id[row["id"]] = item
            eligible = feature["status"] == "completed" and feature["archived_at"] is None
            if feature["status"] != "completed":
                ineligible_reason = "Only a completed session can start archive cleanup."
            elif feature["archived_at"] is not None:
                ineligible_reason = "This session is already archived."
            else:
                ineligible_reason = None
            defaults = [item["id"] for item in inspected if item["selected_by_default"]]
            token_value = {"feature_id": feature_id, "feature_revision": feature["revision"],
                           "status": feature["status"], "archived_at": feature["archived_at"],
                           "resources": inspected, "document_count": document_count,
                           "message_count": message_count,
                           "documents": [tuple(item) for item in documents],
                           "messages": [tuple(item) for item in messages]}
            token = hashlib.sha256(archive.encoded(token_value).encode()).hexdigest()
            public_resources = [{key: value for key, value in item.items() if key != "_observation"}
                                for item in inspected]
            return {"feature_id": feature_id, "feature_revision": feature["revision"], "token": token,
                    "generated_at": archive.now(), "eligible": eligible, "ineligible_reason": ineligible_reason,
                    "resources": public_resources, "document_count": document_count, "message_count": message_count,
                    "cleanup_options": {"resource_ids": defaults, "keep_documents": True, "keep_chat": True},
                    "retention": {
                        "documents": {
                            "keep": "Keep readable live document bodies and the immutable completion catalog.",
                            "compact": "Keep original bodies in the immutable completion catalog and replace live document bodies with catalog pointers. SQLite file size may not shrink immediately.",
                        },
                        "chat": {
                            "keep": "Keep the readable live conversation and the immutable completion catalog.",
                            "compact": "Keep the original conversation in the immutable completion catalog and replace live message bodies with catalog pointers. SQLite file size may not shrink immediately.",
                        },
                    },
                    "size_semantics": "Logical file sizes; null means unknown. Filesystem free space can differ because of clones, hard links, compression, and SQLite reuse."}

    def _inspect_resource(self, resource, feature, inspected=None):
        result = {"id": resource["id"], "kind": resource["kind"], "path": resource["path"],
                  "estimated_bytes": None, "can_delete": False, "reason": "", "selected_by_default": False,
                  "_observation": {"removed_at": resource["removed_at"],
                                   "recorded_identity": json.loads(resource["identity_json"]),
                                   "recorded_metadata": json.loads(resource["metadata_json"])}}
        try:
            if resource["removed_at"]:
                raise RetainResource("Already removed by an earlier cleanup. A recreated path is never selected.")
            kind = resource["kind"]
            if kind == "branch":
                metadata, repository, branch, head, integrated = self._repository_preview(resource)
                result["_observation"].update(repository_identity=self._identity(repository),
                                               branch_head=head, integration_head=integrated)
                worktree_path = metadata["worktree_path"]
                if os.path.lexists(worktree_path):
                    worktree = next((item for row_id, item in (inspected or {}).items()
                                     if item["kind"] == "worktree" and item["path"] == worktree_path), None)
                    if not worktree or not worktree["can_delete"]:
                        raise RetainResource("Its recorded worktree is retained, so the branch is retained with it.")
                    reason = "Eligible after its selected clean, integrated worktree is removed. No remote branch is changed."
                else:
                    listed = self._git(repository, "worktree", "list", "--porcelain", no_optional_locks=True)
                    if "branch " + branch in listed.splitlines():
                        raise RetainResource("The branch is checked out by another worktree.")
                    reason = "Eligible: exact recorded branch tip is integrated and no worktree checks it out."
                result.update(estimated_bytes=0, can_delete=True, selected_by_default=True,
                              reason=reason + " Removing the branch ref does not reclaim Git object data.")
                return result
            path = self._validated_directory(resource, feature)
            result["_observation"].update(current_identity=self._identity(path),
                                           tree=self._tree_observation(path))
            if kind == "worktree":
                metadata, repository, branch, head, _ = self._repository_preview(resource)
                integrated = self._git(repository, "rev-parse", "--verify", metadata["integration_ref"], no_optional_locks=True)
                result["_observation"].update(repository_identity=self._identity(repository),
                                               branch_head=head, integration_head=integrated)
                if Path(self._git(path, "rev-parse", "--show-toplevel", no_optional_locks=True)) != path:
                    raise RetainResource("Path is not the recorded worktree root.")
                if Path(self._git(path, "rev-parse", "--path-format=absolute", "--git-common-dir", no_optional_locks=True)).resolve() != repository:
                    raise RetainResource("Worktree belongs to another repository.")
                if (self._git(path, "symbolic-ref", "-q", "HEAD", no_optional_locks=True) != branch
                        or self._git(path, "rev-parse", "HEAD", no_optional_locks=True) != head):
                    raise RetainResource("Worktree branch or revision changed.")
                if self._git(path, "status", "--porcelain", "--untracked-files=all", "--ignored", no_optional_locks=True):
                    raise RetainResource("Worktree has modified, untracked or ignored files.")
                reason = "Eligible: owned clean worktree at an exact revision preserved by its integration branch."
            elif kind in {"temporary_build", "cache"}:
                self._validate_disposable_tree(path)
                reason = "Eligible: explicitly allocated owned disposable directory with unchanged identity."
            else:
                raise RetainResource("Resource kind has no automatic deletion policy.")
            result.update(estimated_bytes=self._size(path), can_delete=True,
                          selected_by_default=True, reason=reason)
        except (RetainResource, OSError, subprocess.TimeoutExpired) as exc:
            result["reason"] = str(exc)[:500] or "Safety checks did not complete; retained for inspection."
        return result

    @staticmethod
    def _tree_observation(path):
        digest = hashlib.sha256()
        for parent, directories, files in os.walk(path, followlinks=False):
            directories.sort()
            for name in directories + sorted(files):
                child = Path(parent) / name
                info = child.lstat()
                relative = str(child.relative_to(path))
                digest.update(archive.encoded([relative, info.st_mode, info.st_dev, info.st_ino,
                                               info.st_size, info.st_mtime_ns]).encode())
        return digest.hexdigest()

    def _repository_preview(self, resource):
        metadata = json.loads(resource["metadata_json"])
        repository = Path(metadata["repository"])
        if repository.resolve() != repository or self._identity(repository) != metadata["repository_identity"]:
            raise RetainResource("Repository identity changed.")
        branch = "refs/heads/" + metadata["branch"]
        integration = metadata["integration_ref"]
        if not integration.startswith("refs/heads/") or integration.startswith("refs/heads/codex/first-mate-") or integration == branch:
            raise RetainResource("No independent project integration branch was recorded.")
        if self._git(repository, "for-each-ref", "--format=%(symref)", branch, integration, no_optional_locks=True):
            raise RetainResource("Task or integration branch is a symbolic reference; retained to protect its target.")
        head = self._git(repository, "rev-parse", "--verify", branch, no_optional_locks=True)
        integrated = self._git(repository, "rev-parse", "--verify", integration, no_optional_locks=True)
        try:
            self._git(repository, "merge-base", "--is-ancestor", head, integrated, no_optional_locks=True)
        except RetainResource:
            raise RetainResource("Task branch has commits not preserved by the recorded project integration branch.")
        return metadata, repository, branch, head, integrated

    def _validated_directory(self, resource, feature):
        kind = resource["kind"]
        path = Path(resource["path"])
        expected_parent = self.root / "worktrees" if kind == "worktree" else self.root / "disposable" / feature["id"]
        if path.parent != expected_parent or path.resolve() != path or path.is_symlink():
            raise RetainResource("Resource path is outside its managed location or contains a symbolic link.")
        if not path.exists():
            raise RetainResource("Path is already absent. No additional reclaimed space is claimed.")
        if not path.is_dir() or self._identity(path) != json.loads(resource["identity_json"]):
            raise RetainResource("Resource identity changed; the current path is retained.")
        self._exclusive(path, feature)
        return path

    @staticmethod
    def _validate_disposable_tree(path):
        if not shutil.rmtree.avoids_symlink_attacks:
            raise RetainResource("This host cannot safely remove a directory without following replacement links.")
        device = path.stat().st_dev
        for parent, directories, files in os.walk(path, followlinks=False):
            for name in directories + files:
                child = Path(parent) / name
                if name == ".git" or child.is_symlink() or child.lstat().st_dev != device:
                    raise RetainResource("Disposable space contains a link, mount or repository; retained for inspection.")

    def _stopped(self, feature, jobs):
        if feature.get("coordinator_owner"):
            return False
        if self.store._db.execute("SELECT 1 FROM fm_messages WHERE feature_id=? AND status='processing' LIMIT 1",
                                  (feature["id"],)).fetchone():
            return False
        if self.store._db.execute("""SELECT 1 FROM fm_assignments WHERE feature_id=? AND status NOT IN
            ('completed','cancelled','superseded','failed') LIMIT 1""", (feature["id"],)).fetchone():
            return False
        if self.store._db.execute("""SELECT 1 FROM fm_sessions WHERE feature_id=?
            AND assignment_id IS NOT NULL AND status='active' LIMIT 1""", (feature["id"],)).fetchone():
            return False
        from .first_mate_runtime import _locked
        known_jobs = {job["id"] for job in jobs}
        for directory in self.runtime.jobs_root.iterdir():
            if directory.is_dir() and directory.name not in known_jobs and not (directory / "finalized.json").is_file():
                # A missing/malformed job receipt cannot prove which session
                # owns a possible writer. Fail closed until it is reconciled.
                return False
        for job in jobs:
            if job.get("feature_id") != feature["id"]:
                continue
            directory = self.runtime._job_dir(job)
            if not (directory / "finalized.json").is_file() or _locked(directory / "writer.lock"):
                return False
        return True

    def _eligible(self, row):
        feature = self.store._one("fm_features", row["feature_id"])
        current = archive.latest(self.store, row["feature_id"], with_record=False)
        try:
            raw_options = json.loads(row["cleanup_options_json"])
        except (KeyError, TypeError, ValueError):
            raw_options = None
        resource_ids = raw_options.get("resource_ids") if isinstance(raw_options, dict) else None
        reviewed = (isinstance(row.get("preview_token"), str)
                    and len(row["preview_token"]) == 64
                    and all(character in "0123456789abcdef" for character in row["preview_token"])
                    and isinstance(raw_options, dict)
                    and set(raw_options) == {"resource_ids", "keep_documents", "keep_chat"}
                    and isinstance(resource_ids, list) and len(resource_ids) <= 1000
                    and all(isinstance(item, str) and item and len(item) <= 200 for item in resource_ids)
                    and len(set(resource_ids)) == len(resource_ids)
                    and type(raw_options["keep_documents"]) is bool
                    and type(raw_options["keep_chat"]) is bool)
        return feature if (reviewed
                           and feature["archived_at"] == row["archived_at"] and feature["status"] == "completed"
                           and feature["revision"] == row["feature_revision"] and current["id"] == row["id"]
                           and current["status"] in {"pending", "waiting", "running"}) else None

    def tick(self, jobs):
        with self.store._lock:
            rows = [dict(row) for row in self.store._db.execute("""SELECT * FROM fm_archives
                WHERE status IN ('pending','waiting','running') ORDER BY updated_at,id LIMIT 10""")]
        for row in rows:
            try:
                if self._step(row, jobs):
                    return
            except Exception as exc:
                with self.store._transaction():
                    self._status(row, "failed", "Cleanup stopped safely: " + str(exc)[:500])
                    archive.log(self.store, row, kind="completion_record", path=row["id"], outcome="failed",
                                reason=str(exc)[:500])

    def _status(self, row, status, message):
        self.store._db.execute("UPDATE fm_archives SET status=?,message=?,updated_at=? WHERE id=?",
                              (status, message, archive.now(), row["id"]))
        if status != row["status"] or message != row["message"]:
            self.store._event(row["feature_id"], "archive.cleanup", message, {"archive_id": row["id"], "status": status})

    def _step(self, row, jobs):
        with self.store._transaction():
            feature = self._eligible(row)
            if not feature:
                self._status(row, "cancelled", "Session is no longer eligible for archive cleanup.")
                return False
            if not self._stopped(feature, jobs):
                self._status(row, "waiting", "Waiting for recorded executions to stop. No work is interrupted.")
                return False
        if row["record"] is None:
            # Runtime projections may open their own transactions. Compute them
            # before the write fence, then recheck the feature inside it.
            projection = self.runtime.feature(feature["id"])
            resource_git = {}
            for resource in self._resources(feature["id"]):
                if resource["kind"] in {"worktree", "branch"}:
                    metadata = json.loads(resource["metadata_json"])
                    try:
                        resource_git[resource["id"]] = self._git(metadata["repository"], "rev-parse", "refs/heads/" + metadata["branch"])
                    except RetainResource:
                        resource_git[resource["id"]] = None
            projection["archive_resource_revisions"] = resource_git
            with self.store._transaction():
                if not self._eligible(row) or not self._stopped(feature, jobs):
                    return False
                archive.retain_record(self.store, row, projection, [job for job in jobs if job.get("feature_id") == feature["id"]])
                self._status(row, "running", "Completion record saved. Checking owned resources.")
                # Record the categories deliberately retained, including legacy
                # workspaces for which runtime ownership was never established.
                for kind, path, reason in self._retentions(feature):
                    archive.log(self.store, row, kind=kind, path=path, outcome="retained", reason=reason)
                options = archive.cleanup_options(row)
                if options["keep_documents"]:
                    archive.log(self.store, row, kind="documents", path=feature["id"], outcome="retained",
                                reason="Readable live document bodies retained by archive selection; originals also exist in the completion catalog.")
                if options["keep_chat"]:
                    archive.log(self.store, row, kind="chat", path=feature["id"], outcome="retained",
                                reason="Readable live conversation retained by archive selection; originals also exist in the completion catalog.")
            # The record's commit must finish BEFORE any filesystem deletion.
            return True
        saved = archive.record(row)
        with self.store._transaction():
            if not self._eligible(row) or not self._stopped(feature, jobs):
                return False
            options = archive.cleanup_options(row)
            for option, kind, log_kind in (("keep_documents", "documents", "document_catalog"),
                                           ("keep_chat", "chat", "chat_catalog")):
                if options[option]:
                    continue
                finished_compaction = self.store._db.execute("""SELECT 1 FROM fm_cleanup_log
                    WHERE archive_id=? AND attempt=? AND kind=? AND outcome IN ('cataloged','failed') LIMIT 1""",
                    (row["id"], row["attempt"], log_kind)).fetchone()
                if finished_compaction:
                    continue
                intended = self.store._db.execute("""SELECT 1 FROM fm_cleanup_log
                    WHERE archive_id=? AND attempt=? AND kind=? AND outcome='checking' LIMIT 1""",
                    (row["id"], row["attempt"], log_kind)).fetchone()
                if not intended:
                    reason = (f"Completion catalog verified. Preparing to replace live {kind} bodies with catalog pointers; "
                              "originals remain in the immutable catalog.")
                    archive.log(self.store, row, kind=log_kind, path=feature["id"], outcome="checking", reason=reason)
                    self._status(row, "running", reason)
                    return True
                try:
                    self.store._db.execute("SAVEPOINT fm_catalog_compaction")
                    count = archive.compact_live_rows(self.store, row, kind)
                    self.store._db.execute("RELEASE fm_catalog_compaction")
                    outcome = "cataloged"
                    reason = (f"{count} live {kind} rows now keep identifiers and catalog pointers; "
                              "verified original bodies remain in the immutable completion catalog. SQLite file size may not shrink immediately.")
                except Exception as exc:
                    self.store._db.execute("ROLLBACK TO fm_catalog_compaction")
                    self.store._db.execute("RELEASE fm_catalog_compaction")
                    outcome = "failed"
                    reason = f"Live {kind} retained because catalog compaction was not safe: {str(exc)[:400]}"
                archive.log(self.store, row, kind=log_kind, path=feature["id"], outcome=outcome, reason=reason)
                self._status(row, "running", reason)
                return True
            resources = self._resources(feature["id"])
            finished = {entry[0] for entry in self.store._db.execute("""SELECT resource_id FROM fm_cleanup_log
                WHERE archive_id=? AND attempt=? AND outcome IN ('removed','retained','failed')""", (row["id"], row["attempt"]))}
            resource = next((item for item in resources if item["id"] not in finished), None)
            if resource is None:
                failed = self.store._db.execute("SELECT 1 FROM fm_cleanup_log WHERE archive_id=? AND attempt=? AND outcome='failed'",
                                               (row["id"], row["attempt"])).fetchone()
                self._status(row, "failed" if failed else "completed",
                             "Cleanup has failures. Inspect the log and retry safely." if failed else
                             "Cleanup finished. History and retained resources remain available.")
                return True
            archive.log(self.store, row, resource_id=resource["id"], kind=resource["kind"], path=resource["path"],
                        outcome="checking", reason="Checking current ownership and retention rules before removal.")
            self._status(row, "running", "Checking " + resource["kind"] + ": " + resource["path"])
        # Persist intent first; a crash leaves a visible interrupted operation.
        with self.store._transaction():
            if not self._eligible(row) or not self._stopped(feature, jobs):
                return False
            archive.record(archive.latest(self.store, feature["id"]))
            try:
                selected = archive.cleanup_options(row)["resource_ids"]
                if selected is not None and resource["id"] not in selected:
                    raise RetainResource("Not selected for removal in this archive's persisted cleanup options.")
                if resource["removed_at"]:
                    raise RetainResource("Already removed by a previous cleanup; a recreated path is never deleted.")
                reclaimed = self._remove(resource, saved, feature)
                outcome, reason = "removed", "Owned disposable resource removed after completion record verification."
                self.store._db.execute("UPDATE fm_owned_resources SET removed_at=? WHERE id=?", (archive.now(), resource["id"]))
            except RetainResource as exc:
                outcome, reason, reclaimed = "retained", str(exc), 0
            except (OSError, subprocess.TimeoutExpired) as exc:
                outcome, reason, reclaimed = "failed", str(exc)[:500], 0
            archive.log(self.store, row, resource_id=resource["id"], kind=resource["kind"], path=resource["path"],
                        outcome=outcome, reason=reason, bytes_reclaimed=reclaimed)
        return True

    def _retentions(self, feature):
        yield "project", feature["cwd"], "Shared project source is never a cleanup target."
        yield "history", feature["id"], "The immutable completion catalog, original human request, artifacts, links, logs, usage and verification are retained."
        yield "backups", feature["id"], "Recovery backups are retained; no independently verified replacement is assumed."
        yield "published_builds", feature["id"], "Published builds/releases and unregistered local copies are retained."
        known = {item["path"] for item in self._resources(feature["id"])}
        for assignment in self.store.list_assignments(feature_id=feature["id"]):
            metadata = assignment.get("metadata") or {}
            path = metadata.get("worktree_path")
            if path and path not in known:
                yield "workspace", path, "Legacy or shared workspace: no recorded exclusive resource ownership."

    def _exclusive(self, path, feature):
        # Protect shared project roots and overlapping resources, even if their
        # records were created after this task's resource was allocated.
        def overlaps(other):
            other = Path(other).resolve()
            return path == other or path in other.parents or other in path.parents
        for row in self.store._db.execute("SELECT cwd FROM fm_features UNION SELECT cwd FROM fm_projects"):
            if overlaps(row[0]):
                raise RetainResource("Resource overlaps a saved project or session source folder.")
        for row in self.store._db.execute("SELECT metadata_json FROM fm_assignments WHERE feature_id<>?", (feature["id"],)):
            other = json.loads(row[0]).get("worktree_path")
            if other and overlaps(other):
                raise RetainResource("Another session references this workspace.")
        for row in self.store._db.execute("SELECT path FROM fm_owned_resources WHERE feature_id<>? AND kind<>'branch' AND removed_at IS NULL", (feature["id"],)):
            if overlaps(row[0]):
                raise RetainResource("Resource ownership overlaps another session.")

    def _repository(self, resource, saved):
        metadata = json.loads(resource["metadata_json"])
        repository = Path(metadata["repository"])
        if repository.resolve() != repository or self._identity(repository) != metadata["repository_identity"]:
            raise RetainResource("Repository identity changed.")
        branch = "refs/heads/" + metadata["branch"]
        integration = metadata["integration_ref"]
        if not integration.startswith("refs/heads/") or integration.startswith("refs/heads/codex/first-mate-") or integration == branch:
            raise RetainResource("No independent project integration branch was recorded.")
        if self._git(repository, "for-each-ref", "--format=%(symref)", branch, integration):
            raise RetainResource("Task or integration branch is a symbolic reference; retained to protect its target.")
        expected = saved["feature"].get("archive_resource_revisions", {}).get(resource["id"])
        head = self._git(repository, "rev-parse", "--verify", branch)
        if not expected or head != expected:
            raise RetainResource("Branch revision is missing or changed since the completion record was saved.")
        integrated = self._git(repository, "rev-parse", "--verify", integration)
        try:
            self._git(repository, "merge-base", "--is-ancestor", head, integrated)
        except RetainResource:
            raise RetainResource("Task branch has commits not preserved by the recorded project integration branch.")
        return metadata, repository, branch, head, integrated

    @staticmethod
    def _size(path):
        total = 0
        for parent, directories, files in os.walk(path, followlinks=False):
            for name in directories + files:
                info = (Path(parent) / name).lstat()
                if stat.S_ISREG(info.st_mode):
                    total += info.st_size
        return total

    def _remove(self, resource, saved, feature):
        kind = resource["kind"]
        if kind == "branch":
            metadata, repository, branch, head, integrated = self._repository(resource, saved)
            if os.path.lexists(metadata["worktree_path"]):
                raise RetainResource("Worktree is retained; its branch is retained with it.")
            worktrees = self._git(repository, "worktree", "list", "--porcelain")
            if "branch " + branch in worktrees.splitlines():
                raise RetainResource("Branch is checked out by a worktree.")
            # The same Git ref transaction verifies the surviving integration
            # tip and compares the exact branch tip before deleting it.
            self._git(repository, "update-ref", "--stdin", input=
                      f"start\noption no-deref\nverify {metadata['integration_ref']} {integrated}\ndelete {branch} {head}\nprepare\ncommit\n")
            return 0
        path = self._validated_directory(resource, feature)
        if kind == "worktree":
            metadata, repository, branch, head, _ = self._repository(resource, saved)
            if Path(self._git(path, "rev-parse", "--show-toplevel")) != path:
                raise RetainResource("Path is not the recorded worktree root.")
            if Path(self._git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve() != repository:
                raise RetainResource("Worktree belongs to another repository.")
            if self._git(path, "symbolic-ref", "-q", "HEAD") != branch or self._git(path, "rev-parse", "HEAD") != head:
                raise RetainResource("Worktree branch or revision changed.")
            if self._git(path, "status", "--porcelain", "--untracked-files=all", "--ignored"):
                raise RetainResource("Worktree has modified, untracked or ignored files.")
            size = self._size(path)
            self._git(repository, "worktree", "remove", str(path))
            return size
        if kind not in {"temporary_build", "cache"}:
            raise RetainResource("Resource kind has no automatic deletion policy.")
        self._validate_disposable_tree(path)
        size = self._size(path)
        shutil.rmtree(path)
        return size
