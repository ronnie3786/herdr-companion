"""A local claim or launch fault must not stop independent First Mate work."""
import errno
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_runtime import FirstMateRuntime, _write_json
from herdr_harness.first_mate_store import FirstMateStore


class FirstMateDispatchIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = FirstMateStore(self.root / "state.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def feature(self, title, *, cwd=None):
        return self.store.create_feature({"title": title, "goal": "Plan synthetic work",
            "cwd": str(cwd or self.root), "request_id": "create-" + title})

    def healthy_targets(self):
        healthy = self.feature("Healthy feature")
        lead = self.store.ensure_lead(str(self.root))
        self.store.append_human_message(lead["id"], "What needs attention?", "lead-turn")
        return healthy, lead

    def stage(self, feature):
        claim = self.store.claim_message(feature["id"], self.runtime.owner)
        visit = self.store.start_visit(feature["id"], "implementation", "Implement", "visit-" + feature["id"],
                                       feature["revision"], claim["id"])
        self.store.finish_message(claim["id"], self.runtime.owner)
        return visit

    def assignment(self, feature, visit, *, cwd=None):
        return self.store.create_assignment(visit["id"], {"title": "Synthetic worker", "role": "coder",
            "prompt": "Implement the synthetic requirement", "request_id": "worker-" + feature["id"],
            "metadata": {"workspace_mode": "read_only", "worktree_path": str(cwd or self.root)}})

    def invalid_session_claim(self, feature):
        claim = self.store.claim_message(feature["id"], self.runtime.owner)
        path = self.root / ("replaced-session-folder-" + feature["id"])
        path.write_text("A synthetic file replaced the retained session directory")
        self.store.bind_coordinator_session(feature["id"], self.runtime.owner, "synthetic-" + feature["id"],
                                            str(path / "session.jsonl"))
        return claim

    def reconcile(self, *, real_launch_feature=None):
        launches = []
        original_launch = self.runtime._launch

        def launch(job):
            if job["feature_id"] == real_launch_feature:
                return original_launch(job)
            launches.append(job)

        with patch.object(self.runtime, "capabilities", return_value={"available": True}), \
             patch.object(self.runtime, "_launch", side_effect=launch), \
             patch.object(self.runtime.reliability, "tick") as tick, \
             patch.object(self.runtime, "_watch"):
            self.runtime.reconcile()
        return launches, tick

    def assert_claim_preserved(self, feature, claim):
        current = next(message for message in self.store.pending_messages(feature["id"])
                       if message["id"] == claim["id"])
        self.assertEqual((current["status"], current["owner"]), ("processing", claim["owner"]))
        self.assertEqual(self.store.get_feature(feature["id"])["coordinator_owner"], claim["owner"])

    def test_invalid_saved_session_claim_gap_still_launches_healthy_feature_and_lead(self):
        healthy, lead = self.healthy_targets()
        broken = self.feature("Broken feature")
        claim = self.invalid_session_claim(broken)
        launches, tick = self.reconcile()
        self.assertEqual({job["feature_id"] for job in launches}, {healthy["id"], lead["id"]})
        self.assert_claim_preserved(broken, claim)
        self.assertIn(broken["id"], tick.call_args.kwargs["excluded_feature_ids"])
        self.assertTrue(any(event["type"] == "runtime.error" for event in self.store.snapshot(broken["id"])["events"]))

    def test_deleted_feature_directory_still_launches_healthy_feature_and_lead(self):
        healthy, lead = self.healthy_targets()
        broken = self.feature("Deleted project", cwd=self.root / "deleted-project")
        launches, _ = self.reconcile(real_launch_feature=broken["id"])
        self.assertEqual({job["feature_id"] for job in launches}, {healthy["id"], lead["id"]})
        claim = self.store.pending_messages(broken["id"])[0]
        self.assert_claim_preserved(broken, claim)
        self.assertEqual(len([job for job in self.runtime._jobs() if job["feature_id"] == broken["id"]]), 1)

    def test_deleted_worker_directory_retains_dispatch_and_continues_other_features(self):
        healthy, lead = self.healthy_targets()
        broken = self.feature("Deleted worker checkout")
        visit = self.stage(broken)
        assignment = self.assignment(broken, visit, cwd=self.root / "deleted-worktree")
        launches, _ = self.reconcile(real_launch_feature=broken["id"])
        self.assertEqual({job["feature_id"] for job in launches}, {healthy["id"], lead["id"]})
        current = self.store.get_assignment(assignment["id"])
        self.assertEqual((current["status"], current["owner"]), ("dispatching", self.runtime.owner))
        self.assertEqual(current["generation"], 1)
        job = next(job for job in self.runtime._jobs() if job["feature_id"] == broken["id"])
        self.assertEqual(job["claim"]["dispatch_id"], current["dispatch_id"])

    def test_failed_claim_gap_fences_existing_jobs_and_reserves_one_worker_slot(self):
        self.runtime.max_workers = 1
        healthy, lead = self.healthy_targets()
        healthy_visit = self.stage(healthy)
        waiting = self.assignment(healthy, healthy_visit)
        self.store.append_human_message(healthy["id"], "Report progress", "healthy-progress")
        broken = self.feature("Broken saved session")
        visit = self.stage(broken)
        assignment = self.assignment(broken, visit)
        worker = self.store.claim_assignment(assignment["id"], self.runtime.owner)
        job = self.runtime._new_job(broken, kind="worker", prompt="Synthetic work", claim=worker)
        self.store.bind_session(assignment["id"], worker["generation"], self.runtime.owner,
                                "synthetic-worker", job["session_file"], "worker-run")
        _write_json(self.runtime._job_dir(job) / "started.json", {"synthetic": True})
        before = self.store.get_assignment(assignment["id"])
        self.store.append_human_message(broken["id"], "Report progress", "broken-progress")
        claim = self.invalid_session_claim(broken)
        with patch.object(self.runtime, "_observe") as observe:
            launches, _ = self.reconcile()
        observe.assert_not_called()
        self.assertEqual({item["feature_id"] for item in launches}, {healthy["id"], lead["id"]})
        self.assertTrue(all(item["kind"] == "coordinator" for item in launches))
        self.assertEqual(self.store.get_assignment(waiting["id"])["status"], "queued")
        after = self.store.get_assignment(assignment["id"])
        for key in ("status", "owner", "generation", "dispatch_id", "native_session_id"):
            self.assertEqual(after[key], before[key])
        self.assert_claim_preserved(broken, claim)

    def test_claim_gap_global_durability_errors_prevent_every_launch(self):
        healthy, lead = self.healthy_targets()
        broken = self.feature("Claim gap")
        claim = self.store.claim_message(broken["id"], self.runtime.owner)
        errors = [OSError(code, "Synthetic shared storage failure")
                  for code in (errno.ENOSPC, errno.EDQUOT, errno.EROFS)] + [sqlite3.OperationalError("Synthetic database failure")]
        for error in errors:
            with self.subTest(error=type(error).__name__, code=getattr(error, "errno", None)), \
                 patch.object(self.runtime, "_new_job", side_effect=error), \
                 patch.object(self.runtime, "_launch") as launch:
                with self.assertRaises(type(error)):
                    self.runtime.reconcile()
                launch.assert_not_called()
                self.assert_claim_preserved(broken, claim)
                self.assertEqual(self.store.pending_messages(healthy["id"])[0]["status"], "queued")
                self.assertEqual(self.store.pending_messages(lead["id"])[0]["status"], "queued")

    def test_new_dispatch_storage_failure_stops_remaining_launches(self):
        healthy, lead = self.healthy_targets()
        broken = self.feature("Full storage")
        with patch.object(self.runtime, "_require_storage", side_effect=OSError(errno.ENOSPC, "Synthetic full disk")):
            launches, _ = self.reconcile(real_launch_feature=broken["id"])
        self.assertEqual(launches, [])
        self.assertEqual(self.store.pending_messages(healthy["id"])[0]["status"], "queued")
        self.assertEqual(self.store.pending_messages(lead["id"])[0]["status"], "queued")


if __name__ == "__main__":
    unittest.main()
