"""The Agent view board is bounded, versioned, and built from SQLite alone."""
from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import (
    JOURNAL_EVENT_SQL, FirstMateError, FirstMateStore, _is_journal_event_type, _now,
)
from herdr_harness.server import make_handler

ASSIGNMENT_FIELDS = {"id", "feature_id", "visit_id", "visit_ids", "title", "role", "status", "verdict",
                     "native_session_id", "attempt", "generation", "input_revision", "created_at",
                     "updated_at", "summary"}
BOARD_FIELDS = {"version", "unchanged", "feature", "visits", "assignments", "messages", "messages_total",
                "journal", "journal_total", "sessions", "sessions_truncated", "event_cursor"}
PRIVATE_PROMPT = "SYNTHETIC-PRIVATE-PROMPT"
PRIVATE_METADATA = "SYNTHETIC-PRIVATE-METADATA"


class BoardFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = FirstMateStore(Path(self.temp.name) / "first-mate.sqlite3")
        self.addCleanup(self.store.close)
        self.feature = self.store.create_feature({"title": "Garden irrigation", "goal": "Design garden irrigation.",
                                                  "cwd": "/tmp/synthetic-garden", "request_id": "create"})
        self.id = self.feature["id"]

    def stage(self):
        message = self.store.claim_message(self.id, "coordinator")
        self.store.bind_coordinator_session(self.id, "coordinator", "synthetic-coordinator", "/tmp/synthetic-pi/coordinator.jsonl")
        visit = self.store.start_visit(self.id, "plan", "Plan irrigation", "stage", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Planning the irrigation layout.")
        return visit

    def running(self, visit, suffix="1"):
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Survey beds " + suffix, "role": "planner", "prompt": PRIVATE_PROMPT,
            "metadata": {"note": PRIVATE_METADATA}, "request_id": "assign-" + suffix})
        claimed = self.store.claim_assignment(assignment["id"], "worker-" + suffix)
        return self.store.bind_session(assignment["id"], claimed["generation"], "worker-" + suffix,
                                       "synthetic-worker-" + suffix, f"/tmp/synthetic-pi/worker-{suffix}.jsonl", "run-" + suffix)

    def bulk_events(self, types, payload=None):
        # One transaction keeps large synthetic ledgers fast to build.
        body = json.dumps(payload or {})
        with self.store._transaction():
            self.store._db.executemany(
                "INSERT INTO fm_events(id,feature_id,type,summary,created_at,payload_json) VALUES(?,?,?,?,?,?)",
                ((f"fme_synthetic_{index}_{time.monotonic_ns()}", self.id, kind, "Synthetic " + kind, _now(), body)
                 for index, kind in enumerate(types)))

    def version(self):
        return self.store.board(self.id)["version"]


