"""Synthetic First Mate continuity and authorization regressions."""
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.first_mate_store import FirstMateError, FirstMateStore, SCHEMA
from herdr_harness.first_mate_runtime import _read_json
from tests import test_first_mate_reliability as reliability_fixtures


class StageGrantTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "ledger.db"
        self.store = FirstMateStore(self.path)
        self.addCleanup(lambda: self.store.close())

    def test_one_human_request_authorizes_only_its_recorded_stage_sequence(self):
        feature = self.store.create_feature({"title": "Synthetic sequence", "goal": "Plan then implement then review a synthetic feature", "cwd": "/tmp/synthetic-sequence", "request_id": "create"})
        human = self.store.claim_message(feature["id"], "coordinator")
        visit = self.store.start_visit(feature["id"], "plan", "Plan", "stage-0", 1, human["id"], followup_stages=["implement", "review"])
        self.store.finish_message(human["id"], "coordinator")
        for index, stage in enumerate(("plan", "implement", "review")):
            if index:
                visit = self.store.start_visit(feature["id"], stage, stage.title(), f"stage-{index}", 1, human["id"])
                self.assertEqual(visit["followup_stages"], ["review"] if index == 1 else [])
            task = self.store.create_assignment(visit["id"], {"title": "Synthetic task", "role": "planner", "prompt": "Inspect synthetic change", "request_id": f"task-{index}"})
            claim = self.store.claim_assignment(task["id"], f"worker-{index}")
            bound = self.store.bind_session(claim["id"], claim["generation"], f"worker-{index}", f"native-{index}", f"/tmp/synthetic-sequence/{index}.jsonl", f"run-{index}")
            self.store.record_outcome(bound["id"], bound["generation"], bound["native_session_id"], 1, "success", "Evidence retained", f"outcome-{index}")
            self.store.complete_visit(visit["id"], "Evidence retained", "Continue", f"complete-{index}")
            self.assertEqual(self.store.get_feature(feature["id"])["status"], "coordinating" if index < 2 else "awaiting_direction")
            with self.assertRaises(FirstMateError):
                self.store.start_visit(feature["id"], "deploy", "Deploy", f"unapproved-{index}", 1, human["id"])
        self.assertEqual(len(self.store.snapshot(feature["id"])["visits"]), 3)

    def test_new_human_direction_preempts_recorded_followup(self):
        feature = self.store.create_feature({"title": "Synthetic scope", "goal": "Plan then implement", "cwd": "/tmp/synthetic-scope", "request_id": "create"})
        human = self.store.claim_message(feature["id"], "coordinator")
        visit = self.store.start_visit(feature["id"], "plan", "Plan", "plan", 1, human["id"], followup_stages=["implement"])
        self.store.finish_message(human["id"], "coordinator")
        task = self.store.create_assignment(visit["id"], {"title": "Plan", "role": "planner", "prompt": "Plan", "request_id": "task"})
        claim = self.store.claim_assignment(task["id"], "worker")
        bound = self.store.bind_session(claim["id"], claim["generation"], "worker", "native", "/tmp/synthetic-scope/session", "run")
        self.store.record_outcome(bound["id"], bound["generation"], bound["native_session_id"], 1, "success", "Plan done", "outcome")
        self.store.complete_visit(visit["id"], "Plan done", "Implement", "done")
        self.store.append_human_message(feature["id"], "Stop after planning", "stop")
        with self.assertRaises(FirstMateError) as error:
            self.store.start_visit(feature["id"], "implement", "Implement", "preempted", 1, human["id"])
        self.assertEqual(error.exception.code, "human_direction_required")

    def test_existing_visits_and_memberships_survive_schema_migration(self):
        self.store.close()
        self.path.unlink()
        legacy = SCHEMA.replace("authorization_message_id TEXT NOT NULL, followup_stages_json TEXT NOT NULL DEFAULT '[]',", "authorization_message_id TEXT NOT NULL UNIQUE,")
        db = sqlite3.connect(self.path)
        db.executescript(legacy)
        db.execute("INSERT INTO fm_features(id,title,goal,cwd,status,revision,created_at,updated_at) VALUES('old','Old','Plan','/tmp/synthetic','running',1,'2026','2026')")
        db.execute("INSERT INTO fm_messages(id,feature_id,role,text,status,created_at,updated_at) VALUES('message','old','user','Plan','done','2026','2026')")
        db.execute("INSERT INTO fm_visits(id,feature_id,stage_key,title,status,revision,authorization_message_id,created_at,updated_at) VALUES('visit','old','plan','Plan','running',1,'message','2026','2026')")
        db.execute("INSERT INTO fm_assignments(id,feature_id,visit_id,title,role,prompt,status,input_revision,created_at,updated_at) VALUES('assignment','old','visit','Task','planner','Plan','queued',1,'2026','2026')")
        db.commit()
        db.close()
        self.store = FirstMateStore(self.path)
        self.assertEqual(self.store.snapshot("old")["visits"][0]["followup_stages"], [])
        self.assertEqual(self.store.get_assignment("assignment")["visit_ids"], ["visit"])
        self.assertEqual(self.store._db.execute("PRAGMA foreign_key_check").fetchall(), [])


