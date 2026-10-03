"""Synthetic filesystem and Git tests for the archive deletion boundary."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from herdr_harness import first_mate_archive as archive
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore, FirstMateError


class FirstMateCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "project"
        self.repo.mkdir()
        self.git(self.repo, "init", "-b", "main")
        self.git(self.repo, "config", "user.email", "test@example.invalid")
        self.git(self.repo, "config", "user.name", "Example")
        (self.repo / "source.txt").write_text("original\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "Initial synthetic source")
        self.store = FirstMateStore(self.root / "ledger.sqlite")
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, runtime_root=self.root / "runtime", environ={})
        self.feature = self.store.create_feature({"title": "Garden improvement", "goal": "Deliver a watering schedule",
            "cwd": str(self.repo), "request_id": "create"})
        self.fid = self.feature["id"]
        self.archive_payloads = {}

    @staticmethod
    def git(path, *args):
        return subprocess.run(["git", "-C", str(path), *args], check=True, text=True, capture_output=True).stdout.strip()

    def complete(self):
        # Completion workflow contracts have their own tests. This fixture
        # isolates cleanup with no spawned agents or real user state.
        with self.store._transaction():
            self.store._db.execute("UPDATE fm_features SET status='completed' WHERE id=?", (self.fid,))
            self.store._db.execute("UPDATE fm_messages SET status='done' WHERE feature_id=?", (self.fid,))

    def archive(self, request="archive"):
        if request in self.archive_payloads:
            return self.store.set_archived(self.fid, True, self.archive_payloads[request])
        preview = self.runtime.cleanup.preview(self.fid)
        if not preview["eligible"]:
            return self.store.set_archived(self.fid, True, {"request_id": request})
        payload = {
            "request_id": request,
            "expected_revision": preview["feature_revision"],
            "preview_token": preview["token"],
            "cleanup_options": preview["cleanup_options"],
        }
        self.archive_payloads[request] = payload
        return self.store.set_archived(self.fid, True, payload)

    def drain(self):
        for _ in range(20):
            self.runtime.cleanup.tick([])
            if archive.summary(self.store, self.fid)["status"] in {"completed", "failed", "cancelled", "waiting"}:
                return archive.summary(self.store, self.fid)
        self.fail("Cleanup failed to settle")

    def disposable(self, kind="temporary_build", request="build"):
        resource = self.runtime.cleanup.allocate(self.fid, kind, request)
        path = Path(resource["path"])
        (path / "intermediate.bin").write_bytes(b"x" * 1234)
        return path

    def worktree(self, branch="codex/first-mate-example", tracked=True):
        path = self.runtime.root / "worktrees" / "synthetic"
        self.git(self.repo, "worktree", "add", "-b", branch, str(path))
        if tracked:
            self.runtime.cleanup.register_worktree(self.feature, path, branch)
        return path, branch

    def test_archive_completed_saves_verified_history_before_removing_and_keeps_usage(self):
        path = self.disposable()
        self.complete()
        before = self.runtime.feature(self.fid)
        self.archive()
        self.runtime.cleanup.tick([])
        self.assertTrue(path.exists())
        record = archive.record(archive.latest(self.store, self.fid))
        self.assertEqual(record["feature"]["goal"], self.feature["goal"])
        self.assertEqual({key: value for key, value in record["feature"]["usage"].items() if key != "updated_at"},
                         {key: value for key, value in before["usage"].items() if key != "updated_at"})
        result = self.drain()
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["bytes_reclaimed"], 1234)
        self.assertFalse(path.exists())
        self.assertTrue((self.repo / "source.txt").exists())
        self.assertEqual(self.runtime.feature(self.fid)["usage"], record["feature"]["usage"])
        self.assertTrue(self.runtime.feature(self.fid)["verification"]["historical_only"])
        report = archive.report(self.store, self.fid)
        self.assertIn("Deliver a watering schedule", report)
        self.assertIn("1234", report)
        self.assertIn("removed", report)
        self.assertEqual(archive.search(self.store, "watering")["records"][0]["feature_id"], self.fid)

    def test_legacy_completed_archive_remains_visibility_only(self):
        path = self.disposable()
        self.complete()
        self.store.set_archived(self.fid, True, {"request_id": "legacy-hide"})
        self.runtime.cleanup.tick([])
        self.assertIsNotNone(self.store.get_feature(self.fid)["archived_at"])
        self.assertIsNone(archive.summary(self.store, self.fid))
        self.assertTrue(path.exists())

    def test_unreviewed_legacy_cleanup_row_fails_closed(self):
        path = self.disposable()
        self.complete()
        self.store.set_archived(self.fid, True, {"request_id": "legacy-hide"})
        feature = self.store.get_feature(self.fid)
        stamp = archive.now()
        with self.store._transaction():
            self.store._db.execute("""INSERT INTO fm_archives
                (id,feature_id,feature_revision,archived_at,status,preview_token,cleanup_options_json,created_at,updated_at)
                VALUES('archive_legacy',?,?,?,'pending',NULL,'{}',?,?)""",
                (self.fid, feature["revision"], feature["archived_at"], stamp, stamp))
        self.runtime.cleanup.tick([])
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "cancelled")
        self.assertTrue(path.exists())

    def test_malformed_review_metadata_fails_closed(self):
        path = self.disposable()
        self.complete()
        self.store.set_archived(self.fid, True, {"request_id": "legacy-hide"})
        feature = self.store.get_feature(self.fid)
        stamp = archive.now()
        malformed = json.dumps({"resource_ids": [123], "keep_documents": False, "keep_chat": False})
        with self.store._transaction():
            self.store._db.execute("""INSERT INTO fm_archives
                (id,feature_id,feature_revision,archived_at,status,preview_token,cleanup_options_json,created_at,updated_at)
                VALUES('archive_malformed',?,?,?,'pending',?,?,?,?)""",
                (self.fid, feature["revision"], feature["archived_at"], "x" * 64, malformed, stamp, stamp))
        self.runtime.cleanup.tick([])
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "cancelled")
        self.assertTrue(path.exists())

    def test_unfinished_archive_never_queues_or_interrupts(self):
        for status in ("running", "paused", "cancelled"):
            with self.store._transaction():
                self.store._db.execute("UPDATE fm_features SET status=?,archived_at=NULL WHERE id=?", (status, self.fid))
            self.archive(status)
            self.runtime.cleanup.tick([])
            self.assertIsNone(archive.summary(self.store, self.fid))
            self.assertEqual(self.store.get_feature(self.fid)["status"], status)

    def test_unarchive_cancels_pending_cleanup_but_does_not_restore_removed_resources(self):
        path = self.disposable()
        self.complete()
        self.archive()
        self.store.set_archived(self.fid, False, {"request_id": "restore"})
        self.runtime.cleanup.tick([])
        self.assertTrue(path.exists())
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "cancelled")
        self.archive("archive-again")
        self.drain()
        self.store.set_archived(self.fid, False, {"request_id": "restore-again"})
        self.assertFalse(path.exists())
        self.assertIn("Cleanup log", archive.report(self.store, self.fid))

    def test_replay_archive_does_not_queue_twice_or_delete_a_recreated_resource(self):
        path = self.disposable()
        self.complete()
        self.archive()
        self.archive()
        self.assertEqual(self.store._db.execute("SELECT count(*) FROM fm_archives").fetchone()[0], 1)
        self.drain()
        path.mkdir()
        (path / "new.txt").write_text("Keep newly created work")
        first = archive.retry(self.store, self.fid, "retry")
        self.assertEqual(first, archive.retry(self.store, self.fid, "retry"))
        self.drain()
        self.assertTrue((path / "new.txt").exists())
        self.assertIn("Already removed", archive.report(self.store, self.fid))

    def test_corrupt_or_unsaved_history_prevents_deletion_and_supports_retry(self):
        path = self.disposable()
        self.complete()
        self.archive()
        with patch.object(archive, "retain_record", side_effect=OSError("synthetic disk full")):
            self.assertEqual(self.drain()["status"], "failed")
        self.assertTrue(path.exists())
        archive.retry(self.store, self.fid, "retry")
        self.runtime.cleanup.tick([])
        self.store._db.execute("UPDATE fm_archives SET record_sha256='invalid'")
        self.assertEqual(self.drain()["status"], "failed")
        self.assertTrue(path.exists())

    def test_clean_integrated_worktree_and_exact_branch_are_removed(self):
        path, branch = self.worktree()
        (path / "source.txt").write_text("implemented\n")
        self.git(path, "commit", "-am", "Implement synthetic improvement")
        self.git(self.repo, "merge", "--ff-only", branch)
        tip = self.git(self.repo, "rev-parse", "HEAD")
        self.complete()
        self.archive()
        self.assertEqual(self.drain()["status"], "completed")
        self.assertFalse(path.exists())
        self.assertNotIn(branch, self.git(self.repo, "branch", "--list"))
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), tip)

    def test_unmerged_worktree_requires_new_review_after_integration(self):
        path, branch = self.worktree()
        (path / "source.txt").write_text("unmerged implementation\n")
        self.git(path, "commit", "-am", "Unmerged implementation")
        self.complete()
        preview = self.runtime.cleanup.preview(self.fid)
        self.assertIn("not preserved", next(item for item in preview["resources"]
                                             if item["kind"] == "worktree")["reason"])
        self.archive()
        self.drain()
        self.assertTrue(path.exists())
        self.assertIn("Not selected for removal", archive.report(self.store, self.fid))
        self.git(self.repo, "merge", "--ff-only", branch)
        archive.retry(self.store, self.fid, "integrated-retry")
        self.drain()
        self.assertTrue(path.exists())
        self.store.set_archived(self.fid, False, {"request_id": "review-again"})
        self.archive("integrated-archive")
        self.drain()
        self.assertFalse(path.exists())

    def test_dirty_untracked_and_ignored_worktree_contents_are_retained(self):
        path, _ = self.worktree()
        self.complete()
        for index, filename in enumerate(("source.txt", "untracked.txt", "ignored.bin")):
            if filename == "ignored.bin":
                (self.repo / ".git" / "info" / "exclude").write_text("ignored.bin\n")
            (path / filename).write_text("unsaved work\n")
            preview = self.runtime.cleanup.preview(self.fid)
            self.assertIn("modified, untracked or ignored", next(item for item in preview["resources"]
                                                                  if item["kind"] == "worktree")["reason"])
            self.archive("archive" + str(index))
            self.drain()
            self.assertTrue(path.exists())
            self.assertIn("Not selected for removal", archive.report(self.store, self.fid))
            self.store.set_archived(self.fid, False, {"request_id": "restore" + str(index)})
            if filename == "source.txt":
                self.git(path, "restore", "source.txt")
            else:
                (path / filename).unlink()

    def test_unknown_ownership_and_shared_folders_are_not_adopted(self):
        path, _ = self.worktree(tracked=False)
        scratch = self.disposable()
        self.store.create_feature({"title": "Other session", "goal": "Keep shared source", "cwd": str(scratch), "request_id": "other"})
        self.complete()
        preview = self.runtime.cleanup.preview(self.fid)
        self.assertIn("overlaps a saved project", next(item for item in preview["resources"]
                                                       if item["kind"] == "temporary_build")["reason"])
        self.archive()
        self.drain()
        self.assertTrue(path.exists())
        self.assertTrue(scratch.exists())
        self.assertIn("Not selected for removal", archive.report(self.store, self.fid))

    def test_symlink_swap_is_retained(self):
        path = self.disposable()
        replacement = path.with_name("original")
        path.rename(replacement)
        path.symlink_to(self.repo, target_is_directory=True)
        self.complete()
        self.archive()
        self.drain()
        self.assertTrue(path.is_symlink())
        self.assertTrue((self.repo / "source.txt").exists())

    def test_live_job_waits_without_stopping_it(self):
        path = self.disposable()
        self.complete()
        self.archive()
        job = {"id": "synthetic", "feature_id": self.fid}
        self.runtime.cleanup.tick([job])
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "waiting")
        self.assertTrue(path.exists())
        self.drain()
        self.assertFalse(path.exists())

    def test_disk_removal_failure_is_logged_and_retry_succeeds(self):
        path = self.disposable()
        self.complete()
        self.archive()
        with patch("herdr_harness.first_mate_cleanup.shutil.rmtree", side_effect=PermissionError("synthetic permission denied")):
            self.assertEqual(self.drain()["status"], "failed")
        self.assertTrue(path.exists())
        archive.retry(self.store, self.fid, "retry")
        self.assertEqual(self.drain()["status"], "completed")
        self.assertFalse(path.exists())
        self.assertIn("synthetic permission denied", archive.report(self.store, self.fid))

    def test_resource_allocation_is_idempotent_and_cannot_adopt_arbitrary_paths(self):
        resource = self.runtime.cleanup.allocate(self.fid, "cache", "allocation")
        self.assertEqual(resource, self.runtime.cleanup.allocate(self.fid, "cache", "allocation"))
        with self.assertRaises(FirstMateError):
            self.runtime.cleanup.allocate(self.fid, "source", "unsafe")
        self.complete()
        with self.assertRaises(FirstMateError):
            self.runtime.cleanup.allocate(self.fid, "cache", "closed")

    def test_project_archive_does_not_queue_cleanup_or_touch_its_directory(self):
        project = self.store.create_project({"name": "Garden", "cwd": str(self.repo), "request_id": "project"}, home=self.root)
        self.store.archive_project(project["id"], {"archived": True, "expected_revision": project["revision"], "request_id": "archive-project"})
        self.runtime.cleanup.tick([])
        self.assertIsNone(archive.summary(self.store, self.fid))
        self.assertTrue((self.repo / "source.txt").exists())

    def test_unarchive_between_saved_intent_and_delete_cancels_removal(self):
        path = self.disposable()
        self.complete()
        self.archive()
        self.runtime.cleanup.tick([])
        status = self.runtime.cleanup._status

        def restore_after_intent(row, state, message):
            status(row, state, message)
            if message.startswith("Checking temporary_build"):
                # Simulate a second request winning before the next deletion
                # transaction. Store SQL here avoids nested test transactions.
                self.store._db.execute("UPDATE fm_features SET archived_at=NULL WHERE id=?", (self.fid,))
                archive.cancel(self.store, self.fid)

        with patch.object(self.runtime.cleanup, "_status", side_effect=restore_after_intent):
            self.runtime.cleanup.tick([])
        self.assertTrue(path.exists())
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "cancelled")

    def test_crash_after_filesystem_delete_restarts_without_double_counting(self):
        path = self.disposable()
        self.complete()
        self.archive()
        self.runtime.cleanup.tick([])
        remove = self.runtime.cleanup._remove

        def crash(*args):
            remove(*args)
            raise KeyboardInterrupt("synthetic process termination")

        with patch.object(self.runtime.cleanup, "_remove", side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                self.runtime.cleanup.tick([])
        self.assertFalse(path.exists())
        self.runtime = FirstMateRuntime(self.store, runtime_root=self.root / "runtime", environ={})
        result = self.drain()
        self.assertEqual(result["bytes_reclaimed"], 0)
        self.assertIn("already absent", archive.report(self.store, self.fid))

    def test_stale_archive_generation_cannot_resume_after_rearchive(self):
        path = self.disposable()
        self.complete()
        self.archive()
        stale = archive.latest(self.store, self.fid)
        self.store.set_archived(self.fid, False, {"request_id": "restore"})
        self.archive("new-archive")
        self.assertIsNone(self.runtime.cleanup._eligible(stale))
        self.assertTrue(path.exists())

    def test_final_documents_original_request_and_verification_survive_cleanup(self):
        path = self.disposable()
        message = self.store.claim_message(self.fid, "coordinator")
        visit = self.store.start_visit(self.fid, "implementation", "Implement garden", "stage", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Implementation authorized.")
        assignment = self.store.create_assignment(visit["id"], {"title": "Garden implementation", "role": "implementer", "prompt": "Implement", "request_id": "worker"})
        claimed = self.store.claim_assignment(assignment["id"], "worker")
        bound = self.store.bind_session(assignment["id"], claimed["generation"], "worker", "synthetic-session", str(self.root / "session.jsonl"))
        self.store.record_outcome(assignment["id"], bound["generation"], "synthetic-session", 1, "success", "Delivered the schedule", "outcome",
                                 documents=[{"title": "Final schedule", "content": "Final planting document, with limitations and verification omissions."}],
                                 code_revision=self.git(self.repo, "rev-parse", "HEAD"))
        self.complete()
        self.store._db.execute("UPDATE fm_features SET goal='Revised goal',verification_json=? WHERE id=?",
            (json.dumps({"status": "partially_verified", "missing_suites": [{"label": "Garden/UI"}], "coverage_reasons": ["UI suite not run"]}), self.fid))
        self.archive()
        self.drain()
        self.assertFalse(path.exists())
        saved = archive.record(archive.latest(self.store, self.fid))
        self.assertEqual(saved["original_request"], "Deliver a watering schedule")
        self.assertEqual(saved["documents"][0]["title"], "Final schedule")
        self.assertEqual(self.runtime.feature(self.fid)["verification"]["missing_suites"], [{"label": "Garden/UI"}])
        self.assertIn("Final planting document", archive.report(self.store, self.fid))
        self.assertIn("UI suite not run", archive.report(self.store, self.fid))
        self.assertEqual(len(archive.search(self.store, "planting")["records"]), 1)

    def test_changed_branch_since_preservation_is_retained_even_after_integration(self):
        path, branch = self.worktree()
        self.complete()
        self.archive()
        self.runtime.cleanup.tick([])
        (path / "source.txt").write_text("New work after archive\n")
        self.git(path, "commit", "-am", "Later work")
        self.git(self.repo, "merge", "--ff-only", branch)
        self.drain()
        self.assertTrue(path.exists())
        self.assertIn("changed since", archive.report(self.store, self.fid))

    def test_unidentifiable_unfinished_job_prevents_cleanup(self):
        path = self.disposable()
        (self.runtime.jobs_root / "unknown-dispatch").mkdir()
        self.complete()
        self.archive()
        self.runtime.cleanup.tick([])
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "waiting")
        self.assertTrue(path.exists())

    def test_symbolic_task_branch_cannot_delete_the_project_branch(self):
        path, branch = self.worktree()
        self.complete()
        self.archive()
        self.runtime.cleanup.tick([])
        self.git(self.repo, "worktree", "remove", str(path))
        self.git(self.repo, "symbolic-ref", "refs/heads/" + branch, "refs/heads/main")
        self.drain()
        self.assertTrue(self.git(self.repo, "rev-parse", "refs/heads/main"))
        self.assertIn("symbolic reference", archive.report(self.store, self.fid))

    def test_completion_date_and_selected_archive_summary_match_retained_history(self):
        self.store.feature_action(self.fid, "complete", "completed")
        self.archive()
        self.drain()
        first = archive.latest(self.store, self.fid)
        completed = archive.record(first)["completed_at"]
        self.assertIsNotNone(completed)
        self.assertIn("Completed: " + completed, archive.report(self.store, self.fid))
        self.store.set_archived(self.fid, False, {"request_id": "restore"})
        self.archive("second")
        self.assertEqual(archive.summary(self.store, self.fid, first["id"])["status"], "completed")
        self.assertEqual(archive.summary(self.store, self.fid)["status"], "pending")

    def test_preview_uses_live_safety_checks_and_stale_token_cannot_archive(self):
        path = self.disposable()
        self.complete()
        preview = self.runtime.cleanup.preview(self.fid)
        self.assertTrue(preview["eligible"])
        self.assertEqual(preview["resources"][0]["estimated_bytes"], 1234)
        self.assertTrue(preview["resources"][0]["can_delete"])
        (path / "later.bin").write_bytes(b"changed after review")
        payload = {"request_id": "reviewed-archive", "expected_revision": preview["feature_revision"],
                   "preview_token": preview["token"], "cleanup_options": preview["cleanup_options"]}
        with self.assertRaises(FirstMateError) as caught:
            self.store.set_archived(self.fid, True, payload)
        self.assertEqual(caught.exception.code, "archive_preview_stale")
        self.assertIsNone(self.store.get_feature(self.fid)["archived_at"])

        current = self.runtime.cleanup.preview(self.fid)
        current["cleanup_options"]["resource_ids"] = []
        payload.update(expected_revision=current["feature_revision"], preview_token=current["token"],
                       cleanup_options=current["cleanup_options"], request_id="keep-resource")
        self.store.set_archived(self.fid, True, payload)
        self.assertEqual(self.drain()["status"], "completed")
        self.assertTrue(path.exists())
        saved = archive.latest(self.store, self.fid)
        self.assertEqual(archive.cleanup_options(saved)["resource_ids"], [])
        archive.retry(self.store, self.fid, "same-selection-retry")
        self.drain()
        self.assertTrue(path.exists())
        self.assertIn("Not selected for removal", archive.report(self.store, self.fid))

    def test_preview_token_binds_same_size_git_tip_changes_and_branch_ref_estimate(self):
        path, branch = self.worktree()
        first = self.runtime.cleanup.preview(self.fid)
        branch_item = next(item for item in first["resources"] if item["kind"] == "branch")
        self.assertTrue(branch_item["can_delete"])
        self.assertEqual(branch_item["estimated_bytes"], 0)
        self.assertIn("does not reclaim Git object data", branch_item["reason"])
        (path / "source.txt").write_text("changed!\n")
        self.git(path, "commit", "-am", "Same size synthetic change")
        self.git(self.repo, "merge", "--ff-only", branch)
        second = self.runtime.cleanup.preview(self.fid)
        self.assertNotEqual(first["token"], second["token"])
        self.assertTrue(all(item["can_delete"] for item in second["resources"]))

    def test_compacted_live_bodies_rearchive_from_verified_catalog(self):
        message = self.store.claim_message(self.fid, "coordinator")
        visit = self.store.start_visit(self.fid, "implementation", "Implement garden", "stage", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Implementation authorized.")
        assistant_id = self.store._db.execute(
            "SELECT id FROM fm_messages WHERE feature_id=? AND role='assistant' ORDER BY rowid DESC LIMIT 1",
            (self.fid,)).fetchone()[0]
        stamp = archive.now()
        self.store._db.execute("""INSERT INTO fm_message_skims
            (message_id,feature_id,format,prompt_version,segmenter_version,skim_version,model,thinking,status,
             attempts,output,document_json,segments_json,warnings_json,reply_sha256,error,duration_ms,created_at,updated_at)
            VALUES(?,?,'skim','test',1,1,'synthetic','low','ready',1,'cached reply','{}','[]','[]',?,'',1,?,?)""",
            (assistant_id, self.fid, hashlib.sha256("Implementation authorized.".encode()).hexdigest(), stamp, stamp))
        assignment = self.store.create_assignment(visit["id"], {"title": "Garden implementation", "role": "implementer",
            "prompt": "Implement", "request_id": "worker"})
        claimed = self.store.claim_assignment(assignment["id"], "worker")
        bound = self.store.bind_session(assignment["id"], claimed["generation"], "worker", "catalog-session",
                                        str(self.root / "catalog-session.jsonl"))
        self.store.record_outcome(assignment["id"], bound["generation"], "catalog-session", 1, "success",
            "Delivered the schedule", "catalog-outcome",
            documents=[{"title": "Final schedule", "content": "Original final planting evidence."}])
        self.store._db.execute("UPDATE fm_features SET work_item_id='GARDEN-42' WHERE id=?", (self.fid,))
        self.complete()
        preview = self.runtime.cleanup.preview(self.fid)
        options = dict(preview["cleanup_options"], keep_documents=False, keep_chat=False)
        self.store.set_archived(self.fid, True, {"request_id": "compact", "expected_revision": preview["feature_revision"],
            "preview_token": preview["token"], "cleanup_options": options})
        self.drain()
        first = archive.latest(self.store, self.fid)
        saved = archive.record(first)
        self.assertEqual(saved["original_request"], "Deliver a watering schedule")
        self.assertEqual(saved["documents"][0]["content"], "Original final planting evidence.")
        self.assertEqual(saved["feedback_sources"][0]["response_text"], "Implementation authorized.")
        self.assertEqual(saved["message_skims"][0]["output"], "cached reply")
        self.assertTrue(self.store._db.execute("SELECT content FROM fm_documents WHERE feature_id=?", (self.fid,)).fetchone()[0]
                        .startswith("[Archived in First Mate completion record "))
        self.assertTrue(all(row[0].startswith("[Archived in First Mate completion record ")
                            for row in self.store._db.execute("SELECT text FROM fm_messages WHERE feature_id=?", (self.fid,))))
        self.assertTrue(self.store._db.execute(
            "SELECT response_text FROM fm_feedback_sources WHERE feature_id=?", (self.fid,)).fetchone()[0]
            .startswith("[Archived in First Mate completion record "))
        self.assertEqual(self.store._db.execute(
            "SELECT count(*) FROM fm_message_skims WHERE feature_id=?", (self.fid,)).fetchone()[0], 0)
        self.assertIn("Work item / ticket: GARDEN-42", archive.report(self.store, self.fid))

        self.store.set_archived(self.fid, False, {"request_id": "restore-after-compact"})
        self.archive("rearchive-after-compact")
        self.drain()
        again = archive.record(archive.latest(self.store, self.fid))
        self.assertEqual(again["original_request"], "Deliver a watering schedule")
        self.assertEqual(again["documents"][0]["content"], "Original final planting evidence.")

    def test_marker_like_human_text_is_not_treated_as_catalog_pointer(self):
        marker_like = "[Archived in First Mate completion record user-written.] Keep this exact request."
        initial = self.store._db.execute("SELECT id FROM fm_messages WHERE feature_id=? ORDER BY rowid LIMIT 1",
                                         (self.fid,)).fetchone()[0]
        self.store._db.execute("UPDATE fm_messages SET text=?,updated_at=? WHERE id=?",
                               (marker_like, archive.now(), initial))
        self.complete()
        preview = self.runtime.cleanup.preview(self.fid)
        options = dict(preview["cleanup_options"], keep_chat=False)
        self.store.set_archived(self.fid, True, {"request_id": "marker", "expected_revision": preview["feature_revision"],
            "preview_token": preview["token"], "cleanup_options": options})
        self.drain()
        self.store.set_archived(self.fid, False, {"request_id": "marker-restore"})
        self.archive("marker-rearchive")
        self.drain()
        self.assertEqual(archive.record(archive.latest(self.store, self.fid))["original_request"], marker_like)

    def test_changed_live_body_after_catalog_save_is_retained_and_reported(self):
        self.complete()
        preview = self.runtime.cleanup.preview(self.fid)
        options = dict(preview["cleanup_options"], keep_chat=False)
        self.store.set_archived(self.fid, True, {"request_id": "compact-race",
            "expected_revision": preview["feature_revision"], "preview_token": preview["token"],
            "cleanup_options": options})
        self.runtime.cleanup.tick([])  # immutable record
        self.runtime.cleanup.tick([])  # committed compaction intent
        message_id = self.store._db.execute("SELECT id FROM fm_messages WHERE feature_id=? ORDER BY rowid LIMIT 1",
                                             (self.fid,)).fetchone()[0]
        changed = "[Archived in First Mate completion record spoof.] changed after snapshot"
        self.store._db.execute("UPDATE fm_messages SET text=?,updated_at=? WHERE id=?",
                               (changed, archive.now(), message_id))
        result = self.drain()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.store._db.execute("SELECT text FROM fm_messages WHERE id=?", (message_id,)).fetchone()[0], changed)
        self.assertIn("changed after the completion catalog was saved", archive.report(self.store, self.fid))

    def test_changed_feedback_source_rolls_back_chat_compaction_as_one_batch(self):
        message = self.store.claim_message(self.fid, "coordinator")
        self.store.finish_message(message["id"], "coordinator", "Original assistant response.")
        self.complete()
        original_messages = [row[0] for row in self.store._db.execute(
            "SELECT text FROM fm_messages WHERE feature_id=? ORDER BY rowid", (self.fid,))]
        preview = self.runtime.cleanup.preview(self.fid)
        options = dict(preview["cleanup_options"], keep_chat=False)
        self.store.set_archived(self.fid, True, {"request_id": "feedback-race",
            "expected_revision": preview["feature_revision"], "preview_token": preview["token"],
            "cleanup_options": options})
        self.runtime.cleanup.tick([])  # immutable record
        self.runtime.cleanup.tick([])  # committed compaction intent
        self.store._db.execute("UPDATE fm_feedback_sources SET response_text='Changed feedback source' WHERE feature_id=?",
                               (self.fid,))
        self.assertEqual(self.drain()["status"], "failed")
        self.assertEqual([row[0] for row in self.store._db.execute(
            "SELECT text FROM fm_messages WHERE feature_id=? ORDER BY rowid", (self.fid,))], original_messages)
        self.assertEqual(self.store._db.execute(
            "SELECT count(*) FROM fm_catalog_pointers WHERE feature_id=?", (self.fid,)).fetchone()[0], 0)
        self.assertIn("A feedback source changed", archive.report(self.store, self.fid))

    def test_progress_pages_are_bounded_and_pinned_to_archive_generation(self):
        self.complete()
        self.archive()
        self.drain()
        first = archive.latest(self.store, self.fid)["id"]
        page = archive.progress(self.store, self.fid, first, limit=1)
        self.assertEqual(page["archive_id"], first)
        self.assertEqual(len(page["logs"]), 1)
        self.assertIsNotNone(page["next_after"])
        second_page = archive.progress(self.store, self.fid, first, after=page["next_after"], limit=200)
        self.assertTrue(second_page["logs"])
        self.store.set_archived(self.fid, False, {"request_id": "progress-restore"})
        self.archive("progress-second")
        second = archive.latest(self.store, self.fid)["id"]
        self.assertNotEqual(first, second)
        self.assertEqual(archive.progress(self.store, self.fid, first)["archive_id"], first)
        self.assertEqual(archive.progress(self.store, self.fid)["archive_id"], second)

    def test_progress_reads_committed_intent_while_removal_holds_writer_lock(self):
        self.disposable()
        self.complete()
        self.archive()
        self.runtime.cleanup.tick([])  # immutable record
        started, release = threading.Event(), threading.Event()
        remove = self.runtime.cleanup._remove

        def blocked_remove(*args):
            started.set()
            if not release.wait(5):
                raise RuntimeError("synthetic removal wait timed out")
            return remove(*args)

        with patch.object(self.runtime.cleanup, "_remove", side_effect=blocked_remove):
            worker = threading.Thread(target=self.runtime.cleanup.tick, args=([],), daemon=True)
            worker.start()
            self.assertTrue(started.wait(2))
            began = time.monotonic()
            page = archive.progress(self.store, self.fid)
            elapsed = time.monotonic() - began
            self.assertLess(elapsed, 1.0)
            self.assertTrue(any(item["outcome"] == "checking" for item in page["logs"]))
            release.set()
            worker.join(5)
            self.assertFalse(worker.is_alive())

    def test_progress_supports_a_relative_database_path(self):
        self.complete()
        self.archive()
        expected = archive.latest(self.store, self.fid)["id"]
        with patch.object(self.store, "path", Path(os.path.relpath(self.store.path))):
            self.assertEqual(archive.progress(self.store, self.fid)["archive_id"], expected)