class FirstMateBoardStoreTests(BoardFixture, unittest.TestCase):
    def test_board_shape_bounds_and_ordering(self):
        self.stage()
        for index in range(4):
            self.store.append_human_message(self.id, f"Direction {index}", f"direction-{index}")
        self.store.queue_system_message(self.id, "Synthetic background update", "system-1")
        board = self.store.board(self.id, messages=2, journal=3)
        self.assertEqual(set(board), BOARD_FIELDS)
        self.assertFalse(board["unchanged"])
        self.assertTrue(board["version"].startswith("b1-"))
        self.assertEqual(board["feature"], self.store.list_features()[0])
        self.assertIn("dashboard_summary", board["feature"])
        snapshot = self.store.snapshot(self.id)
        self.assertEqual(board["visits"], snapshot["visits"])
        chat = [message for message in snapshot["messages"] if message["role"] in {"user", "assistant", "human"}]
        self.assertEqual(board["messages"], chat[-2:])
        self.assertEqual([m["text"] for m in board["messages"]], ["Direction 2", "Direction 3"])
        self.assertEqual(board["messages_total"], len(chat))
        self.assertNotIn("system", {message["role"] for message in board["messages"]})
        self.assertEqual(board["journal"], snapshot["events"][-3:])
        self.assertEqual(board["journal_total"], len(snapshot["events"]))
        self.assertEqual(board["event_cursor"], snapshot["events"][-1]["sequence"])
        empty = self.store.board(self.id, journal=0)
        self.assertEqual((empty["journal"], empty["journal_total"]), ([], len(snapshot["events"])))
        self.assertEqual(len(self.store.board(self.id)["messages"]), len(chat))

    def test_assignments_are_trimmed_and_visit_ids_match_the_full_snapshot(self):
        visit = self.stage()
        kept = self.running(visit, "keep")
        changed = self.running(visit, "change")
        direction = self.store.append_human_message(self.id, "Change the drip layout only", "redirect")
        self.store.claim_message(self.id, "coordinator")
        self.store.revise_feature(self.id, "Revised drip layout", 1, "revise", direction["id"], verified_stopped=True,
                                  affected_assignment_ids=[changed["id"]])
        self.store.record_outcome(kept["id"], kept["generation"], kept["native_session_id"], kept["input_revision"],
                                  "success", "S" * 1000, "outcome")
        board = self.store.board(self.id)
        for assignment in board["assignments"]:
            self.assertEqual(set(assignment), ASSIGNMENT_FIELDS)
        full = {row["id"]: row["visit_ids"] for row in self.store.snapshot(self.id)["assignments"]}
        self.assertEqual({row["id"]: row["visit_ids"] for row in board["assignments"]}, full)
        self.assertEqual(len(full[kept["id"]]), 2)
        self.assertEqual([row["id"] for row in board["assignments"]], [kept["id"], changed["id"]])
        self.assertEqual(board["assignments"][0]["summary"], "S" * 600)
        self.assertNotIn(PRIVATE_PROMPT, json.dumps(board))
        self.assertNotIn(PRIVATE_METADATA, json.dumps(board))
        # The feature object matches the list endpoint; rows never add paths or owners.
        rows = json.dumps([board["assignments"], board["sessions"]])
        for private in ("/tmp/synthetic-pi/", "\"worker-keep\"", "fmd_", "run-keep"):
            self.assertNotIn(private, rows)

    def test_sessions_include_coordinators_and_only_the_newest_per_assignment(self):
        assignment = self.running(self.stage())
        self.store.recover_assignment(assignment["id"], 1, "Synthetic interruption", "recover", verified_stopped=True)
        claimed = self.store.claim_assignment(assignment["id"], "worker-2")
        self.store.bind_session(assignment["id"], claimed["generation"], "worker-2", "synthetic-worker-2",
                                "/tmp/synthetic-pi/worker-2.jsonl", "run-2")
        board = self.store.board(self.id)
        self.assertEqual({session["native_session_id"] for session in board["sessions"]},
                         {"synthetic-coordinator", "synthetic-worker-2"})
        full = {session["native_session_id"]: session for session in self.store.snapshot(self.id)["sessions"]}
        self.assertEqual(len(full), 3)
        for session in board["sessions"]:
            self.assertEqual(session, full[session["native_session_id"]])
            self.assertNotIn("session_file", session)
        self.assertFalse(board["sessions_truncated"])
        with self.store._transaction():
            self.store._db.executemany("INSERT INTO fm_sessions VALUES(?,?,?,?,?,?,?,?,?)", (
                (f"synthetic-retired-{index:03}", self.id, None, 0, "coordinator", "retained",
                 f"/tmp/synthetic-pi/retired-{index:03}.jsonl", f"2030-01-01T00:00:{index % 60:02}.{index:06}Z", _now())
                for index in range(205)))
        capped = self.store.board(self.id)
        self.assertEqual(len(capped["sessions"]), 200)
        self.assertTrue(capped["sessions_truncated"])
        order = [(session["created_at"], session["native_session_id"]) for session in capped["sessions"]]
        self.assertEqual(order, sorted(order, key=lambda item: item[0], reverse=True))

    def test_journal_excludes_only_pi_telemetry(self):
        types = ["pi.message_end", "reliability.sweep", "pi.tool_execution_start", "recovery.checkpoint",
                 "handoff.checkpointed", "pi.context_usage", "visit.started", "pi", "pix.synthetic", "PI.upper"]
        for kind in types:
            self.store.append_event(self.id, kind, "Synthetic " + kind, {"synthetic": True})
        board = self.store.board(self.id, journal=200)
        journal_types = [event["type"] for event in board["journal"]]
        self.assertEqual(journal_types, ["feature.created"] + [kind for kind in types if not kind.startswith("pi.")])
        self.assertEqual(board["journal_total"], len(journal_types))
        sequences = [event["sequence"] for event in board["journal"]]
        self.assertEqual(sequences, sorted(sequences))
        rows = self.store._db.execute(f"SELECT type,{JOURNAL_EVENT_SQL} FROM fm_events WHERE feature_id=?", (self.id,)).fetchall()
        for kind, journal in rows:
            self.assertEqual(bool(journal), _is_journal_event_type(kind), kind)

    def test_version_ignores_telemetry_and_changes_for_every_board_mutation(self):
        visit = self.stage()
        assignment = self.running(visit)
        before, updated_at = self.version(), self.store.get_feature(self.id)["updated_at"]
        self.store.append_event(self.id, "pi.message_end", "Agent response recorded", {"synthetic": True})
        self.store.append_event(self.id, "pi.context_usage", "Context usage measured", {"synthetic": True})
        # Telemetry still moves the feature timestamp the card list sorts by.
        self.assertNotEqual(self.store.get_feature(self.id)["updated_at"], updated_at)
        self.assertEqual(self.version(), before)

        def changes(label, mutate):
            previous = self.version()
            mutate()
            self.assertNotEqual(self.version(), previous, label)

        def direct(sql, *args):
            with self.store._transaction():
                self.store._db.execute(sql, args)

        # Each table marker is checked without the journal event that store
        # mutations normally add, so the token cannot rely on events alone.
        message_id = self.store.snapshot(self.id)["messages"][0]["id"]
        changes("message status", lambda: direct("UPDATE fm_messages SET status='queued',updated_at=? WHERE id=?", _now(), message_id))
        changes("assignment status", lambda: direct("UPDATE fm_assignments SET status='paused',updated_at=? WHERE id=?", _now(), assignment["id"]))
        changes("visit", lambda: direct("UPDATE fm_visits SET recommendation='Synthetic',updated_at=? WHERE id=?", _now(), visit["id"]))
        changes("session", lambda: direct("UPDATE fm_sessions SET status='quiesced',updated_at=? WHERE native_session_id=?", _now(), "synthetic-worker-1"))
        changes("feature status", lambda: direct("UPDATE fm_features SET status='blocked' WHERE id=?", self.id))
        changes("feature revision", lambda: direct("UPDATE fm_features SET revision=revision+1 WHERE id=?", self.id))
        changes("coordinator owner", lambda: direct("UPDATE fm_features SET coordinator_owner='synthetic' WHERE id=?", self.id))
        changes("model settings", lambda: direct("UPDATE fm_features SET model_settings_revision=model_settings_revision+1 WHERE id=?", self.id))
        changes("archive", lambda: direct("UPDATE fm_features SET archived_at=? WHERE id=?", _now(), self.id))
        changes("journal event", lambda: direct("INSERT INTO fm_events(id,feature_id,type,summary,created_at,payload_json) VALUES('fme_synthetic',?,'reliability.sweep','Synthetic',?,'{}')", self.id, _now()))
        changes("new message", lambda: direct("INSERT INTO fm_messages(id,feature_id,role,text,status,created_at,updated_at) VALUES('fmm_synthetic',?,'user','Synthetic','done',?,?)", self.id, "2000-01-01T00:00:00Z", "2000-01-01T00:00:00Z"))
        unchanged = self.version()
        direct("UPDATE fm_features SET updated_at=? WHERE id=?", _now(), self.id)
        self.assertEqual(self.version(), unchanged)
        self.assertFalse(self.store.board(self.id, if_version=before)["unchanged"])

    def test_version_follows_public_workflow_mutations(self):
        def changes(label, mutate):
            previous = self.version()
            result = mutate()
            self.assertNotEqual(self.version(), previous, label)
            return result

        message = changes("claim message", lambda: self.store.claim_message(self.id, "coordinator"))
        visit = changes("visit", lambda: self.store.start_visit(self.id, "plan", "Plan", "stage", 1, message["id"]))
        changes("finish message", lambda: self.store.finish_message(message["id"], "coordinator", "Planning."))
        assignment = changes("assignment", lambda: self.store.create_assignment(visit["id"], {"title": "Survey", "role": "planner", "prompt": PRIVATE_PROMPT, "request_id": "assign"}))
        claimed = changes("claim", lambda: self.store.claim_assignment(assignment["id"], "worker"))
        bound = changes("session", lambda: self.store.bind_session(assignment["id"], claimed["generation"], "worker", "synthetic-worker", "/tmp/synthetic-pi/worker.jsonl", "run"))
        changes("outcome", lambda: self.store.record_outcome(assignment["id"], bound["generation"], "synthetic-worker", 1, "success", "Survey complete.", "outcome"))
        changes("complete visit", lambda: self.store.complete_visit(visit["id"], "Planned.", "Build next.", "complete"))
        changes("model settings", lambda: self.store.set_model_settings(self.id, {"model": "synthetic/model", "thinking": "high", "expected_settings_revision": 0, "request_id": "settings"}))
        changes("pause", lambda: self.store.feature_action(self.id, "pause", "pause"))
        changes("archive", lambda: self.store.set_archived(self.id, True, {"request_id": "archive"}))
        changes("unarchive", lambda: self.store.set_archived(self.id, False, {"request_id": "unarchive"}))

    def test_activity_at_follows_journal_and_messages_but_not_telemetry(self):
        self.stage()

        def activity():
            listed = self.store.list_features()[0]["dashboard_summary"]["activity_at"]
            self.assertEqual(self.store.board(self.id)["feature"]["dashboard_summary"]["activity_at"], listed)
            return listed

        before = activity()
        self.store.append_event(self.id, "pi.message_end", "Agent response recorded", {"synthetic": True})
        self.assertEqual(activity(), before)
        self.assertGreater(self.store.get_feature(self.id)["updated_at"], before)
        journal = self.store.append_event(self.id, "reliability.sweep", "Synthetic sweep", {"synthetic": True})
        self.assertEqual(activity(), journal["created_at"])
        message = self.store.append_human_message(self.id, "Check the drip timer", "direction")
        self.assertGreaterEqual(activity(), message["created_at"])
        self.store.append_event(self.id, "pi.context_usage", "Context usage measured", {"synthetic": True})
        self.assertGreaterEqual(activity(), message["created_at"])
        with self.store._transaction():
            self.store._db.execute("DELETE FROM fm_events WHERE feature_id=?", (self.id,))
            self.store._db.execute("DELETE FROM fm_messages WHERE feature_id=?", (self.id,))
        self.assertEqual(activity(), self.feature["created_at"])

    def test_awaiting_turn_marks_a_parked_coordinator_without_changing_attention(self):
        self.assertFalse(self.store.list_features()[0]["dashboard_summary"]["awaiting_turn"])
        visit = self.stage()

        def summary():
            listed = self.store.list_features()[0]["dashboard_summary"]
            self.assertEqual(self.store.board(self.id)["feature"]["dashboard_summary"], listed)
            return listed

        def direct(sql, *args):
            with self.store._transaction():
                self.store._db.execute(sql, args)

        parked = summary()
        self.assertEqual(self.store.get_feature(self.id)["status"], "running")
        self.assertTrue(parked["awaiting_turn"])
        self.assertFalse(parked["needs_user"])
        self.assertEqual(parked["needs_user_prompt"], "Planning the irrigation layout.")
        direct("INSERT INTO fm_messages(id,feature_id,role,text,status,created_at,updated_at) VALUES('fmm_synthetic_long',?,'assistant',?,'done',?,?)",
               self.id, "Q" * 2000, _now(), _now())
        self.assertEqual((summary()["needs_user_prompt"], len(summary()["latest_message"])), ("Q" * 600, 1200))

        assignment = self.store.create_assignment(visit["id"], {"title": "Survey", "role": "planner", "prompt": PRIVATE_PROMPT, "request_id": "assign"})
        self.assertTrue(summary()["awaiting_turn"], "queued work is not running")
        self.store.claim_assignment(assignment["id"], "worker")
        self.assertEqual((summary()["awaiting_turn"], summary()["needs_user_prompt"]), (False, None))
        direct("UPDATE fm_assignments SET status='completed',updated_at=? WHERE id=?", _now(), assignment["id"])
        self.assertTrue(summary()["awaiting_turn"])

        direct("UPDATE fm_features SET coordinator_owner='synthetic' WHERE id=?", self.id)
        self.assertFalse(summary()["awaiting_turn"])
        direct("UPDATE fm_features SET coordinator_owner=NULL WHERE id=?", self.id)

        self.store.append_human_message(self.id, "Beds are two metres long", "reply")
        self.assertEqual((summary()["awaiting_turn"], summary()["needs_user_prompt"]), (False, None))
        message = self.store.claim_message(self.id, "coordinator")
        self.assertFalse(summary()["awaiting_turn"])
        self.store.finish_message(message["id"], "coordinator", "Thanks. Reply when the soil test is back.")
        self.assertEqual(summary()["needs_user_prompt"], "Thanks. Reply when the soil test is back.")
        direct("INSERT INTO fm_messages(id,feature_id,role,text,status,created_at,updated_at) VALUES('fmm_synthetic_user',?,'user','Done','done',?,?)",
               self.id, _now(), _now())
        self.assertFalse(summary()["awaiting_turn"], "the human spoke last")
        direct("DELETE FROM fm_messages WHERE id='fmm_synthetic_user'")
        self.assertTrue(summary()["awaiting_turn"])
        direct("UPDATE fm_features SET status='coordinating' WHERE id=?", self.id)
        self.assertTrue(summary()["awaiting_turn"])
        self.store.feature_action(self.id, "pause", "pause")
        paused = summary()
        self.assertEqual((paused["awaiting_turn"], paused["needs_user"], paused["needs_user_prompt"]), (False, False, None))
        direct("UPDATE fm_features SET status='awaiting_direction' WHERE id=?", self.id)
        gated = summary()
        self.assertEqual((gated["awaiting_turn"], gated["needs_user"], gated["needs_user_prompt"]), (False, True, "Needs your direction"))

    def test_board_and_journal_snapshot_read_without_the_writer_lock_or_decoding_telemetry(self):
        self.stage()
        self.bulk_events(["pi.message_end", "reliability.sweep", "pi.context_usage"], {"synthetic": True})
        statements, decoded = [], []
        original = FirstMateStore._decode

        def record(row):
            decoded.append(dict(row) if row is not None else None)
            return original(row)

        self.store._db.set_trace_callback(statements.append)
        try:
            with patch.object(FirstMateStore, "_decode", staticmethod(record)):
                self.store.board(self.id)
                self.store.snapshot(self.id, events="journal")
            self.assertNotIn("BEGIN IMMEDIATE", statements)
            self.assertEqual(statements.count("BEGIN"), 2)
            self.assertTrue(any(row and row.get("type") == "reliability.sweep" for row in decoded))
            self.assertFalse([row for row in decoded if row and str(row.get("type", "")).startswith("pi.")])
            statements.clear()
            self.store.snapshot(self.id)
            self.assertIn("BEGIN IMMEDIATE", statements)
        finally:
            self.store._db.set_trace_callback(None)

    def test_if_version_short_circuits_without_building_a_projection(self):
        self.stage()
        current = self.store.board(self.id)
        with patch.object(self.store, "_feature_summaries", side_effect=AssertionError("projection built")):
            self.assertEqual(self.store.board(self.id, if_version=current["version"]),
                             {"version": current["version"], "unchanged": True})
        for stale in ("", "b1-stale"):
            full = self.store.board(self.id, if_version=stale)
            self.assertEqual(full, current)

    def test_store_validation(self):
        for bounds in ({"messages": 0}, {"messages": 201}, {"messages": True}, {"messages": "5"},
                       {"journal": -1}, {"journal": 201}, {"journal": 1.5}, {"if_version": "v" * 201},
                       {"if_version": 7}):
            with self.subTest(bounds=bounds), self.assertRaises(FirstMateError) as error:
                self.store.board(self.id, **bounds)
            self.assertEqual(error.exception.code, "invalid_request")
        with self.assertRaises(FirstMateError) as error:
            self.store.board("fmf_missing")
        self.assertEqual(error.exception.status, 404)
        with self.assertRaises(FirstMateError) as error:
            self.store.snapshot(self.id, events="telemetry")
        self.assertEqual(error.exception.code, "invalid_request")

    def test_journal_snapshot_keeps_default_and_reports_the_true_event_cursor(self):
        self.stage()
        self.store.append_event(self.id, "pi.message_end", "Agent response recorded", {"synthetic": True})
        default = self.store.snapshot(self.id)
        self.assertIn("pi.message_end", {event["type"] for event in default["events"]})
        journal = self.store.snapshot(self.id, events="journal")
        self.assertEqual(journal["events"], [event for event in default["events"] if not event["type"].startswith("pi.")])
        self.assertEqual({key: value for key, value in journal.items() if key != "events"},
                         {key: value for key, value in default.items() if key != "events"})
        cursor = default["events"][-1]["sequence"]
        self.assertEqual((default["event_cursor"], journal["event_cursor"], self.store.board(self.id)["event_cursor"]),
                         (cursor, cursor, cursor))
        self.assertLess(journal["events"][-1]["sequence"], cursor)
        # A ledger holding only telemetry still reports its cursor.
        with self.store._transaction():
            self.store._db.execute("DELETE FROM fm_events WHERE feature_id=?", (self.id,))
        self.assertEqual(self.store.snapshot(self.id, events="journal")["event_cursor"], 0)
        self.store.append_event(self.id, "pi.context_usage", "Context usage measured", {"synthetic": True})
        only = self.store.snapshot(self.id, events="journal")
        self.assertEqual(only["events"], [])
        self.assertEqual(only["event_cursor"], self.store.snapshot(self.id)["events"][-1]["sequence"])
        self.assertEqual(self.store.board(self.id)["event_cursor"], only["event_cursor"])

    def test_large_telemetry_ledger_stays_bounded_and_unchanged_polls_are_cheap(self):
        visit = self.stage()
        self.running(visit)
        for index in range(30):
            self.store.append_human_message(self.id, f"Synthetic direction {index}", f"direction-{index}")
        # Realistic telemetry payloads make the full snapshot several megabytes.
        payload = {"event": {"type": "message_end", "text": "synthetic telemetry " * 25}}
        types = ["pi.message_end" if index % 3 else "pi.tool_execution_start" for index in range(20000)]
        for index in range(300):
            types.insert(index * 67, "reliability.sweep" if index % 2 else "assignment.progress")
        self.bulk_events(types, payload)
        journal_total = len(self.store.snapshot(self.id, events="journal")["events"])
        self.assertGreater(journal_total, 300)
        board = self.store.board(self.id)
        encoded = json.dumps(board).encode()
        self.assertLess(len(encoded), 200 * 1024)
        self.assertEqual((len(board["journal"]), board["journal_total"]), (40, journal_total))
        self.assertEqual(len(board["messages"]), 32)
        self.assertEqual(board["event_cursor"], self.store._db.execute("SELECT max(sequence) FROM fm_events").fetchone()[0])

        statements = []
        steps = [0]
        self.store._db.set_trace_callback(statements.append)
        self.store._db.set_progress_handler(lambda: steps.__setitem__(0, steps[0] + 1), 100)
        try:
            started = time.perf_counter()
            for _ in range(20):
                self.assertTrue(self.store.board(self.id, if_version=board["version"])["unchanged"])
            elapsed = time.perf_counter() - started
        finally:
            self.store._db.set_trace_callback(None)
            self.store._db.set_progress_handler(None, 100)
        self.assertLess(elapsed, 0.05)
        self.assertEqual({statement.split()[0] for statement in statements}, {"BEGIN", "SELECT", "COMMIT"})
        queries = [statement for statement in statements if statement.startswith("SELECT")]
        self.assertEqual(len(queries), 20)
        self.assertTrue(all(query.startswith("SELECT f.*") and f"FROM fm_features f WHERE f.id='{self.id}'" in query for query in queries))
        # About 160 VM steps per poll; reading one row per telemetry event would
        # take more than 60,000.
        self.assertLess(steps[0] * 100 / 20, 1000)


