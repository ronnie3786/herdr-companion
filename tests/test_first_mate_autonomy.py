"""Synthetic regressions for interrupted turns and bounded worker context."""
import json
import errno
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_runtime import FirstMateRuntime, _write_json, _pi_command
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

    def test_coordinator_keeps_configured_inactivity_budget_and_separate_total_ceiling(self):
        self.runtime.environ['HERDR_FIRST_MATE_COORDINATOR_TIMEOUT_SECONDS'] = '600'
        self.runtime.environ['HERDR_FIRST_MATE_COORDINATOR_MAX_SECONDS'] = '2400'
        job = self.coordinator()
        self.assertEqual(job['idle_timeout_seconds'], 600)
        self.assertEqual(job['timeout_seconds'], 2400)

    def test_transient_continuation_retains_completed_dispatch_facts(self):
        job = self.coordinator()
        directory = self.runtime._job_dir(job)
        _write_json(directory / "requests" / "dispatch.json", {"action": "fm_delegate", "request_id": "dispatch"})
        _write_json(directory / "responses" / "dispatch.json", {"ok": True, "result": {"id": "synthetic-worker"}})
        self.runtime._finish(job, {"ended": True, "error": "Execution exceeded its bounded supervisor deadline"})
        successor = self.coordinator()
        self.assertIn('"tool": "fm_delegate"', successor["prompt"])
        self.assertIn('"status": "completed"', successor["prompt"])

    def test_lead_retry_keeps_its_charter_and_completed_relay_facts(self):
        self.feature = self.store.ensure_lead(str(self.root))
        self.store.append_human_message(self.feature["id"], "Check the synthetic feature", "lead-turn")
        job = self.coordinator()
        self.assertTrue(job["lead"])
        directory = self.runtime._job_dir(job)
        _write_json(directory / "requests" / "relay.json", {"action": "fm_relay", "request_id": "relay"})
        _write_json(directory / "responses" / "relay.json", {"ok": True, "result": {"relayed": True}})
        self.runtime._finish(job, {"ended": True, "error": "Connection reset"})
        successor = self.coordinator()
        self.assertTrue(successor["lead"])
        self.assertIn("You have no stage authority", successor["charter"])
        self.assertIn('"tool": "fm_relay"', successor["prompt"])
        self.assertGreater(successor["retry_not_before"], 0)

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

    def test_interruption_discloses_completed_shell_receipts_and_retry_reason(self):
        job = self.coordinator()
        path = self.runtime._job_dir(job) / 'effects.jsonl'
        with path.open('a') as handle:
            for index in range(5):
                handle.write(json.dumps({'type': 'start', 'id': str(index), 'tool': 'bash',
                    'scope': 'external', 'command': 'git show HEAD:README.md'}) + '\n')
                handle.write(json.dumps({'type': 'end', 'id': str(index), 'is_error': False}) + '\n')
        self.runtime._finish(job, {'ended': True, 'prompt_sent': True,
                                  'error': 'Execution exceeded its bounded supervisor deadline'})
        snapshot = self.store.snapshot(self.feature['id'])
        reply = snapshot['messages'][-1]['text']
        self.assertIn('Completed workflow tools: none', reply)
        self.assertIn('Other tool receipts: 5 completed of 5 started', reply)
        self.assertIn('Tool effects need reconciliation', reply)
        event = next(e for e in snapshot['events'] if e['type'] == 'coordinator.interrupted')
        self.assertEqual(event['payload']['tool_activity'], {'started_tools': 5, 'completed_tools': 5})
        self.assertIn('reconciliation', event['payload']['automatic_continuation_blocked_reason'])
        self.assertFalse(any(e['type'] == 'coordinator.retry_scheduled' for e in snapshot['events']))

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

    def test_feature_fault_does_not_prevent_a_lead_reply(self):
        self.coordinator()
        lead = self.store.ensure_lead(str(self.root))
        self.store.append_human_message(lead["id"], "What needs attention?", "lead-status")
        with patch.object(self.runtime, "_observe", side_effect=FileNotFoundError("missing job cwd")), \
             patch.object(self.runtime, "_launch") as launch, \
             patch.object(self.runtime, "capabilities", return_value={"available": True}), \
             patch.object(self.runtime, "_watch"):
            self.runtime.reconcile()
        self.assertEqual([call.args[0]["feature_id"] for call in launch.call_args_list], [lead["id"]])
        self.assertTrue(launch.call_args.args[0]["lead"])

    def test_recovery_advisor_can_reach_extension_guarded_observational_shell(self):
        command = _pi_command({"kind": "advisor", "recovery_mode": True,
            "pi_bin": "pi", "session_file": str(self.root / "session.jsonl"),
            "extension": "/synthetic/first-mate.ts", "claim": {}})
        allowed = command[command.index("--tools") + 1].split(",")
        self.assertIn("bash", allowed)
        self.assertNotIn("write", allowed)
        self.assertIn("--no-extensions", command)
        self.assertIn("/synthetic/first-mate.ts", command)

    def test_restricted_advisor_omits_bridge_lineage_flag(self):
        # The bridge that registers --herdr-parent-session-id is not loaded with
        # --no-extensions; passing it made Pi exit before confirming startup.
        base = {"kind": "advisor", "pi_bin": "pi", "session_file": str(self.root / "session.jsonl"),
                "extension": "/synthetic/first-mate.ts", "claim": {},
                "parent_session_id": "synthetic-worker-session"}
        for mode in ("recovery_mode", "reliability_assessment"):
            with self.subTest(mode=mode):
                command = _pi_command({**base, mode: True})
                self.assertIn("--no-extensions", command)
                self.assertNotIn("--herdr-parent-session-id", command)
        command = _pi_command(base)
        self.assertNotIn("--no-extensions", command)
        self.assertEqual(command[command.index("--herdr-parent-session-id") + 1], "synthetic-worker-session")
