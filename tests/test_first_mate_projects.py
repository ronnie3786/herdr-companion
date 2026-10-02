"""Saved projects retain ownership, snapshots, and exactly-once initial direction."""
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.directory_browser import DirectoryBrowserError
from herdr_harness.first_mate_store import FirstMateError, FirstMateStore


class FirstMateProjectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.folder = self.root / "Garden project"
        self.folder.mkdir()
        self.database = self.root / "first-mate.sqlite3"
        self.store = FirstMateStore(self.database)
        self.addCleanup(lambda: self.store.close())
        self.project_body = {"name": "Garden iOS", "cwd": str(self.folder), "request_id": "project-one"}
        self.project = self.store.create_project(self.project_body)

    def feature_body(self, **changes):
        return {"title": "Watering schedule", "goal": "  Start with SYNTH-31.\nInvestigate first, then propose a plan.  ",
                "project_id": self.project["id"], "expected_project_revision": self.project["revision"],
                "request_id": "feature-one", **changes}

    def assert_error(self, code, operation, error_type=FirstMateError):
        with self.assertRaises(error_type) as error:
            operation()
        self.assertEqual(error.exception.code, code)

    def test_saved_project_and_feature_snapshot_survive_restart_and_project_edits(self):
        feature = self.store.create_feature(self.feature_body())
        other = self.root / "Web project"
        other.mkdir()
        updated = self.store.update_project(self.project["id"], {
            "name": "Garden Web", "cwd": str(other), "expected_revision": 1, "request_id": "edit-one"})
        self.assertEqual(updated["revision"], 2)
        self.store.close()
        self.store = FirstMateStore(self.database)
        saved = self.store.get_feature(feature["id"])
        self.assertEqual((saved["cwd"], saved["project_name"], saved["project_revision"]),
                         (str(self.folder), "Garden iOS", 1))
        self.assertEqual(self.store.list_projects()[0]["name"], "Garden Web")
        messages = self.store.snapshot(feature["id"])["messages"]
        self.assertEqual([message["text"] for message in messages], [self.feature_body()["goal"]])

    def test_accepted_creation_retries_after_archive_edit_and_folder_removal(self):
        body = self.feature_body()
        feature = self.store.create_feature(body)
        edited = self.store.update_project(self.project["id"], {
            "name": "Renamed garden", "cwd": str(self.folder), "expected_revision": 1, "request_id": "rename"})
        self.store.archive_project(self.project["id"], {
            "archived": True, "expected_revision": edited["revision"], "request_id": "archive"})
        self.folder.rmdir()
        self.assertEqual(self.store.create_feature(body), feature)
        self.assertEqual(self.store.create_project(self.project_body), self.project)
        self.assertEqual(len(self.store.snapshot(feature["id"])["messages"]), 1)
        self.assert_error("idempotency_conflict", lambda: self.store.create_feature({**body, "goal": "Different direction"}))

    def test_archive_restore_filters_and_stale_selection_leave_existing_session_intact(self):
        feature = self.store.create_feature(self.feature_body())
        body = {"archived": True, "expected_revision": 1, "request_id": "archive"}
        archived = self.store.archive_project(self.project["id"], body)
        self.assertEqual(self.store.archive_project(self.project["id"], body), archived)
        self.assertEqual(self.store.list_projects(), [])
        self.assertEqual(self.store.list_projects("archived"), [archived])
        self.assertEqual(self.store.list_projects("all"), [archived])
        self.assertEqual(self.store.get_feature(feature["id"])["status"], "ready")
        self.assert_error("stale_project_revision", lambda: self.store.create_feature(self.feature_body(request_id="new-one")))
        self.assert_error("project_archived", lambda: self.store.create_feature(self.feature_body(
            request_id="new-two", expected_project_revision=archived["revision"])))
        restored = self.store.archive_project(self.project["id"], {
            "archived": False, "expected_revision": archived["revision"], "request_id": "restore"})
        self.assertIsNone(restored["archived_at"])
        self.assertEqual(len(self.store.list_projects()), 1)

    def test_invalid_selection_and_folder_changes_cannot_create_a_feature(self):
        for changes in ({"cwd": str(self.folder)}, {"expected_project_revision": True},
                        {"expected_project_revision": 0}, {"expected_project_revision": None}):
            self.assert_error("invalid_request", lambda changes=changes: self.store.create_feature(self.feature_body(**changes)))
        self.folder.rmdir()
        self.assert_error("directory_missing", lambda: self.store.create_feature(self.feature_body()), DirectoryBrowserError)
        self.assertEqual(self.store.list_features(), [])
        self.assertFalse(self.store.has_receipt("create_feature", "feature-one"))
        elsewhere = self.root / "Other garden"
        elsewhere.mkdir()
        self.folder.symlink_to(elsewhere, target_is_directory=True)
        self.assert_error("project_directory_changed", lambda: self.store.create_feature(self.feature_body()))

    def test_invalid_project_mutations_leave_revision_and_receipts_unchanged(self):
        for value in ("", "\n", "Garden\nWeb", "Garden\n", "Garden\u2028Web", "Garden\ud800", "x" * 161, 42):
            self.assert_error("invalid_request", lambda value=value: self.store.create_project(
                {**self.project_body, "name": value, "request_id": "invalid-name"}))
        self.assert_error("stale_project_revision", lambda: self.store.update_project(self.project["id"], {
            "name": "Renamed", "cwd": str(self.folder), "expected_revision": 2, "request_id": "stale"}))
        self.assert_error("invalid_request", lambda: self.store.archive_project(self.project["id"], {
            "archived": "true", "expected_revision": 1, "request_id": "bad-archive"}))
        self.assertEqual(self.store.list_projects(), [self.project])

    def test_feature_creation_rolls_back_all_rows_when_initial_message_fails(self):
        with patch.object(self.store, "_message", side_effect=RuntimeError("synthetic write failure")):
            with self.assertRaises(RuntimeError):
                self.store.create_feature(self.feature_body())
        self.assertEqual(self.store.list_features(), [])
        self.assertFalse(self.store.has_receipt("create_feature", "feature-one"))
        self.assertEqual(len(self.store.snapshot(self.store.create_feature(self.feature_body())["id"])["messages"]), 1)

    def test_concurrent_retries_create_one_feature_and_one_prompt(self):
        another = FirstMateStore(self.database)
        self.addCleanup(another.close)
        results, failures = [], []
        barrier = threading.Barrier(2)

        def create(store):
            try:
                barrier.wait()
                results.append(store.create_feature(self.feature_body()))
            except Exception as error:
                failures.append(error)

        workers = [threading.Thread(target=create, args=(store,)) for store in (self.store, another)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])
        self.assertEqual(len(self.store.snapshot(results[0]["id"])["messages"]), 1)

    def test_migration_keeps_legacy_manual_features_and_does_not_invent_projects(self):
        feature = self.store.create_feature({"title": "Legacy", "goal": "Existing work", "cwd": "/tmp/synthetic-legacy",
                                            "request_id": "legacy"})
        self.store.close()
        with sqlite3.connect(self.database) as old:
            old.execute("DROP TABLE fm_projects")
            for column in ("project_id", "project_name", "project_revision"):
                old.execute("ALTER TABLE fm_features DROP COLUMN " + column)
            old.execute("DELETE FROM fm_schema WHERE version=19")
            self.assertEqual([row[0] for row in old.execute("SELECT version FROM fm_schema WHERE version>=15 ORDER BY version")],
                             [15, 16, 17, 18])
        self.store = FirstMateStore(self.database)
        with sqlite3.connect(self.database) as migrated:
            self.assertEqual([row[0] for row in migrated.execute("SELECT version FROM fm_schema WHERE version>=15 ORDER BY version")],
                             [15, 16, 17, 18, 19])
        saved = self.store.get_feature(feature["id"])
        self.assertEqual(saved["cwd"], "/tmp/synthetic-legacy")
        self.assertIsNone(saved["project_id"])
        self.assertEqual(self.store.list_projects(), [])
        self.assertEqual(len(self.store.snapshot(feature["id"])["messages"]), 1)

    def test_symlink_and_home_paths_are_saved_as_server_canonical_paths(self):
        alias = self.root / "Alias"
        alias.symlink_to(self.folder, target_is_directory=True)
        project = self.store.create_project({"name": "Alias project", "cwd": "~/Alias", "request_id": "alias"}, home=self.root)
        self.assertEqual(project["cwd"], str(self.folder))


if __name__ == "__main__":
    unittest.main()