class FirstMateBoardRuntimeTests(BoardFixture, unittest.TestCase):
    def test_runtime_board_adds_only_pure_routing_without_jobs_or_usage(self):
        self.stage()
        runtime = FirstMateRuntime(self.store, environ={"HERDR_FIRST_MATE_MODEL": "synthetic/host"},
                                   runtime_root=Path(self.temp.name) / "runtime")
        with patch.object(runtime, "_jobs", side_effect=AssertionError("job scan")), \
                patch.object(runtime, "_usage_account", side_effect=AssertionError("usage")), \
                patch.object(runtime.context, "project", side_effect=AssertionError("context")):
            board = runtime.board(self.id, messages=5)
            self.assertEqual(runtime.board(self.id, if_version=board["version"]),
                             {"version": board["version"], "unchanged": True})
        self.assertEqual(board["feature"]["model_selection"]["requested_model"], "synthetic/host")
        self.assertNotIn("usage", board["feature"])
        self.assertNotIn("coordinator_context", board["feature"])
        journal = runtime.snapshot(self.id, events="journal")
        self.assertIn("usage", journal["feature"])
        self.assertTrue(all(_is_journal_event_type(event["type"]) for event in journal["events"]))


class FirstMateBoardHTTPTests(BoardFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        health = {"status": "healthy", "scheduler_alive": True, "last_success_at": None, "error_kind": None, "consecutive_failures": 0}
        runtime = SimpleNamespace(capabilities=lambda: {"available": True}, health=lambda: health)
        service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token"},
                                  first_mate_store=self.store, first_mate=runtime, first_mate_changed=lambda _id: None)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.stage()
        self.store.append_event(self.id, "pi.message_end", "Agent response recorded", {"synthetic": True})

    def request(self, path, token="synthetic-main-token"):
        headers = {"Authorization": "Bearer " + token} if token else {}
        try:
            response = urllib.request.urlopen(urllib.request.Request(self.origin + path, headers=headers))
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def test_capabilities_and_board_route(self):
        _, capabilities = self.request("/api/v1/first-mate/capabilities")
        self.assertIn("first-mate-board-v1", capabilities["capabilities"])
        self.assertIn("first-mate-journal-events-v1", capabilities["capabilities"])
        path = f"/api/v1/first-mate/features/{self.id}/board"
        self.assertEqual(self.request(path, token=None)[0], 401)
        code, board = self.request(path + "?messages=1&journal=2")
        self.assertEqual(code, 200)
        self.assertEqual(set(board), BOARD_FIELDS | {"ok", "runtime_health"})
        self.assertEqual((len(board["messages"]), len(board["journal"])), (1, 2))
        self.assertNotIn("pi.message_end", {event["type"] for event in board["journal"]})
        self.assertEqual(board["runtime_health"]["status"], "healthy")
        code, unchanged = self.request(path + "?if_version=" + board["version"])
        self.assertEqual((code, unchanged), (200, {"ok": True, "version": board["version"], "unchanged": True}))
        code, stale = self.request(path + "?if_version=b1-stale&messages=1&journal=2")
        self.assertEqual(code, 200)
        self.assertEqual(stale, board)
        self.assertEqual(self.request("/api/v1/first-mate/features/fmf_missing/board")[0], 404)

    def test_board_query_validation(self):
        path = f"/api/v1/first-mate/features/{self.id}/board?"
        for query in ("messages=abc", "messages=0", "messages=201", "journal=-1", "journal=201", "journal=",
                      "unknown=1", "messages=1&messages=2", "if_version=a&if_version=b", "if_version=" + "v" * 201):
            with self.subTest(query=query):
                code, body = self.request(path + query)
                self.assertEqual(code, 400)
                self.assertEqual(body["error"]["code"], "invalid_request")

    def test_snapshot_events_view_is_opt_in(self):
        path = f"/api/v1/first-mate/features/{self.id}"
        code, default = self.request(path)
        self.assertEqual(code, 200)
        self.assertIn("pi.message_end", {event["type"] for event in default["events"]})
        self.assertEqual(self.request(path + "?events=all")[1], default)
        self.assertEqual(self.request(path + "?unrelated=ignored")[1], default)
        code, journal = self.request(path + "?events=journal")
        self.assertEqual(code, 200)
        self.assertEqual(journal["events"], [event for event in default["events"] if not event["type"].startswith("pi.")])
        self.assertEqual(journal["event_cursor"], default["event_cursor"])
        self.assertEqual(default["event_cursor"], default["events"][-1]["sequence"])
        for query in ("events=telemetry", "events=", "events=all&events=journal"):
            with self.subTest(query=query):
                code, body = self.request(path + "?" + query)
                self.assertEqual((code, body["error"]["code"]), (400, "invalid_request"))


if __name__ == "__main__":
    unittest.main()