class RecoveryContinuationTests(unittest.TestCase):
    setUp = reliability_fixtures.FirstMateReliabilityTests.setUp
    tearDown = reliability_fixtures.FirstMateReliabilityTests.tearDown
    feature = reliability_fixtures.FirstMateReliabilityTests.feature
    coordinator = reliability_fixtures.FirstMateReliabilityTests.coordinator
    worker = reliability_fixtures.FirstMateReliabilityTests.worker
    isolated = reliability_fixtures.FirstMateReliabilityTests.isolated
    ledger = reliability_fixtures.FirstMateReliabilityTests.ledger

    def test_system_turn_consumes_only_recorded_stage_and_router_can_see_grant(self):
        feature = self.store.create_feature({"title": "Synthetic routing", "goal": "Plan then implement a synthetic feature", "cwd": str(self.cwd), "request_id": "routing"})
        human = self.store.claim_message(feature["id"], "router")
        coordinator = {"feature_id": feature["id"], "kind": "coordinator", "claim": human}
        plan = self.runtime._tool(coordinator, "fm_begin_stage", {"stage_key": "plan", "title": "Plan", "followup_stages": ["implement"]}, "plan")
        self.store.finish_message(human["id"], "router")
        task = self.store.create_assignment(plan["id"], {"title": "Plan", "role": "planner", "prompt": "Plan", "request_id": "task"})
        claim = self.store.claim_assignment(task["id"], "worker")
        bound = self.store.bind_session(claim["id"], claim["generation"], "worker", "native-route", str(self.root / "route.jsonl"), "run")
        self.store.record_outcome(bound["id"], bound["generation"], bound["native_session_id"], 1, "success", "Plan done", "outcome")
        self.store.complete_visit(plan["id"], "Plan done", "Implement", "complete")
        system = {"feature_id": feature["id"], "kind": "coordinator", "claim": {"role": "system", "id": "system-turn"}}
        visible = self.runtime._coordinator_projection(self.store.snapshot(feature["id"]), system["claim"])
        self.assertEqual(visible["current_visit"]["followup_stages"], ["implement"])
        with self.assertRaises(FirstMateError):
            self.runtime._tool(system, "fm_begin_stage", {"stage_key": "deploy", "title": "Deploy"}, "unauthorized")
        with self.assertRaises(FirstMateError):
            self.runtime._tool(system, "fm_begin_stage", {"stage_key": "implement", "title": "Implement", "followup_stages": ["deploy"]}, "escalation")
        implementation = self.runtime._tool(system, "fm_begin_stage", {"stage_key": "implement", "title": "Implement"}, "implement")
        self.assertEqual(implementation["authorization_message_id"], human["id"])

    def test_system_recovery_cannot_use_the_human_effect_override(self):
        feature, assignment, job = self.worker()
        self.runtime._unknown(job)
        system = {"feature_id": feature["id"], "kind": "coordinator", "claim": {"role": "system", "id": "system-update"}}
        params = {"assignment_id": assignment["id"], "reason": "Inspect stopped worker"}
        with patch.object(self.runtime.reliability, "recover", return_value=True) as checked, \
             patch.object(self.store, "recover_assignment", side_effect=AssertionError("unsafe override")):
            self.runtime._tool(system, "fm_recover", params, "system-recover")
        checked.assert_called_once()
        self.store.append_human_message(feature["id"], "Stop and reconsider", "preempt")
        with self.assertRaises(FirstMateError):
            self.runtime._tool(system, "fm_recover", params, "preempted")

    def test_inconclusive_advisor_fences_inspection_without_new_human_message(self):
        feature, assignment, job = self.isolated()
        self.ledger(job, [{"type": "start", "id": "local", "scope": "workspace", "tool": "write"}])
        with patch.object(self.runtime, "_launch"):
            self.assertFalse(self.runtime.reliability.recover(job, {"error": "stopped"}))
            advisor = _read_json(self.runtime.jobs_root / job["recovery_job_id"] / "job.json")
            self.runtime._tool(advisor, "fm_recovery_brief", {"summary": "Read the predecessor; next action unknown", "safe_to_continue": False}, "brief")
            stopped = _read_json(self.runtime._job_dir(job) / "job.json")
            self.assertTrue(self.runtime.reliability.recover(stopped, {}))
        self.assertEqual(self.store.get_assignment(assignment["id"])["status"], "queued")
        claim = self.store.claim_assignment(assignment["id"], "inspector")
        successor = self.runtime._new_job(feature, kind="worker", claim=claim, prompt="Inspect")
        self.assertTrue(successor["requires_recovery_inspection"])
        self.runtime._bind(successor, "inspector-native", successor["session_file"])
        with self.assertRaises(FirstMateError):
            self.runtime._tool(successor, "fm_acknowledge_recovery", {"summary": "Premature"}, "premature")
        Path(job["session_file"]).write_text("\n".join((json.dumps({"type": "session", "id": job["native_session_id"]}), json.dumps({"type": "message", "message": {"role": "assistant", "content": "Synthetic evidence"}}))) + "\n")
        self.runtime._tool(successor, "fm_read_session", {"native_session_id": job["native_session_id"]}, "inspect")
        self.assertTrue(self.runtime._tool(successor, "fm_acknowledge_recovery", {"summary": "Predecessor inspected; local work retained and no external effect pending"}, "ack")["acknowledged"])

    def test_incomplete_external_effect_still_blocks_without_a_successor(self):
        feature, assignment, job = self.isolated()
        self.ledger(job, [{"type": "start", "id": "external", "scope": "external", "tool": "bash"}])
        with patch.object(self.runtime, "_launch"):
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        self.assertEqual(self.store.get_feature(feature["id"])["status"], "blocked")
        self.assertEqual(self.store.get_assignment(assignment["id"])["recovery_count"], 0)

    def test_fenced_successor_can_request_a_real_human_decision(self):
        feature, assignment, job = self.worker()
        job["requires_recovery_ack"] = True
        job["requires_recovery_inspection"] = True
        result = self.runtime._tool(job, "fm_request_human", {"reason": "Synthetic decision remains unresolved"}, "gate")
        self.assertEqual(result["status"], "paused")
        self.assertEqual(self.store.get_feature(feature["id"])["status"], "awaiting_direction")
