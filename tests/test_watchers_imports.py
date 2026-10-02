"""Synthetic full-set migration, non-executing preview and portable bundles."""
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from herdr_harness.watchers.api import route
from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.imports import bundle_entry, cronboard_entries
from herdr_harness.watchers.store import WatchersStore
from herdr_harness.watchers.validation import example


def jobs():
    return [{"id": f"synthetic-job-{index}", "name": f"Example scheduled check {index}", "schedule": "0 9 * * 1-5", "interpreter": "bash" if index % 2 else "python", "command": "printf 'example\\n'\n" if index % 2 else "print('example')\n", "enabled": index < 8, "scheduleTimeZone": "America/Chicago", "nextRun": "2026-10-02T14:00:00Z"} for index in range(10)]


class WatchersImportsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = WatchersStore(Path(self.tmp.name) / "watchers.sqlite3", Path(self.tmp.name) / "watchers", "example")
        self.wakes = []
        self.service = SimpleNamespace(watchers=SimpleNamespace(store=self.store, wake=lambda: self.wakes.append(True)), environ={})

    def tearDown(self):
        self.tmp.cleanup()

    def test_all_ten_imported_once_with_confirmed_jobs_paused(self):
        first, previews, commands = cronboard_entries(jobs(), confirmed=True)
        values = self.store.batch_create(first, request_id="import-all")
        self.assertEqual([value["state"] for value in values], ["paused"] * 8 + ["draft"] * 2)
        self.assertEqual(len(values), 10)
        self.assertTrue(all(value["next_fire_at"] is None for value in values))
        again, _, _ = cronboard_entries(jobs(), confirmed=True)
        self.assertEqual(self.store.batch_create(again, request_id="import-all"), values)
        repeated = self.store.batch_create(again, request_id="new-request-same-source")
        self.assertEqual({value["id"] for value in repeated}, {value["id"] for value in values})
        self.assertEqual(len(self.store.list()), 10)
        self.assertEqual(len(commands["disable"]), 8)
        self.assertEqual(len(commands["rollback_enable"]), 8)
        self.assertEqual(values[0]["activated_by"], "user")
        self.assertEqual(self.store.get_script(values[0]["id"], "script")["content"], jobs()[0]["command"])

    def test_unconfirmed_jobs_are_all_drafts(self):
        entries, _, _ = cronboard_entries(jobs())
        values = self.store.batch_create(entries, request_id="draft-import")
        self.assertTrue(all(value["state"] == "draft" and "activated_by" not in value for value in values))

    def test_preview_checks_parity_and_never_executes_or_creates(self):
        now = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
        with patch("subprocess.Popen", side_effect=AssertionError("preview ran a job")):
            entries, previews, _ = cronboard_entries(jobs(), now=now)
            self.assertTrue(all(value["parity"] is True and len(value["next"]) == 3 for value in previews))
            result = route(self.service, "POST", ["import"], {}, {"request_id": "preview", "source": "cronboard", "jobs": jobs(), "dry_run": True})
        self.assertFalse(result["executed"])
        self.assertEqual(self.store.list(), [])
        self.assertEqual(self.wakes, [])
        self.assertEqual(previews[0]["interpreter"], "/usr/bin/python3")
        self.assertIn("interpreter_present", previews[0])

    def test_validation_failure_keeps_all_ten_out_of_store(self):
        invalid = jobs()
        invalid[-1]["schedule"] = "invalid"
        with self.assertRaises(WatchersError):
            route(self.service, "POST", ["import"], {}, {"request_id": "bad-import", "source": "cronboard", "jobs": invalid, "confirmed_by": "user"})
        self.assertEqual(self.store.list(), [])
        self.assertEqual(list(self.store.root.glob("wat_*")), [])
        entries, _, _ = cronboard_entries(jobs(), confirmed=True)
        entries[-1]["scripts"]["script"] = "a\x00b"
        with self.assertRaises(WatchersError):
            self.store.batch_create(entries, request_id="bad-script")
        self.assertEqual(self.store.list(), [])
        self.assertEqual(list(self.store.root.glob("wat_*")), [])

    def test_bad_import_shapes_and_nul_fail_preflight(self):
        for change in ({"id": "synthetic-job-0"}, {"interpreter": []}, {"command": "a\x00b"}, {"enabled": "true"}, {"scheduleTimeZone": "Fake/Zone"}):
            value = jobs()
            value[-1].update(change)
            with self.subTest(change=change), self.assertRaises(WatchersError):
                cronboard_entries(value)

    def test_bundle_roundtrip_paused_new_identity_new_machine(self):
        value = example()
        original = self.store.create(value["definition"], scripts=value["scripts"], request_id="source")
        bundle = self.store.export(original["id"])
        target = WatchersStore(Path(self.tmp.name) / "target.sqlite3", Path(self.tmp.name) / "target", "another-machine")
        entry = bundle_entry(bundle)
        imported = target.batch_create([entry], request_id="bundle")[0]
        self.assertEqual(imported["state"], "paused")
        self.assertEqual(imported["machine"]["id"], "another-machine")
        self.assertNotEqual(imported["id"], original["id"])
        self.assertEqual(imported["summary"], original["summary"])
        self.assertEqual(target.get_script(imported["id"], "check")["content"], value["scripts"]["check"])
        self.assertEqual(self.store.get(original["id"])["state"], "draft")

    def test_source_batch_resume_schedules_from_now_then_pause(self):
        entries, _, _ = cronboard_entries(jobs(), confirmed=True)
        self.store.batch_create(entries, request_id="import")
        result = route(self.service, "POST", ["actions"], {}, {"request_id": "cutover", "action": "resume", "source": "cronboard"})
        self.assertEqual(len(result["watchers"]), 8)
        self.assertEqual(route(self.service, "POST", ["actions"], {}, {"request_id": "cutover", "action": "resume", "source": "cronboard"}), result)
        self.assertTrue(all(value["state"] == "active" and value["next_fire_at"] for value in result["watchers"]))
        self.assertEqual(self.store.runs(source="cronboard"), [])
        paused = route(self.service, "POST", ["actions"], {}, {"request_id": "rollback", "action": "pause", "source": "cronboard"})
        self.assertTrue(all(value["state"] == "paused" and value["next_fire_at"] is None for value in paused["watchers"]))

    def test_duplicate_imported_watcher_is_an_independent_draft(self):
        entries, _, _ = cronboard_entries(jobs(), confirmed=True)
        original = self.store.batch_create(entries, request_id="import")[0]
        duplicated = route(self.service, "POST", [original["id"], "actions"], {}, {"request_id": "duplicate", "action": "duplicate"})["watcher"]
        self.assertNotEqual(duplicated["id"], original["id"])
        self.assertEqual(duplicated["state"], "draft")
        self.assertNotIn("source", duplicated)
        self.assertEqual(self.store.get(original["id"])["state"], "paused")
