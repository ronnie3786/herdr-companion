"""Current work and upcoming work remain visible across bounded read surfaces."""
import json
import hashlib
import unittest
from unittest.mock import patch

from herdr_harness import first_mate_fleet
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_read_models import (
    MESSAGE_PROVENANCE_FIELDS, activity_presentation, event_presentation, message_presentation,
)
from herdr_harness.first_mate_store import FirstMateStore, PENDING_MESSAGE_LIMIT
from tests.test_first_mate_board import BoardFixture


class FirstMateActivityTests(BoardFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.store.path.parent / "runtime")
        self.addCleanup(self.runtime.stop)

    def projections(self):
        return [self.store.snapshot(self.id, events="journal"), self.store.board(self.id),
                self.runtime.read_view(self.id, view="chat", messages=1),
                self.runtime.read_view(self.id, view="overview")]

    def test_pending_work_is_visible_outside_chat_page_and_prevents_false_human_wait(self):
        self.stage()
        system = self.store.queue_system_message(self.id, "Reconcile a finished worker", "background")
        processing = self.store.append_human_message(self.id, "Inspect latest plan", "human-1")
        self.store.claim_message(self.id, "coordinator")
        queued = self.store.append_human_message(self.id, "Q" * 2000, "human-2")
        summary = self.store.list_features()[0]["dashboard_summary"]
        self.assertEqual((summary["queued_message_count"], summary["processing_message_count"],
                          summary["pending_human_message_count"]), (2, 1, 2))
        self.assertFalse(summary["awaiting_turn"])
        for projection in self.projections():
            self.assertEqual(projection["feature"]["dashboard_summary"], summary)
            pending = projection["pending_messages"]
            self.assertEqual([row["id"] for row in pending], [processing["id"], queued["id"], system["id"]])
            self.assertEqual(pending[1]["text"], "Q" * 1200)
            self.assertTrue(pending[1]["text_truncated"])
            self.assertNotIn("owner", pending[0])
            self.assertNotIn("metadata", pending[0])
        before = self.runtime.read_view(self.id, view="overview")["version"]
        self.store.finish_message(processing["id"], "coordinator", "Inspected.")
        while message := self.store.claim_message(self.id, "coordinator"):
            self.store.finish_message(message["id"], "coordinator", "Handled.")
        settled = self.runtime.read_view(self.id, view="overview", if_version=before)
        self.assertFalse(settled["unchanged"])
        self.assertEqual(settled["pending_messages"], [])
        self.assertTrue(settled["feature"]["dashboard_summary"]["awaiting_turn"])

    def test_queued_worker_and_background_only_queue_are_working_in_fleet(self):
        visit = self.stage()
        queued = self.store.create_assignment(visit["id"], {
            "title": "Queued scout", "role": "researcher", "prompt": "Inspect synthetic evidence",
            "request_id": "queued-scout"})
        summary = self.store.list_features()[0]["dashboard_summary"]
        self.assertEqual((summary["running_assignment_count"], summary["queued_assignment_count"]), (0, 1))
        self.assertFalse(summary["awaiting_turn"])
        self.assertEqual(first_mate_fleet.entry(self.store.fleet_row(self.id))["hud_status"], "working")
        with self.store._transaction():
            self.store._db.execute("UPDATE fm_assignments SET status='completed' WHERE id=?", (queued["id"],))
        self.store.queue_system_message(self.id, "Continue the authorized stage", "continuation")
        self.assertFalse(self.store.list_features()[0]["dashboard_summary"]["awaiting_turn"])
        self.assertEqual(first_mate_fleet.entry(self.store.fleet_row(self.id))["hud_status"], "working")

    def test_pending_queue_is_bounded_with_full_counts_and_keeps_active_turn_first(self):
        self.stage()
        for index in range(PENDING_MESSAGE_LIMIT + 5):
            self.store.queue_system_message(self.id, "Synthetic update", f"system-{index}")
        human = self.store.append_human_message(self.id, "New direction", "latest-human")
        self.store.claim_message(self.id, "coordinator")
        view = self.runtime.read_view(self.id, view="overview")
        self.assertEqual(len(view["pending_messages"]), PENDING_MESSAGE_LIMIT)
        self.assertTrue(view["pending_messages_truncated"])
        self.assertEqual(view["pending_messages"][0]["id"], human["id"])
        self.assertEqual(view["feature"]["dashboard_summary"]["queued_message_count"], PENDING_MESSAGE_LIMIT + 5)

    def test_authorized_followups_and_carried_assignments_follow_current_revision(self):
        message = self.store.claim_message(self.id, "coordinator")
        visit = self.store.start_visit(self.id, "plan", "Plan", "stage", 1, message["id"],
                                       followup_stages=["implement", "review"])
        self.store.finish_message(message["id"], "coordinator", "Planning.")
        parent = self.running(visit, "parent")
        child = self.store.create_assignment(visit["id"], {
            "title": "Child scout", "role": "researcher", "prompt": "Inspect synthetic evidence",
            "metadata": {"parent_assignment_id": parent["id"]}, "request_id": "child"})
        self.assertEqual(self.store.get_feature_summary(self.id)["dashboard_summary"]["followup_stages"],
                         ["implement", "review"])
        human = self.store.append_human_message(self.id, "Revise only other work", "redirect")
        self.store.claim_message(self.id, "coordinator")
        revised = self.store.revise_feature(self.id, "New synthetic scope", 1, "revise", human["id"],
                                            verified_stopped=True, affected_assignment_ids=[])
        overview = self.runtime.read_view(self.id, view="overview")
        self.assertEqual(overview["feature"]["dashboard_summary"]["followup_stages"], [])
        for assignment in overview["assignments"]:
            self.assertEqual(assignment["visit_id"], visit["id"])
            self.assertIn(revised["current_visit_id"], assignment["visit_ids"])
        self.assertEqual({a["id"] for a in overview["assignments"]}, {parent["id"], child["id"]})
        self.store.finish_message(human["id"], "coordinator", "Scope adjusted.")
        human = self.store.append_human_message(self.id, "Replace entire plan", "replace")
        self.store.claim_message(self.id, "coordinator")
        self.store.revise_feature(self.id, "Replacement scope", 2, "replace-plan", human["id"], verified_stopped=True)
        summary = self.store.get_feature_summary(self.id)["dashboard_summary"]
        self.assertIsNone(summary["current_stage_title"])
        self.assertEqual((summary["followup_stages"], summary["queued_assignment_count"]), ([], 0))

    def test_agent_status_does_not_decode_telemetry_and_retains_explicit_public_history(self):
        self.stage()
        self.bulk_events(["pi.tool_execution_end"] * 50, {"synthetic_payload": "X" * 10000})
        original = FirstMateStore._decode
        decoded = []

        def record(row):
            if row is not None and "type" in row.keys():
                decoded.append(row["type"])
            return original(row)

        with patch.object(FirstMateStore, "_decode", staticmethod(record)):
            for kind in ("coordinator", "worker"):
                job = {"feature_id": self.id, "kind": kind, "claim": {"role": "system", "id": "synthetic"}}
                self.runtime._tool(job, "fm_status", {}, "status-" + kind)
            self.runtime._lead_feature_status(self.store.get_feature(self.id))
        self.assertFalse(any(kind.startswith("pi.") for kind in decoded))
        self.assertEqual(sum(event["type"] == "pi.tool_execution_end"
                             for event in self.store.snapshot(self.id)["events"]), 50)

    def test_router_projection_is_coherent_after_revision_and_prioritizes_live_work(self):
        visit = self.stage()
        stale = self.store.snapshot(self.id, events="journal")
        human = self.store.append_human_message(self.id, "Replace the plan", "replace")
        self.store.claim_message(self.id, "coordinator")
        self.store.revise_feature(self.id, "New scope", 1, "revision", human["id"], verified_stopped=True)
        current = self.store.start_visit(self.id, "review", "Review new scope", "review-stage", 2, human["id"])
        for index in range(55):
            assignment = self.store.create_assignment(current["id"], {
                "title": f"Historical scout {index}", "role": "scout", "prompt": "Synthetic",
                "request_id": f"historical-{index}"})
            with self.store._transaction():
                self.store._db.execute("UPDATE fm_assignments SET status='completed' WHERE id=?", (assignment["id"],))
        queued = self.store.create_assignment(current["id"], {
            "title": "Latest scout", "role": "scout", "prompt": "Synthetic", "request_id": "latest"})
        status = self.runtime._coordinator_projection(stale)
        self.assertEqual(status["current_visit"]["id"], current["id"])
        self.assertNotEqual(status["current_visit"]["id"], visit["id"])
        self.assertEqual(status["assignments"][0]["id"], queued["id"])
        self.assertTrue(status["assignments_truncated"])
        self.assertEqual(status["pending_messages"][0]["id"], human["id"])
        self.assertEqual(status["activity"]["queued_assignment_count"], 1)

    def test_large_retained_verification_does_not_bury_live_activity_or_overflow_reads(self):
        self.stage()
        history = {
            "status": "partially_verified", "label": "Partially verified", "feature_revision": 1,
            "gate_set": [{"key": f"suite-{index}", "label": f"Synthetic suite {index}",
                          "outcome": "failed" if index == 9 else "passed", "run_id": f"run-{index}",
                          "tested_revision": "a" * 40} for index in range(10)],
            "coverage_reasons": ["Synthetic missing coverage: " + "x" * 125 for _ in range(3143)],
            "unmapped_paths": [{"workspace": "synthetic", "path": "pkg/" + "x" * 120}
                               for _ in range(3138)],
            "previously_green_missing": [{"label": f"Synthetic suite {index}"} for index in range(185)],
        }
        current = {"status": "unavailable", "label": "Verification unavailable", "evidence_present": True,
                   "feature_revision": 1, "coverage_reasons": ["Current synthetic inputs cannot be checked"],
                   "failing_suites": [{"label": "Latest failing suite", "run_id": "current-run"}],
                   "historical_evidence": history}
        with self.store._transaction():
            self.store._db.execute("UPDATE fm_features SET verification_json=? WHERE id=?",
                                   (json.dumps(current), self.id))
            for index in range(60):
                self.store._message(self.id, "assistant", f"Synthetic result {index}", status="done",
                                    metadata={"in_reply_to": "synthetic-request", "verification": history,
                                              "internal_context": "private synthetic context"})
        self.store.append_event(self.id, "verification.assessed", "Synthetic retained evidence",
                                {"verification": history})

        def evidence_hash():
            digest = hashlib.sha256()
            for query in ("SELECT verification_json FROM fm_features WHERE id=?",
                          "SELECT metadata_json FROM fm_messages WHERE feature_id=? ORDER BY id",
                          "SELECT payload_json FROM fm_events WHERE feature_id=? ORDER BY sequence"):
                for row in self.store._db.execute(query, (self.id,)):
                    digest.update(row[0].encode())
            return digest.hexdigest()

        before = evidence_hash()
        for projection in (self.runtime.board(self.id), self.runtime.read_view(self.id, view="overview"),
                           self.runtime.read_view(self.id, view="details")):
            self.assertLess(len(json.dumps(projection).encode()), 500_000)
            assessment = projection["feature"]["verification"]
            self.assertEqual(assessment["status"], "unavailable")
            self.assertEqual(assessment["failing_suites"], current["failing_suites"])
            self.assertEqual(assessment["coverage_reasons"], current["coverage_reasons"])
            retained = assessment["historical_evidence"]
            self.assertEqual(retained["counts"]["coverage_reasons"], 3143)
            self.assertEqual(retained["counts"]["unmapped_paths"], 3138)
            self.assertEqual(retained["counts"]["gate_set"], 10)
            self.assertTrue(retained["gate_set_truncated"])
            self.assertEqual(activity_presentation(projection), projection, "presentation must be idempotent")
            for message in projection["messages"]:
                if "verification" not in message["metadata"]:
                    continue
                self.assertLess(len(json.dumps(message["metadata"]).encode()), 8192)
                self.assertTrue(message["metadata_summary"])
                self.assertEqual(message["metadata_detail_reference"]["message_id"], message["id"])
                self.assertEqual(message["metadata"]["verification"]["counts"]["coverage_reasons"], 3143)
        self.assertEqual(evidence_hash(), before)
        raw = self.store.snapshot(self.id)
        self.assertEqual(len(raw["messages"][-1]["metadata"]["verification"]["coverage_reasons"]), 3143)
        last_event = self.store.get_events(self.id, after=raw["events"][-1]["sequence"] - 1, limit=1)["events"][0]
        self.assertEqual(last_event["payload"]["verification"], history)

    def test_record_byte_budgets_hold_for_nested_fields_and_escaped_text(self):
        proof = {"status": "failed", "label": "Failed", "feature_revision": 1,
                 "gate_set": [{key: "😀" * 500 for key in (
                     "key", "label", "package", "suite", "workspace", "outcome", "tested_revision", "run_id")}
                              for _ in range(50)],
                 "failing_suites": [{"label": "Synthetic failure"}] * 200,
                 "assessed_revisions": {"workspace-" + str(index): "\\" * 1000 for index in range(100)}}
        metadata = {key: "\x01" * 256 for key in MESSAGE_PROVENANCE_FIELDS}
        metadata.update({"in_reply_to": "exact-synthetic-id", "verification": proof})
        message = message_presentation({"id": "synthetic", "feature_id": self.id, "metadata": metadata})
        self.assertLessEqual(len(json.dumps(message["metadata"], ensure_ascii=False).encode()), 8192)
        self.assertEqual(message["metadata"]["in_reply_to"], "exact-synthetic-id")
        self.assertEqual(message["metadata"]["verification"]["status"], "failed")
        self.assertEqual(message["metadata"]["verification"]["counts"]["failing_suites"], 200)
        for payload in ({"assignment_id": "exact-assignment", **{
                "key-" + str(index): [{"deep": ["😀" * 1000] * 10}] * 10 for index in range(40)}},
                ["😀" * 10000] * 10):
            event = event_presentation({"feature_id": self.id, "sequence": 42, "payload": payload})
            self.assertLessEqual(len(json.dumps(event["payload"], ensure_ascii=False).encode()), 8192)
            self.assertTrue(event["payload_summary"])
            self.assertEqual(event["payload_detail_reference"], {"feature_id": self.id, "after": 41, "limit": 1})
            if isinstance(payload, dict):
                self.assertEqual(event["payload"]["assignment_id"], "exact-assignment")


if __name__ == "__main__":
    unittest.main()
