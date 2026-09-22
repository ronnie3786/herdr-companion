"""Failure and ownership contracts for the durable First Mate work ledger."""
from __future__ import annotations

import tempfile
import threading
import unittest
from pathlib import Path

from herdr_harness.first_mate_store import FirstMateError, FirstMateStore


class FirstMateStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "first-mate.sqlite3"
        self.store = FirstMateStore(self.path)
        self.addCleanup(lambda: self.store.close())
        self.feature = self.store.create_feature({"title": "Garden schedule", "goal": "Plan a garden watering feature", "cwd": "/tmp/synthetic-garden", "work_item_id": "SYNTH-31", "request_id": "feature-create"})

    def stage(self):
        message = self.store.claim_message(self.feature["id"], "coordinator")
        visit = self.store.start_visit(self.feature["id"], "plan", "Planning", "visit-1", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Planning is running.")
        return visit

    def assignment(self, visit=None, suffix="1", **extra):
        visit = visit or self.stage()
        return self.store.create_assignment(visit["id"], {"title": "Architecture review " + suffix, "role": "reviewer", "prompt": "Review the garden scheduling design.", "request_id": "assignment-" + suffix, **extra})

    def running(self, assignment=None, suffix="1"):
        assignment = assignment or self.assignment()
        claimed = self.store.claim_assignment(assignment["id"], "worker-" + suffix)
        return self.store.bind_session(assignment["id"], claimed["generation"], "worker-" + suffix, "native-" + suffix, "/tmp/synthetic-pi/session-" + suffix + ".jsonl", "run-" + suffix)

    def outcome(self, assignment, request_id="result", **extra):
        return self.store.record_outcome(assignment["id"], assignment["generation"], assignment["native_session_id"], assignment["input_revision"], "success", "Review completed with evidence.", request_id, **extra)

    def assert_code(self, code, callback):
        with self.assertRaises(FirstMateError) as error:
            callback()
        self.assertEqual(error.exception.code, code)

    def test_duplicate_commands_are_identical_and_changed_payload_conflicts(self):
        duplicate = self.store.create_feature({"title": "Garden schedule", "goal": "Plan a garden watering feature", "cwd": "/tmp/synthetic-garden", "work_item_id": "SYNTH-31", "request_id": "feature-create"})
        self.assertEqual(self.feature, duplicate)
        self.assertEqual(len(self.store.list_features()), 1)
        self.assertEqual(len(self.store.snapshot(self.feature["id"])["messages"]), 1)
        self.assert_code("idempotency_conflict", lambda: self.store.create_feature({"title": "Different", "goal": "Plan a garden watering feature", "cwd": "/tmp/synthetic-garden", "work_item_id": "SYNTH-31", "request_id": "feature-create"}))
        first = self.store.append_human_message(self.feature["id"], "Do not deploy; discuss options", "direction-1")
        second = self.store.append_human_message(self.feature["id"], "Do not deploy; discuss options", "direction-1")
        self.assertEqual(first, second)
        self.assertEqual(first["role"], "user")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "ready")

    def test_archive_is_an_idempotent_presentation_axis_that_preserves_running_work(self):
        assignment = self.running()
        self.store.begin_handoff(assignment["id"], 1, "handoff-before-archive", "Retained checkpoint")
        before = self.store.snapshot(self.feature["id"])
        archived = self.store.set_archived(self.feature["id"], True, {
            "request_id": "archive-one", "reason": "superseded",
        })
        duplicate = self.store.set_archived(self.feature["id"], True, {
            "request_id": "archive-one", "reason": "superseded",
        })
        self.assertEqual(duplicate, archived)
        self.assertEqual(archived["archive_reason"], "superseded")
        self.assertIsNotNone(archived["archived_at"])
        self.assertEqual(self.store.list_features(), [])
        self.assertEqual([item["id"] for item in self.store.list_features("archived")], [self.feature["id"]])
        self.assertEqual([item["id"] for item in self.store.list_features("all")], [self.feature["id"]])

        after = self.store.snapshot(self.feature["id"])
        for field in ("status", "revision", "current_visit_id", "work_item_id"):
            self.assertEqual(after["feature"][field], before["feature"][field])
        for collection in ("visits", "assignments", "documents", "sessions", "messages", "handoffs"):
            self.assertEqual(after[collection], before[collection])
        self.assertEqual(
            [event["id"] for event in after["events"][:-1]],
            [event["id"] for event in before["events"]],
        )
        self.assertEqual(after["events"][-1]["type"], "feature.archived")

        restored = self.store.set_archived(self.feature["id"], False, {"request_id": "unarchive-one"})
        self.assertIsNone(restored["archived_at"])
        self.assertIsNone(restored["archive_reason"])
        self.assertEqual(restored["status"], before["feature"]["status"])
        self.assertEqual(len(self.store.list_features()), 1)

    def test_archive_reason_and_list_view_are_validated(self):
        self.assert_code("invalid_request", lambda: self.store.set_archived(
            self.feature["id"], True, {"request_id": "archive-invalid", "reason": "finished"}
        ))
        self.assert_code("invalid_request", lambda: self.store.list_features("hidden"))

    def test_messages_are_verbatim_and_human_priority_does_not_allow_two_writers(self):
        first = self.store.claim_message(self.feature["id"], "owner-1")
        self.store.queue_system_message(self.feature["id"], "An agent completed", "background")
        user = self.store.append_human_message(self.feature["id"], "What is our status?", "human")
        self.assertIsNone(self.store.claim_message(self.feature["id"], "owner-2"))
        self.store.finish_message(first["id"], "owner-1")
        self.assertEqual(self.store.claim_message(self.feature["id"], "owner-2")["id"], user["id"])
        self.assert_code("stale_owner", lambda: self.store.finish_message(user["id"], "owner-1"))
        self.assert_code("writer_not_stopped", lambda: self.store.release_message(user["id"], "owner-2", "restart"))
        self.store.release_message(user["id"], "owner-2", "Coordinator verified stopped", verified_stopped=True)
        self.assertEqual(self.store.claim_message(self.feature["id"], "owner-3")["id"], user["id"])

    def test_cross_connection_atomic_dispatch_claim_and_restart_preserves_receipt(self):
        assignment = self.assignment()
        second = FirstMateStore(self.path)
        self.addCleanup(second.close)
        barrier, results = threading.Barrier(2), []
        def claim(store, owner):
            barrier.wait()
            try:
                results.append(store.claim_assignment(assignment["id"], owner))
            except FirstMateError as error:
                results.append(error.code)
        threads = [threading.Thread(target=claim, args=(store, owner)) for store, owner in [(self.store, "owner-a"), (second, "owner-b")]]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        successes = [result for result in results if isinstance(result, dict)]
        self.assertEqual(len(successes), 1)
        self.assertIn("not_dispatchable", results)
        self.store.close()
        self.store = FirstMateStore(self.path)
        persisted = self.store.get_assignment(assignment["id"])
        self.assertEqual(persisted["status"], "dispatching")
        self.assertEqual(persisted["dispatch_id"], successes[0]["dispatch_id"])
        self.assertEqual(len(self.store.list_attempts(assignment["id"])), 1)
        self.assert_code("writer_not_stopped", lambda: self.store.recover_assignment(assignment["id"], 1, "No observed process", "recovery"))

    def test_missing_outcome_is_not_completion_and_recovery_is_bounded(self):
        assignment = self.running()
        visit = self.store.snapshot(self.feature["id"])["visits"][0]
        self.assert_code("stage_incomplete", lambda: self.store.complete_visit(visit["id"], "Done", "Implement", "complete"))
        for index in range(1, 4):
            recovered = self.store.recover_assignment(assignment["id"], assignment["generation"], "Process exited without a typed outcome", "recovery-" + str(index), verified_stopped=True)
            if index <= 2:
                self.assertEqual(recovered["status"], "queued")
                assignment = self.running(recovered, suffix="recovery-" + str(index))
            else:
                self.assertEqual(recovered["status"], "blocked")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "blocked")
        self.assertEqual(len(self.store.list_attempts(assignment["id"])), 3)
        self.assertEqual(self.store.get_session("native-1")["status"], "retained")

    def test_success_is_idempotent_documents_retained_and_every_stage_waits(self):
        assignment = self.running()
        documents = [{"title": "Architecture", "content": "# Verified design", "media_type": "text/markdown"}, {"title": "Review evidence", "content": "Two scheduling cases verified."}]
        result = self.outcome(assignment, documents=documents)
        duplicate = self.outcome(assignment, documents=documents)
        self.assertEqual(result, duplicate)
        self.assertEqual(len(self.store.snapshot(self.feature["id"])["documents"]), 2)
        self.assertEqual(len([m for m in self.store.pending_messages() if m["role"] == "system"]), 1)
        self.assert_code("idempotency_conflict", lambda: self.outcome(assignment, documents=[]))
        self.store.complete_visit(assignment["visit_id"], "Plan verified", "Implement the plan", "stage-done")
        feature = self.store.get_feature(self.feature["id"])
        self.assertEqual(feature["status"], "awaiting_direction")
        self.assertEqual(self.store.list_assignments(["queued"]), [])
        background = self.store.claim_message(feature["id"], "coordinator-2")
        self.assert_code("human_direction_required", lambda: self.store.start_visit(feature["id"], "implement", "Implementation", "visit-2", 1, background["id"]))
        self.store.finish_message(background["id"], "coordinator-2")
        direction = self.store.append_human_message(feature["id"], "Implement the plan, leave reminders for later.", "next")
        self.store.claim_message(feature["id"], "coordinator-3")
        next_visit = self.store.start_visit(feature["id"], "implement", "Implementation", "visit-2", 1, direction["id"])
        self.assertEqual(next_visit["status"], "running")
        snapshot = self.store.snapshot(feature["id"])
        self.assertEqual(len(snapshot["visits"]), 2)
        document = self.store.get_document(snapshot["documents"][0]["id"])
        self.assertEqual(document["native_session_id"], assignment["native_session_id"])
        self.assertEqual(document["generation"], 1)
        self.assertIn("content", document)
        self.assertNotIn("content", snapshot["documents"][0])

    def test_direction_before_stage_completion_cannot_authorize_next_stage(self):
        assignment = self.running()
        question = self.store.append_human_message(self.feature["id"], "How is planning going?", "status-question")
        self.store.claim_message(self.feature["id"], "coordinator")
        self.store.finish_message(question["id"], "coordinator", "Still running.")
        self.outcome(assignment)
        self.store.complete_visit(assignment["visit_id"], "Planning done", "Implement", "complete")
        self.assert_code("human_direction_required", lambda: self.store.start_visit(self.feature["id"], "implement", "Implementation", "next", 1, question["id"]))

    def test_outcomes_verify_generation_session_revision_and_code_revision(self):
        assignment = self.running(self.assignment(metadata={"expected_code_revision": "synthetic-revision-a"}))
        self.assert_code("stale_generation", lambda: self.store.record_outcome(assignment["id"], 999, assignment["native_session_id"], 1, "success", "Done", "wrong-generation"))
        self.assert_code("session_mismatch", lambda: self.store.record_outcome(assignment["id"], 1, "native-unrelated", 1, "success", "Done", "wrong-session"))
        self.assert_code("stale_revision", lambda: self.store.record_outcome(assignment["id"], 1, assignment["native_session_id"], 2, "success", "Done", "wrong-plan"))
        self.assert_code("stale_code_revision", lambda: self.outcome(assignment, code_revision="synthetic-revision-b"))
        self.assertEqual(self.outcome(assignment, code_revision="synthetic-revision-a")["status"], "completed")

    def test_partial_document_validation_rolls_back_entire_outcome(self):
        assignment = self.running()
        self.assert_code("invalid_request", lambda: self.outcome(assignment, documents=[{"title": "Valid", "content": "Evidence"}, {"title": "", "content": "Invalid"}]))
        self.assertEqual(self.store.get_assignment(assignment["id"])["status"], "running")
        self.assertEqual(self.store.snapshot(self.feature["id"])["documents"], [])
        self.assertEqual(self.outcome(assignment, documents=[{"title": "Valid", "content": "Evidence"}])["status"], "completed")

    def test_pausing_blocks_dispatch_and_resume_does_not_cross_human_gate(self):
        assignment = self.assignment()
        self.store.feature_action(self.feature["id"], "pause", "pause")
        self.assert_code("not_dispatchable", lambda: self.store.claim_assignment(assignment["id"], "worker"))
        self.store.feature_action(self.feature["id"], "resume", "resume")
        assignment = self.running(assignment)
        self.assert_code("writer_not_stopped", lambda: self.store.feature_action(self.feature["id"], "cancel", "cancel"))
        self.outcome(assignment)
        self.store.complete_visit(assignment["visit_id"], "Plan done", "Implement", "completed")
        self.store.feature_action(self.feature["id"], "pause", "pause-again")
        self.store.feature_action(self.feature["id"], "resume", "resume-again")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "awaiting_direction")

    def test_revision_supersedes_old_work_preserves_history_and_rejects_late_result(self):
        assignment = self.running()
        message = self.store.append_human_message(self.feature["id"], "Only support manual schedules", "redirect")
        self.store.claim_message(self.feature["id"], "coordinator")
        self.assert_code("writer_not_stopped", lambda: self.store.revise_feature(self.feature["id"], "Only manual schedules", 1, "revision", message["id"]))
        revised = self.store.revise_feature(self.feature["id"], "Only manual schedules", 1, "revision", message["id"], verified_stopped=True)
        self.assertEqual(revised["revision"], 2)
        self.assertEqual(self.store.get_assignment(assignment["id"])["status"], "superseded")
        self.assert_code("stale_revision", lambda: self.outcome(assignment))
        visit = self.store.start_visit(self.feature["id"], "plan", "Revised planning", "next", 2, message["id"])
        self.assertEqual(visit["revision"], 2)
        previous = self.store.snapshot(self.feature["id"])["visits"][0]
        self.assertEqual(previous["revision"], 1)
        self.assertEqual(previous["status"], "superseded")

    def test_native_session_and_file_have_single_owner(self):
        visit = self.stage()
        first = self.running(self.assignment(visit, "a"), "a")
        second = self.store.claim_assignment(self.assignment(visit, "b")["id"], "worker-b")
        self.assert_code("session_owned", lambda: self.store.bind_session(second["id"], second["generation"], "worker-b", first["native_session_id"], first["session_file"]))
        self.assert_code("session_owned", lambda: self.store.bind_session(second["id"], second["generation"], "worker-b", "native-other", first["session_file"]))
        self.assert_code("stale_owner", lambda: self.store.bind_session(second["id"], second["generation"], "wrong-owner", "native-b", "/tmp/synthetic-pi/b.jsonl"))

    def test_handoff_survives_restart_and_requires_successor_ack_before_retirement(self):
        assignment = self.running()
        handoff = self.store.begin_handoff(assignment["id"], 1, "handoff", "Completed schema review. Next inspect scheduling boundaries.")
        self.assertEqual(self.store.get_session("native-1")["status"], "active")
        self.assert_code("writer_not_stopped", lambda: self.store.bind_handoff_successor(handoff["id"], "native-next", "/tmp/synthetic-pi/next.jsonl", "worker-next", "successor"))
        successor = self.store.bind_handoff_successor(handoff["id"], "native-next", "/tmp/synthetic-pi/next.jsonl", "worker-next", "successor", verified_predecessor_stopped=True)
        self.assertEqual(successor["generation"], 2)
        self.assertEqual(successor["status"], "awaiting_ack")
        self.assertEqual(self.store.get_session("native-1")["status"], "quiesced")
        self.assert_code("outcome_already_settled", lambda: self.outcome(successor))
        self.store.close()
        self.store = FirstMateStore(self.path)
        self.assert_code("session_mismatch", lambda: self.store.acknowledge_handoff(handoff["id"], "native-unrelated", 2, "ack"))
        result = self.store.acknowledge_handoff(handoff["id"], "native-next", 2, "ack")
        self.assertEqual(result["status"], "running")
        self.assertEqual(self.store.get_session("native-1")["status"], "retained")
        self.assertEqual(self.store.list_attempts(assignment["id"])[0]["status"], "handed_off")
        self.assertEqual(self.store.get_document(handoff["document_id"])["native_session_id"], "native-1")
        self.assert_code("stale_generation", lambda: self.outcome(assignment))
        self.assertEqual(self.outcome(result)["status"], "completed")


    def test_unknown_dispatch_requires_observation_before_recovery(self):
        assignment = self.store.claim_assignment(self.assignment()["id"], "worker")
        unknown = self.store.mark_dispatch_unknown(assignment["id"], 1, "No supervisor receipt", "unknown")
        self.assertEqual(unknown["dispatch_id"], assignment["dispatch_id"])
        self.assertEqual(unknown["status"], "recovering")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "recovering")
        self.assert_code("not_dispatchable", lambda: self.store.claim_assignment(assignment["id"], "another-owner"))
        recovered = self.store.recover_assignment(assignment["id"], 1, "Verified both processes stopped", "recover", verified_stopped=True)
        self.assertEqual(recovered["status"], "queued")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "running")
        replacement = self.store.claim_assignment(assignment["id"], "new-owner")
        self.assertEqual(replacement["generation"], 2)
        self.assertNotEqual(replacement["dispatch_id"], assignment["dispatch_id"])

    def test_safe_human_pause_resumes_without_spending_recovery_budget(self):
        assignment = self.running()
        self.store.feature_action(self.feature["id"], "pause", "pause")
        self.assertEqual(self.store.get_assignment(assignment["id"])["status"], "running")
        stopped = self.store.acknowledge_stopped(assignment["id"], 1, "stopped")
        self.assertEqual(stopped["status"], "paused")
        self.assertEqual(self.store.get_session("native-1")["status"], "retained")
        self.store.feature_action(self.feature["id"], "resume", "resume")
        resumed = self.running(self.store.get_assignment(assignment["id"]), "resumed")
        self.assertEqual(resumed["generation"], 2)
        self.assertEqual(resumed["recovery_count"], 0)
        self.assert_code("stale_generation", lambda: self.outcome(assignment))

    def test_known_stopped_cancel_preserves_sessions_and_documents(self):
        assignment = self.running()
        handoff = self.store.begin_handoff(assignment["id"], 1, "handoff", "Checkpoint captured before cancellation.")
        self.store.acknowledge_stopped(assignment["id"], 1, "stopped", status="cancelled")
        result = self.store.feature_action(self.feature["id"], "cancel", "cancel")
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(self.store.get_document(handoff["document_id"])["content"], "Checkpoint captured before cancellation.")
        self.assertEqual(self.store.get_session("native-1")["status"], "retained")
        self.assert_code("feature_closed", lambda: self.store.append_human_message(self.feature["id"], "Continue", "more"))

    def test_review_retry_retains_prior_verdict_and_rechecks_new_revision(self):
        assignment = self.running(self.assignment(metadata={"expected_code_revision": "synthetic-a"}))
        self.store.record_outcome(assignment["id"], 1, assignment["native_session_id"], 1, "needs_changes", "Missing boundary check", "finding", documents=[{"title": "Review", "content": "Boundary check is missing."}], code_revision="synthetic-a")
        self.assert_code("writer_not_stopped", lambda: self.store.retry_assignment(assignment["id"], "Review the fixed boundary", "retry"))
        retry = self.store.retry_assignment(assignment["id"], "Review the fixed boundary", "retry", metadata={"expected_code_revision": "synthetic-b"}, verified_stopped=True)
        successor = self.running(retry, "fixed")
        self.assert_code("stale_code_revision", lambda: self.outcome(successor, code_revision="synthetic-a"))
        self.outcome(successor, code_revision="synthetic-b")
        self.assertEqual(self.store.list_attempts(assignment["id"])[0]["verdict"], "needs_changes")
        self.assertEqual(self.store.snapshot(self.feature["id"])["documents"][0]["generation"], 1)
        self.store.complete_visit(assignment["visit_id"], "Reviewed corrected boundary", "Proof", "complete")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "awaiting_direction")

    def test_internal_repairs_cannot_reset_their_limit_via_metadata(self):
        assignment = self.running()
        for index in range(1, 4):
            self.store.record_outcome(assignment["id"], assignment["generation"], assignment["native_session_id"], 1, "needs_changes", "Boundary still incorrect", "finding-" + str(index))
            result = self.store.retry_assignment(assignment["id"], "Repair boundary", "retry-" + str(index), metadata={"repair_count": 0, "max_repair_attempts": 100}, verified_stopped=True)
            if index < 3:
                assignment = self.running(result, "retry-" + str(index))
            else:
                self.assertEqual(result["status"], "blocked")
                self.assertEqual(result["metadata"]["repair_count"], 3)
                self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "blocked")

    def test_coordinator_session_identity_survives_turns_without_concurrent_claims(self):
        first = self.store.claim_message(self.feature["id"], "coordinator-a")
        feature = self.store.bind_coordinator_session(self.feature["id"], "coordinator-a", "native-coordinator", "/tmp/synthetic-pi/coordinator.jsonl")
        self.assertEqual(feature["native_session_id"], "native-coordinator")
        self.store.finish_message(first["id"], "coordinator-a", "I have the feature goal.")
        second = self.store.append_human_message(self.feature["id"], "Discuss the tradeoffs", "discuss")
        self.store.claim_message(self.feature["id"], "coordinator-b")
        self.assert_code("stale_owner", lambda: self.store.bind_coordinator_session(self.feature["id"], "coordinator-a", "native-coordinator", "/tmp/synthetic-pi/coordinator.jsonl"))
        self.store.bind_coordinator_session(self.feature["id"], "coordinator-b", "native-coordinator", "/tmp/synthetic-pi/coordinator.jsonl")
        self.store.finish_message(second["id"], "coordinator-b")
        self.assertEqual(len([m for m in self.store.snapshot(self.feature["id"])["messages"] if m["role"] == "user"]), 2)


    def test_internal_human_gate_cannot_be_resumed_by_system_or_generic_resume(self):
        assignment = self.running()
        checkpoint = self.store.request_human_gate(assignment["id"], 1, assignment["native_session_id"], "Choose whether to change the public API", "gate")
        self.assertEqual(checkpoint["status"], "paused")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "awaiting_direction")
        self.assert_code("writer_not_stopped", lambda: self.store.feature_action(self.feature["id"], "cancel", "premature-cancel"))
        self.store.acknowledge_stopped(assignment["id"], 1, "gate-stop")
        system = self.store.claim_message(self.feature["id"], "coordinator")
        self.assert_code("human_direction_required", lambda: self.store.resolve_human_gate(assignment["id"], system["id"], "Continue", "resolve", verified_stopped=True))
        self.store.finish_message(system["id"], "coordinator", "Please choose an API direction.")
        self.store.feature_action(self.feature["id"], "pause", "pause")
        self.store.feature_action(self.feature["id"], "resume", "resume")
        self.assertEqual(self.store.get_assignment(assignment["id"])["status"], "paused")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "awaiting_direction")
        self.assert_code("first_mate_conflict", lambda: self.store.retry_assignment(assignment["id"], "Continue", "retry", verified_stopped=True))
        human = self.store.append_human_message(self.feature["id"], "Keep the public API unchanged", "direction")
        self.store.claim_message(self.feature["id"], "coordinator")
        self.assert_code("writer_not_stopped", lambda: self.store.resolve_human_gate(assignment["id"], human["id"], human["text"], "resolve"))
        resolved = self.store.resolve_human_gate(assignment["id"], human["id"], human["text"], "resolve", verified_stopped=True)
        self.assertEqual(resolved["status"], "queued")
        self.assertIn("Keep the public API unchanged", resolved["prompt"])
        self.assertEqual(resolved["metadata"]["human_gate"]["status"], "resolved")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "running")
        self.assertEqual(len(self.store.snapshot(self.feature["id"])["visits"]), 1)

    def test_prior_direction_does_not_approve_later_internal_human_gate(self):
        assignment = self.running()
        original = self.store.snapshot(self.feature["id"])["messages"][0]
        self.store.request_human_gate(assignment["id"], 1, assignment["native_session_id"], "New risk needs a choice", "gate")
        self.store.acknowledge_stopped(assignment["id"], 1, "stop")
        self.assert_code("human_direction_required", lambda: self.store.resolve_human_gate(assignment["id"], original["id"], "Continue", "old-approval", verified_stopped=True))


    def test_coordinator_rotation_preserves_history_and_rejects_live_or_stale_writers(self):
        message = self.store.claim_message(self.feature["id"], "coordinator")
        self.store.bind_coordinator_session(self.feature["id"], "coordinator", "native-primary", "/tmp/synthetic-pi/primary.jsonl")
        self.assert_code("writer_not_stopped", lambda: self.store.rotate_coordinator_session(self.feature["id"], "native-primary", "rotate", verified_stopped=True))
        self.store.finish_message(message["id"], "coordinator", "The current plan and decisions are retained.")
        result = self.store.rotate_coordinator_session(self.feature["id"], "native-primary", "rotate", verified_stopped=True)
        self.assertIsNone(result["native_session_id"])
        self.assertEqual(self.store.get_session("native-primary")["status"], "retained")
        self.store.append_human_message(self.feature["id"], "Review the next step", "next")
        self.store.claim_message(self.feature["id"], "new-coordinator")
        successor = self.store.bind_coordinator_session(self.feature["id"], "new-coordinator", "native-fresh", "/tmp/synthetic-pi/fresh.jsonl")
        self.assertEqual(successor["native_session_id"], "native-fresh")
        self.assert_code("writer_not_stopped", lambda: self.store.rotate_coordinator_session(self.feature["id"], "native-primary", "stale-rotation", verified_stopped=True))
        self.assertEqual(len([event for event in self.store.get_events(self.feature["id"])["events"] if event["type"] == "coordinator.context_rotated"]), 1)


    def test_selective_revision_keeps_unaffected_writer_and_fences_changed_assignment(self):
        visit = self.stage()
        unaffected = self.running(self.assignment(visit, "keep"), "keep")
        affected = self.running(self.assignment(visit, "change"), "change")
        direction = self.store.append_human_message(self.feature["id"], "Change reminders, keep the scheduling research running", "redirect")
        self.store.claim_message(self.feature["id"], "coordinator")
        self.assert_code("writer_not_stopped", lambda: self.store.revise_feature(self.feature["id"], "Revised reminder scope", 1, "revise", direction["id"], affected_assignment_ids=[affected["id"]]))
        revised = self.store.revise_feature(self.feature["id"], "Revised reminder scope", 1, "revise", direction["id"], verified_stopped=True, affected_assignment_ids=[affected["id"]])
        self.assertNotEqual(revised["current_visit_id"], visit["id"])
        self.assertEqual(revised["revision"], 2)
        retained = self.store.get_assignment(unaffected["id"])
        self.assertEqual(retained["status"], "running")
        self.assertEqual(retained["input_revision"], 1)
        self.assertEqual(retained["visit_id"], visit["id"])
        self.assertEqual(set(retained["visit_ids"]), {visit["id"], revised["current_visit_id"]})
        self.assertTrue(self.store.assignment_is_in_current_visit(unaffected["id"]))
        self.assertFalse(self.store.assignment_is_in_current_visit(affected["id"]))
        self.assert_code("stale_revision", lambda: self.outcome(affected))
        self.store.close()
        self.store = FirstMateStore(self.path)
        self.outcome(unaffected, documents=[{"title":"Scheduling findings","content":"Original scoped research retained."}])
        replacement = self.running(self.assignment({"id":revised["current_visit_id"]}, "replacement"), "replacement")
        self.outcome(replacement)
        self.store.complete_visit(revised["current_visit_id"], "Revised stage complete", "Review results", "complete")
        snapshot = self.store.snapshot(self.feature["id"])
        self.assertEqual(snapshot["feature"]["status"], "awaiting_direction")
        self.assertEqual(snapshot["documents"][0]["visit_id"], visit["id"])
        self.assertEqual(snapshot["documents"][0]["input_revision"], 1)
        self.assertEqual(len(snapshot["memberships"]), 4)

    def test_selective_revision_refuses_completed_code_evidence_that_drifted(self):
        visit = self.stage()
        completed = self.running(self.assignment(visit, "review", metadata={"expected_code_revision":"synthetic-a"}), "review")
        affected = self.running(self.assignment(visit, "implementation"), "implementation")
        self.outcome(completed, code_revision="synthetic-a")
        direction = self.store.append_human_message(self.feature["id"], "Revise implementation and retain the unaffected review only if current", "redirect")
        self.store.claim_message(self.feature["id"], "coordinator")
        self.assert_code("stale_code_revision", lambda: self.store.revise_feature(self.feature["id"], "Changed scope", 1, "revise", direction["id"], verified_stopped=True, affected_assignment_ids=[affected["id"]], carry_forward_evidence={completed["id"]:"synthetic-b"}))
        self.assertEqual(self.store.get_feature(self.feature["id"])["revision"], 1)
        self.assertEqual(len(self.store.snapshot(self.feature["id"])["visits"]), 1)
        revised = self.store.revise_feature(self.feature["id"], "Changed scope", 1, "revise", direction["id"], verified_stopped=True, affected_assignment_ids=[affected["id"]], carry_forward_evidence={completed["id"]:"synthetic-a"})
        self.assertEqual(revised["revision"], 2)
        self.assertTrue(self.store.assignment_is_in_current_visit(completed["id"]))
        self.assertEqual(self.store.get_assignment(completed["id"])["code_revision"], "synthetic-a")

    def test_selective_revision_preserves_pending_internal_human_gate(self):
        assignment = self.running()
        self.store.request_human_gate(assignment["id"], 1, assignment["native_session_id"], "Choose an API boundary", "gate")
        self.store.acknowledge_stopped(assignment["id"], 1, "stopped")
        message = self.store.append_human_message(self.feature["id"], "Update goal wording, keep the API question open", "redirect")
        self.store.claim_message(self.feature["id"], "coordinator")
        revised = self.store.revise_feature(self.feature["id"], "More precise goal", 1, "revise", message["id"], affected_assignment_ids=[])
        self.assertEqual(revised["status"], "awaiting_direction")
        self.assertEqual(self.store.get_assignment(assignment["id"])["metadata"]["human_gate"]["status"], "pending")
        self.assertTrue(self.store.assignment_is_in_current_visit(assignment["id"]))

    def test_snapshot_sessions_includes_failed_predecessor_without_documents(self):
        assignment = self.running()
        self.store.recover_assignment(assignment["id"], 1, "Process stopped before report", "recover", verified_stopped=True)
        successor = self.running(self.store.get_assignment(assignment["id"]), "successor")
        snapshot = self.store.snapshot(self.feature["id"])
        self.assertEqual(snapshot["documents"], [])
        self.assertEqual({session["native_session_id"] for session in snapshot["sessions"]}, {assignment["native_session_id"], successor["native_session_id"]})
        old = next(session for session in snapshot["sessions"] if session["native_session_id"] == assignment["native_session_id"])
        self.assertEqual(old["ownership_status"], "retained")
        self.assertEqual(old["status"], "interrupted")
        self.assertEqual(old["generation"], 1)
        self.assertEqual(old["attempt"], 1)
        self.assertNotIn("session_file", old)


    def test_parent_waits_without_new_session_and_cannot_succeed_before_children(self):
        parent = self.running()
        child = self.assignment({"id":parent["visit_id"]}, "child", metadata={"parent_assignment_id":parent["id"]})
        self.assert_code("children_incomplete", lambda: self.outcome(parent))
        waiting = self.store.wait_for_children(parent["id"], 1, parent["native_session_id"], "Child research delegated; waiting asynchronously", "wait")
        self.assertEqual(waiting["status"], "waiting_children")
        self.assert_code("children_incomplete", lambda: self.store.bind_session(parent["id"], 1, "worker-1", parent["native_session_id"], parent["session_file"]))
        self.outcome(self.running(child, "child"))
        resumed = self.store.bind_session(parent["id"], 1, "worker-1", parent["native_session_id"], parent["session_file"])
        self.assertEqual(resumed["status"], "running")
        self.assertEqual(resumed["generation"], 1)
        self.assertEqual(resumed["native_session_id"], parent["native_session_id"])
        self.outcome(resumed)
        self.store.complete_visit(parent["visit_id"], "Parent synthesized child evidence", "Next stage", "complete")
        self.assertEqual(self.store.get_feature(parent["feature_id"])["status"], "awaiting_direction")

    def test_seven_reviewers_must_all_finish_before_stage_completion(self):
        visit = self.stage()
        assignments = [self.running(self.assignment(visit, str(n)), str(n)) for n in range(7)]
        for assignment in assignments[:-1]:
            self.outcome(assignment)
        self.assert_code("stage_incomplete", lambda: self.store.complete_visit(visit["id"], "All reviews", "Proof", "complete"))
        self.outcome(assignments[-1])
        self.store.complete_visit(visit["id"], "All seven reviews completed", "Run proof", "complete")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "awaiting_direction")
        cursor = self.store.get_events(self.feature["id"], limit=2)["cursor"]
        later = self.store.get_events(self.feature["id"], after=cursor)
        self.assertTrue(all(e["sequence"] > cursor for e in later["events"]))


if __name__ == "__main__":
    unittest.main()
