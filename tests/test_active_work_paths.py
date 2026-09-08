"""Ticket paths preserve decisions and evidence across branches, retries, and clients."""

from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from herdr_harness.active_work import ActiveWorkError
from herdr_harness.active_work_store import ActiveWorkRepository
from herdr_harness.workflows import parse_workflow_config


def garden_workflow():
    return {
        "workflow": "garden-work", "version": 1, "title": "Garden work",
        "phases": [{"key": "main", "title": "Garden"}],
        "stages": [
            {"key": "intake", "title": "Understand", "phase": "main", "next": ["decision"]},
            {"key": "decision", "title": "Plan decision", "phase": "main", "checkpoint": "human", "next": ["intake", "build"]},
            {"key": "build", "title": "Build", "phase": "main", "next": ["review"]},
            {"key": "review", "title": "Review", "phase": "main", "checkpoint": "human", "next": ["build", "delivered"]},
            {"key": "delivered", "title": "Delivered", "phase": "main", "next": []},
        ],
    }


def path_payload(item, *, note="Tailor this ticket"):
    return {
        "expected_revision": item["revision"], "note": note,
        "phases": copy.deepcopy(item["path"]["phases"]),
        "stages": [
            {"key": stage["stage_key"], "title": stage["title"], "phase": stage["phase_key"],
             "skill": stage["skill_name"], "checkpoint": stage["checkpoint_kind"], "next": list(stage["next"])}
            for stage in item["stages"]
        ],
    }


class ActiveWorkPathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "active-work.sqlite3"
        self.repo = ActiveWorkRepository(self.path)
        self.addCleanup(self.repo.close)
        self.repo.apply_workflow(parse_workflow_config(garden_workflow()))

    def create(self):
        return self.repo.create_item({"title": "Build a garden", "workflow": "garden-work"})

    def move(self, item, key, **fields):
        return self.repo.transition(item["id"], {"expected_revision": item["revision"], "to_stage_key": key, **fields})

    def approved_build(self, item):
        item = self.move(item, "decision")
        item = self.move(item, "decision", checkpoint_state="approved")
        return self.move(item, "build")

    def test_customization_isolated_and_persists_all_stage_associations(self):
        item = self.repo.create_item({"title": "One garden"})
        other = self.repo.create_item({"title": "Another garden"})
        item = self.repo.ingest({
            "source": "garden-agent", "idempotency_key": "snapshot-1", "observed_at": "2026-09-01T10:00:00Z",
            "selector": {"work_item_id": item["id"]}, "current_stage_key": "implement",
            "stages": [{"stage_key": "implement", "summary": "Built the irrigation controller",
                        "content": {"test_result": "Synthetic verification passed"},
                        "agents": [{"external_id": "gardener", "display_name": "Gardener"}],
                        "pi_sessions": [{"external_id": "garden-session", "title": "Garden session"}],
                        "threads": [{"external_id": "garden-review", "title": "Garden review"}]}],
            "activity": [{"external_id": "garden-start", "stage_key": "implement", "kind": "agent_started", "message": "Started work"}],
        })["item"]
        original_pipeline = item["pipeline"]["id"]
        payload = path_payload(item)
        payload["stages"][3]["next"] = ["implement", "proof"]
        edited = self.repo.update_path(item["id"], payload)
        self.assertEqual(edited["pipeline"]["id"], original_pipeline)
        self.assertTrue(edited["path"]["customized"])
        self.assertEqual(edited["pi_sessions"][0]["id"], item["pi_sessions"][0]["id"])
        self.assertEqual(edited["pi_sessions"][0]["stage_links"], item["pi_sessions"][0]["stage_links"])
        implemented = next(stage for stage in edited["stages"] if stage["stage_key"] == "implement")
        self.assertEqual(implemented["content"], {"test_result": "Synthetic verification passed"})
        self.assertEqual(implemented["buzz_threads"][0]["id"], item["stages"][2]["buzz_threads"][0]["id"])
        self.assertEqual(self.repo.item_projection(other["id"]), other)
        self.assertFalse(any(flow["slug"].startswith("route_") for flow in self.repo.list_workflows()))
        self.assertEqual(self.repo._database.execute("PRAGMA foreign_key_check").fetchall(), [])
        reopened = ActiveWorkRepository(self.path)
        try:
            self.assertEqual(reopened.item_projection(item["id"]), edited)
            self.assertEqual(reopened.get_workflow("buzz-feature-work")["stages"][3]["next"], ["proof"])
        finally:
            reopened.close()

    def test_loop_revisit_snapshots_evidence_and_keeps_unvisited_branch_pending(self):
        item = self.approved_build(self.create())
        item = self.repo.patch_stage(item["id"], "build", {"summary": "First attempt", "content": {"result": "One passing check"}})
        item = self.move(item, "review", note="Review irrigation")
        item = self.move(item, "build", note="Add a missing timer", next_action="Test the timer", loop={"owner": "garden-agent", "context": "Timer feedback"})
        visits = item["path"]["visits"]
        first_build = next(visit for visit in visits if visit["stage_key"] == "build")
        self.assertEqual(first_build["summary"], "First attempt")
        self.assertEqual(first_build["content"], {"result": "One passing check"})
        self.assertEqual(first_build["transition_note"], "Review irrigation")
        self.assertEqual(visits[-2]["outcome"], "rework")
        self.assertEqual(visits[-1]["stage_key"], "build")
        self.assertIsNone(visits[-1]["exited_at"])
        by_key = {stage["stage_key"]: stage for stage in item["stages"]}
        self.assertEqual(by_key["build"]["visit_count"], 2)
        self.assertEqual(by_key["review"]["state"], "pending")
        self.assertEqual(by_key["delivered"]["state"], "pending")
        self.assertEqual(item["loop"]["next_action"], "Test the timer")
        self.assertEqual(item["loop"]["owner"], "garden-agent")
        with self.assertRaises(ActiveWorkError):
            self.repo.update_path(item["id"], {**path_payload(item), "stages": [s for s in path_payload(item)["stages"] if s["key"] != "review"]})

    def test_expected_revision_protects_path_and_handoff(self):
        item = self.create()
        payload = path_payload(item)
        payload["stages"][2]["title"] = "Build timer"
        changed = self.repo.update_path(item["id"], payload)
        for mutation in (
            lambda: self.repo.update_path(item["id"], payload),
            lambda: self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "loop": {"owner": "stale-agent"}}),
            lambda: self.move(item, "decision"),
        ):
            with self.assertRaises(ActiveWorkError) as conflict:
                mutation()
            self.assertEqual(conflict.exception.code, "active_work_revision_conflict")
        self.assertEqual(self.repo.item_projection(item["id"]), changed)

    def test_observers_enrich_custom_paths_without_regressing_or_approving_them(self):
        item = self.approved_build(self.create())
        item = self.move(item, "review", next_action="Review the timer", loop={"owner": "person", "context": "Check the wiring"})
        result = self.repo.ingest({
            "source": "garden-sync", "idempotency_key": "snapshot-1", "observed_at": "2026-09-01T10:00:00Z",
            "selector": {"work_item_id": item["id"]}, "current_stage_key": "delivered",
            "item": {"lifecycle": "done", "next_action": "Old upstream advice"},
            "stages": [{"stage_key": "review", "state": "complete", "attention": "none", "checkpoint_state": "approved", "content": {"evidence": "New screenshot available"}}],
        })["item"]
        review = next(stage for stage in result["stages"] if stage["stage_key"] == "review")
        self.assertEqual(result["current_stage_key"], "review")
        self.assertEqual(result["lifecycle"], "active")
        self.assertEqual(result["next_action"], "Review the timer")
        self.assertEqual(result["loop"], item["loop"])
        self.assertEqual(review["state"], "active")
        self.assertEqual(review["checkpoint_state"], "pending")
        self.assertEqual(review["content"]["evidence"], "New screenshot available")

    def test_checkpoint_approval_and_returning_are_independent_of_display_order(self):
        item = self.create()
        payload = path_payload(item)
        payload["stages"][1], payload["stages"][2] = payload["stages"][2], payload["stages"][1]
        item = self.repo.update_path(item["id"], payload)
        item = self.move(item, "decision")
        with self.assertRaises(ActiveWorkError) as gate:
            self.move(item, "build")
        self.assertEqual(gate.exception.code, "active_work_checkpoint_required")
        with self.assertRaises(ActiveWorkError):
            self.repo.transition(item["id"], {"expected_revision": item["revision"], "to_stage_key": "decision", "checkpoint_state": "approved"}, actor="garden-agent")
        item = self.move(item, "decision", checkpoint_state="approved")
        item = self.move(item, "build")
        item = self.move(item, "review")
        payload = path_payload(item)
        payload["stages"][1], payload["stages"][3] = payload["stages"][3], payload["stages"][1]
        item = self.repo.update_path(item["id"], payload)
        with self.assertRaises(ActiveWorkError) as note:
            self.move(item, "build")
        self.assertEqual(note.exception.code, "active_work_transition_note_required")
        item = self.move(item, "build", note="Revise the timer")
        self.assertEqual(item["path"]["visits"][-2]["outcome"], "rework")

    def test_missing_path_reason_and_invalid_graphs_roll_back(self):
        item = self.create()
        for note in (None, "", " "):
            with self.assertRaises(ActiveWorkError):
                self.repo.update_path(item["id"], path_payload(item, note=note))
        payload = path_payload(item)
        payload["stages"][-1]["next"] = ["intake"]
        with self.assertRaises(ActiveWorkError):
            self.repo.update_path(item["id"], payload)
        self.assertEqual(self.repo.item_projection(item["id"]), item)

    def test_handoff_can_finish_without_completing_ticket_and_waits_need_reasons(self):
        item = self.create()
        self.assertEqual(item["loop"]["status"], "working")
        with self.assertRaises(ActiveWorkError):
            self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "loop": {"status": "waiting"}})
        item = self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "next_action": "Human reviews the design", "loop": {"owner": "gardener", "status": "done", "context": "Design notes saved"}})
        self.assertEqual(item["loop"]["status"], "done")
        self.assertEqual(item["lifecycle"], "active")
        item = self.move(item, "decision")
        self.assertEqual(item["loop"]["status"], "waiting")

    def test_new_jira_tickets_use_dynamic_template_and_setup_is_idempotent(self):
        ticket = {"key": "GARDEN-123", "title": "Water the garden", "url": "https://jira.example.test/browse/GARDEN-123"}
        first = self.repo.setup_jira(ticket)
        again = self.repo.setup_jira(ticket)
        self.assertTrue(first["created"])
        self.assertFalse(again["created"])
        self.assertEqual(first["item"]["pipeline"]["slug"], "ticket-journey")
        self.assertEqual(first["item"]["path"]["mode"], "dynamic")
        self.assertEqual(first["item"]["id"], again["item"]["id"])

    def reopen_as_v3_database(self):
        self.repo._database.executescript(
            "DROP TABLE work_stage_visits; DROP TABLE work_item_paths; "
            "DELETE FROM active_work_schema_migrations WHERE version = 4; PRAGMA user_version=3;"
        )
        self.repo.close()
        self.repo = ActiveWorkRepository(self.path)
        self.addCleanup(self.repo.close)

    def test_legacy_proof_can_return_to_historical_implementation_after_migration(self):
        item = self.repo.create_item({"title": "Existing garden", "current_stage_key": "proof"})
        self.repo.patch_stage(item["id"], "implement", {"summary": "Original timer", "content": {"result": "Timer verified"}})
        self.reopen_as_v3_database()
        item = self.repo.item_projection(item["id"])
        historical = next(visit for visit in item["path"]["visits"] if visit["stage_key"] == "implement")
        self.assertEqual(historical["actor"], "import")
        self.assertEqual(historical["content"], {"result": "Timer verified"})
        payload = path_payload(item)
        payload["stages"][4]["next"] = ["implement", "code-review-pre-pr"]
        item = self.repo.update_path(item["id"], payload)
        self.assertIn("implement", item["path"]["return_targets"])
        item = self.move(item, "implement", note="Address the QA finding")
        self.assertEqual(item["current_stage_key"], "implement")
        self.assertEqual(item["path"]["visits"][-2]["outcome"], "rework")

    def test_migrated_terminal_evidence_survives_reopening(self):
        item = self.repo.create_item({"title": "Delivered garden", "lifecycle": "done"})
        self.repo.patch_stage(item["id"], "pr-triage", {"summary": "Installed controller", "content": {"result": "Garden delivered"}})
        self.reopen_as_v3_database()
        item = self.repo.item_projection(item["id"])
        self.assertEqual(item["path"]["visits"][-1]["summary"], "Installed controller")
        item = self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "lifecycle": "active"})
        self.assertEqual(item["loop"]["status"], "working")
        self.assertEqual(sum(visit["exited_at"] is None for visit in item["path"]["visits"]), 1)
        self.assertEqual(item["path"]["visits"][-2]["content"], {"result": "Garden delivered"})
        self.assertEqual(item["path"]["visits"][-1]["stage_key"], "pr-triage")

    def test_reopening_completed_human_terminal_requires_fresh_approval(self):
        item = self.create()
        payload = path_payload(item)
        payload["stages"][-1]["checkpoint"] = "human"
        item = self.repo.update_path(item["id"], payload)
        item = self.approved_build(item)
        item = self.move(item, "review")
        item = self.move(item, "review", checkpoint_state="approved")
        item = self.move(item, "delivered")
        item = self.move(item, "delivered", checkpoint_state="approved")
        item = self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "lifecycle": "done"})
        item = self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "lifecycle": "active"})
        self.assertEqual(item["loop"]["status"], "waiting")
        self.assertEqual(item["stages"][-1]["checkpoint_state"], "pending")
        with self.assertRaises(ActiveWorkError) as gate:
            self.repo.patch_item(item["id"], {"expected_revision": item["revision"], "lifecycle": "done"})
        self.assertEqual(gate.exception.code, "active_work_checkpoint_required")

    def test_sync_skips_removed_template_steps_and_still_enriches_remaining_steps(self):
        item = self.create()
        payload = path_payload(item)
        payload["stages"] = [stage for stage in payload["stages"] if stage["key"] != "build"]
        payload["stages"][1]["next"] = ["intake", "review"]
        payload["stages"][2]["next"] = ["decision", "delivered"]
        item = self.repo.update_path(item["id"], payload)
        observation = {
            "source": "garden-sync", "idempotency_key": "retired-step-1", "observed_at": "2026-09-01T10:00:00Z",
            "selector": {"work_item_id": item["id"]}, "current_stage_key": "build",
            "stages": [
                {"stage_key": "build", "state": "active", "summary": "Obsolete route progress"},
                {"stage_key": "review", "content": {"evidence": "Retained verification"},
                 "pi_sessions": [{"external_id": "garden-session", "title": "Review session"}]},
            ],
            "activity": [
                {"external_id": "old-build-event", "stage_key": "build", "message": "Obsolete route event"},
                {"external_id": "retained-review-event", "stage_key": "review", "message": "New review evidence"},
            ],
        }
        result = self.repo.ingest(observation)
        updated = result["item"]
        self.assertTrue(result["applied"])
        self.assertEqual(updated["current_stage_key"], "intake")
        self.assertNotIn("build", {stage["stage_key"] for stage in updated["stages"]})
        review = next(stage for stage in updated["stages"] if stage["stage_key"] == "review")
        self.assertEqual(review["content"]["evidence"], "Retained verification")
        self.assertEqual(len(review["pi_sessions"]), 1)
        self.assertIn("retained-review-event", {event["source_event_id"] for event in updated["activity"]})
        self.assertNotIn("old-build-event", {event["source_event_id"] for event in updated["activity"]})
        self.assertTrue(self.repo.ingest(observation)["replayed"])
        self.assertEqual(self.repo.item_projection(item["id"]), updated)
        for field in ("current_stage_key", "stages", "activity"):
            invalid = copy.deepcopy(observation)
            invalid["idempotency_key"] = f"unknown-{field}"
            if field == "current_stage_key":
                invalid[field] = "unknown-step"
            elif field == "stages":
                invalid[field][0]["stage_key"] = "unknown-step"
            else:
                invalid[field][0]["stage_key"] = "unknown-step"
            with self.assertRaises(ActiveWorkError):
                self.repo.ingest(invalid)
            self.assertEqual(self.repo.item_projection(item["id"]), updated)


if __name__ == "__main__":
    unittest.main()
