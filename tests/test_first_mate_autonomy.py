"""Synthetic regressions for interrupted turns and bounded worker context."""
import json
import errno
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_runtime import FirstMateRuntime, _write_json
from herdr_harness.first_mate_store import FirstMateStore


class FirstMateAutonomyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = FirstMateStore(self.root / "state.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")
        self.feature = self.store.create_feature({"title": "Synthetic workflow", "goal": "Implement and verify",
            "cwd": str(self.root), "request_id": "create"})

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def coordinator(self):
        claim = self.store.claim_message(self.feature["id"], "owner")
        job = self.runtime._new_job(self.feature, kind="coordinator", claim=claim, prompt="Continue authorized work")
        directory = self.runtime._job_dir(job)
        (directory / "effects.jsonl").write_text(json.dumps({"type": "ledger_ready", "version": 1, "job_id": job["id"]}) + "\n")
        return job

    def test_transient_startup_failure_retries_same_human_message_without_a_question(self):
        first = self.coordinator()
        error = {"ended": True, "error": "Pi did not confirm its saved session during startup", "prompt_sent": False}
        self.runtime._finish(first, error)
        snapshot = self.store.snapshot(self.feature["id"])
        self.assertEqual(snapshot["messages"][0]["status"], "queued")
        self.assertEqual(len(snapshot["messages"]), 1)
        second = self.coordinator()
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(first["claim"]["id"], second["claim"]["id"])
        self.assertIn("SAME authorized", second["prompt"])
        self.assertGreater(second["retry_not_before"], 0)
        self.runtime._finish(second, error)
        third = self.coordinator()
        self.runtime._finish(third, error)
        snapshot = self.store.snapshot(self.feature["id"])
        self.assertEqual(snapshot["messages"][0]["status"], "done")
        self.assertEqual(len([m for m in snapshot["messages"] if m["role"] == "assistant"]), 1)

    def test_transient_continuation_retains_completed_dispatch_facts(self):
        job = self.coordinator()
        directory = self.runtime._job_dir(job)
        _write_json(directory / "requests" / "dispatch.json", {"action": "fm_delegate", "request_id": "dispatch"})
        _write_json(directory / "responses" / "dispatch.json", {"ok": True, "result": {"id": "synthetic-worker"}})
        self.runtime._finish(job, {"ended": True, "error": "Execution exceeded its bounded supervisor deadline"})
        successor = self.coordinator()
        self.assertIn('"tool": "fm_delegate"', successor["prompt"])
        self.assertIn('"status": "completed"', successor["prompt"])

    def test_unknown_or_successful_external_effect_never_replays_coordinator(self):
        job = self.coordinator()
        path = self.runtime._job_dir(job) / "effects.jsonl"
        with path.open("a") as handle:
            handle.write(json.dumps({"type": "start", "id": "send", "tool": "bash", "scope": "external"}) + "\n")
        error = {"ended": True, "error": "Connection reset", "prompt_sent": True}
        self.assertFalse(self.runtime._retry_coordinator(job, error))
        with path.open("a") as handle:
            handle.write(json.dumps({"type": "end", "id": "send", "is_error": False}) + "\n")
        self.assertFalse(self.runtime._retry_coordinator(job, error))

    def test_unconfirmed_managed_operation_prevents_replay(self):
        job = self.coordinator()
        _write_json(self.runtime._job_dir(job) / "requests" / "dispatch.json", {"action": "fm_delegate"})
        self.assertFalse(self.runtime._retry_coordinator(job, {"error": "timeout"}))

    def test_timeout_after_checkpoint_does_not_repeat_the_human_turn(self):
        job = self.coordinator()
        visit = self.store.start_visit(self.feature["id"], "planning", "Plan", "visit", 1, job["claim"]["id"])
        assignment = self.store.create_assignment(visit["id"], {"title": "Plan", "role": "planner",
            "prompt": "Plan", "request_id": "plan"})
        worker = self.store.claim_assignment(assignment["id"], "worker")
        self.store.bind_session(assignment["id"], worker["generation"], "worker", "native-plan",
                                str(self.root / "plan.jsonl"), "plan-run")
        self.store.record_outcome(assignment["id"], worker["generation"], "native-plan", 1,
                                  "success", "Plan verified", "plan-outcome")
        self.store.complete_visit(visit["id"], "Plan ready", "Review the plan", "complete", turn_id=job["claim"]["id"])
        self.runtime._finish(job, {"ended": True, "error": "timeout", "response": "Would you like to proceed?"})
        snapshot = self.store.snapshot(self.feature["id"])
        self.assertEqual(snapshot["messages"][0]["status"], "done")
        self.assertEqual(len([m for m in snapshot["messages"] if m["role"] == "assistant"]), 1)

    def test_new_human_direction_preempts_old_turn_retry(self):
        job = self.coordinator()
        self.store.append_human_message(self.feature["id"], "Hold, do not continue", "hold")
        self.assertFalse(self.runtime._retry_coordinator(job, {"error": "timeout", "prompt_sent": False}))

    def test_worker_status_references_documents_instead_of_loading_history(self):
        coordinator = self.coordinator()
        claim = coordinator["claim"]
        visit = self.store.start_visit(self.feature["id"], "implementation", "Implement", "visit", 1, claim["id"])
        self.store.finish_message(claim["id"], "owner", "Working")
        assignment = self.store.create_assignment(visit["id"], {"title": "Worker", "role": "coder",
            "prompt": "Implement", "request_id": "worker"})
        snapshot = self.store.snapshot(self.feature["id"])
        snapshot["documents"] = [{"id": "doc-" + str(i), "assignment_id": assignment["id"],
            "title": "Proof", "content": "archived proof " * 20000} for i in range(200)]
        snapshot["assignments"][0]["metadata"]["recovery_direction"] = "old direction " * 40000
        snapshot["assignments"][0]["summary"] = "historical summary " * 5000
        snapshot["feature"]["verification"] = {"status": "partially_verified", "missing_suites": [
            {"label": "pkg/suite-" + str(i)} for i in range(4000)]}
        job = {"kind": "worker", "feature_id": self.feature["id"], "claim": assignment}
        with patch.object(self.runtime, "snapshot", return_value=snapshot):
            status = self.runtime._tool(job, "fm_status", {}, "status")
        serialized = json.dumps(status)
        self.assertLess(len(serialized), 30000)
        self.assertNotIn("archived proof", serialized)
        self.assertNotIn("old direction", serialized)
        self.assertEqual(status["assignments"][0]["id"], assignment["id"])
        self.assertTrue(status["documents_truncated"])
        self.assertEqual(status["verification"]["missing_suites_count"], 4000)
        self.assertTrue(status["verification"]["missing_suites_truncated"])

    def test_one_bad_dispatch_does_not_block_other_feature_launch(self):
        broken = self.coordinator()
        other = self.store.create_feature({"title": "Independent", "goal": "Plan",
            "cwd": str(self.root), "request_id": "other"})
        with patch.object(self.runtime, "_observe", side_effect=FileNotFoundError("missing job cwd")), \
             patch.object(self.runtime, "_launch") as launch, \
             patch.object(self.runtime, "capabilities", return_value={"available": True}), \
             patch.object(self.runtime, "_watch"):
            self.runtime.reconcile()
        self.assertEqual([call.args[0]["feature_id"] for call in launch.call_args_list], [other["id"]])
        self.assertEqual(self.store.pending_messages(broken["feature_id"])[0]["status"], "processing")

    def test_storage_error_still_defers_all_new_launches(self):
        self.coordinator()
        self.store.create_feature({"title": "Independent", "goal": "Plan",
            "cwd": str(self.root), "request_id": "other"})
        with patch.object(self.runtime, "_observe", side_effect=OSError(errno.ENOSPC, "storage unavailable")), \
             patch.object(self.runtime, "_launch") as launch:
            self.runtime.reconcile()
        launch.assert_not_called()
