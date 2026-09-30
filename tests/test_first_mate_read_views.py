"""Narrow, conditional First Mate read projections."""
from __future__ import annotations

import gzip
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.first_mate_read_models import verification_summary
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateError, FirstMateStore, _now
from herdr_harness.server import make_handler


class FirstMateReadViewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.addCleanup(self.store.close)
        self.feature = self.store.create_feature({
            "title": "Synthetic read projection", "goal": "Test bounded reads",
            "cwd": str(self.root), "request_id": "create",
        })
        self.id = self.feature["id"]
        self.runtime = FirstMateRuntime(
            self.store, environ={"PATH": "/usr/bin:/bin", "HERDR_FIRST_MATE_MODEL": "synthetic/coordinator"},
            runtime_root=self.root / "runtime")

    def insert_message(self, identity: str, role: str, timestamp: str, *, visibility: str = "conversation",
                       status: str = "done") -> None:
        with self.store._transaction():
            self.store._db.execute(
                "INSERT INTO fm_messages(id,feature_id,role,text,status,owner,metadata_json,created_at,updated_at,visibility) "
                "VALUES(?,?,?,?,?,NULL,'{}',?,?,?)",
                (identity, self.id, role, "Text " + identity, status, timestamp, timestamp, visibility))

    def test_chat_paginates_feature_owned_conversation_in_chronological_order(self):
        roles = ["user", "assistant", "human", "assistant", "user"]
        for index, role in enumerate(roles, 1):
            second = 2 if index == 3 else index  # tied timestamps order by message ID
            self.insert_message(f"message-{index}", role, f"2030-01-01T00:00:0{second}Z")
        self.insert_message("background", "system", "2030-01-01T00:00:06Z", visibility="background")

        newest = self.runtime.read_view(self.id, messages=2)
        self.assertEqual([(row["id"], row["role"]) for row in newest["messages"]],
                         [("message-4", "assistant"), ("message-5", "user")])
        self.assertEqual((newest["next_before"], newest["has_more"]), ("message-4", True))
        middle = self.runtime.read_view(self.id, messages=2, before=newest["next_before"])
        self.assertEqual([row["id"] for row in middle["messages"]], ["message-2", "message-3"])
        oldest = self.runtime.read_view(self.id, messages=2, before=middle["next_before"])
        self.assertEqual([row["id"] for row in oldest["messages"]][-1], "message-1")
        self.assertEqual(oldest["messages"][0]["text"], "Test bounded reads")
        self.assertEqual((oldest["next_before"], oldest["has_more"]), (None, False))
        self.assertEqual(newest["events"], [])
        self.assertEqual(newest["handoffs"], [])

        other = self.store.create_feature({
            "title": "Other", "goal": "Other", "cwd": str(self.root), "request_id": "other"})
        with self.store._transaction():
            self.store._db.execute(
                "INSERT INTO fm_messages(id,feature_id,role,text,status,owner,metadata_json,created_at,updated_at,visibility) "
                "VALUES('other-cursor',?,'user','Other','done',NULL,'{}',?,?, 'conversation')",
                (other["id"], _now(), _now()))
        for cursor in ("missing", "other-cursor", "background"):
            with self.subTest(cursor=cursor), self.assertRaises(FirstMateError) as error:
                self.runtime.read_view(self.id, messages=2, before=cursor, if_version=newest["version"])
            self.assertEqual((error.exception.code, error.exception.status), ("invalid_request", 400))

    def test_conditional_version_tracks_projection_and_rejects_a_racing_body(self):
        self.insert_message("message-1", "user", "2030-01-01T00:00:01Z")
        first = self.runtime.read_view(self.id)
        with patch.object(self.store, "read_projection", side_effect=AssertionError("projection built")):
            self.assertEqual(self.runtime.read_view(self.id, if_version=first["version"]), {
                "version": first["version"], "unchanged": True, "view": "chat",
            })
        self.insert_message("message-2", "assistant", "2030-01-01T00:00:02Z")
        changed = self.runtime.read_view(self.id, if_version=first["version"])
        self.assertFalse(changed["unchanged"])
        self.assertNotEqual(changed["version"], first["version"])

        with patch.object(self.store, "read_version", return_value="concurrently-changed") as versions:
            with self.assertRaises(FirstMateError) as error:
                self.runtime.read_view(self.id)
        self.assertEqual((error.exception.code, error.exception.status), ("read_changed", 409))
        self.assertEqual(versions.call_count, 3)

    def test_racing_chat_reads_share_one_verification_budget(self):
        with patch.object(self.store, "read_version", return_value="concurrently-changed"), \
             patch.object(self.runtime, "_live_verification", return_value={}) as verification:
            with self.assertRaises(FirstMateError):
                self.runtime.read_view(self.id)
        self.assertEqual(verification.call_count, 3)
        deadlines = [call.kwargs["deadline"] for call in verification.call_args_list]
        self.assertEqual(len(set(deadlines)), 1)

    def test_overview_is_transcript_free_and_details_keep_the_legacy_journal(self):
        self.insert_message("message-1", "user", "2030-01-01T00:00:01Z")
        for index in range(6):
            self.store.append_event(self.id, "synthetic.event", f"Event {index}", {"index": index})
        self.store.append_event(self.id, "pi.message_end", "Telemetry", {"synthetic": True})

        overview = self.runtime.read_view(self.id, view="overview")
        self.assertEqual(overview["messages"], [])
        self.assertEqual(len(overview["events"]), 4)
        sequences = [event["sequence"] for event in overview["events"]]
        self.assertEqual(sequences, sorted(sequences))
        self.assertNotIn("pi.message_end", {event["type"] for event in overview["events"]})

        details = self.runtime.read_view(self.id, view="details")
        legacy = self.runtime.snapshot(self.id, events="journal")
        for key, value in legacy.items():
            self.assertEqual(details[key], value, key)
        self.assertNotIn("pi.message_end", {event["type"] for event in details["events"]})

    def test_compact_views_hide_checkpoint_documents_but_details_retain_them(self):
        claimed_message = self.store.claim_message(self.id, "coordinator")
        visit = self.store.start_visit(self.id, "build", "Build", "visit", 1, claimed_message["id"])
        self.store.finish_message(claimed_message["id"], "coordinator", "Starting build.")
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Implement", "role": "implementer", "prompt": "Implement.",
            "request_id": "assignment",
        })
        claimed = self.store.claim_assignment(assignment["id"], "worker")
        assignment = self.store.bind_session(
            assignment["id"], claimed["generation"], "worker", "worker-session",
            str(self.root / "runtime" / "sessions" / "worker.jsonl"), "run")
        with self.store._transaction():
            user_document = self.store._document(assignment, "User report", "Visible report")
            checkpoint = self.store._document(assignment, "Session checkpoint", "Private checkpoint")
            now = _now()
            self.store._db.execute(
                "INSERT INTO fm_handoffs(id,assignment_id,feature_id,predecessor_generation,"
                "predecessor_session_id,summary,document_id,status,created_at,updated_at) "
                "VALUES('handoff-1',?,?,?,?,?,?, 'checkpointed',?,?)",
                (assignment["id"], self.id, assignment["generation"], "worker-session",
                 "Synthetic checkpoint", checkpoint["id"], now, now))

        for view in ("chat", "overview"):
            compact = self.runtime.read_view(self.id, view=view)
            self.assertEqual([row["id"] for row in compact["documents"]], [user_document["id"]])
            self.assertEqual(compact["handoffs"], [])
        details = self.runtime.read_view(self.id, view="details")
        self.assertEqual({row["id"] for row in details["documents"]},
                         {user_document["id"], checkpoint["id"]})
        self.assertEqual([row["document_id"] for row in details["handoffs"]], [checkpoint["id"]])

    def test_chat_exposes_latest_coordinator_session_and_queued_work(self):
        message = self.store.claim_message(self.id, "coordinator-owner")
        sessions = self.root / "runtime" / "sessions"
        sessions.mkdir(parents=True)
        session_file = sessions / "coordinator.jsonl"
        session_file.write_text(
            '\n'.join((
                json.dumps({"type": "session", "id": "coordinator-session"}),
                json.dumps({"type": "model_change", "model": {"provider": "synthetic", "id": "actual"}}),
                json.dumps({"type": "thinking_level_change", "thinkingLevel": "high"}),
            )) + '\n')
        self.store.bind_coordinator_session(
            self.id, "coordinator-owner", "coordinator-session", str(session_file))

        queued = self.runtime.read_view(self.id)
        self.assertTrue(queued["has_queued_work"])
        self.assertEqual(len(queued["sessions"]), 1)
        session = queued["sessions"][0]
        self.assertEqual(session["native_session_id"], "coordinator-session")
        self.assertEqual(session["model_selection"]["actual_model"], "synthetic/actual")
        self.assertEqual(session["model_selection"]["actual_thinking"], "high")

        self.store.finish_message(message["id"], "coordinator-owner", "Finished.")
        settled = self.runtime.read_view(self.id)
        self.assertFalse(settled["has_queued_work"])
        self.assertNotEqual(settled["version"], queued["version"])

    def test_compact_verified_summary_retains_gate_and_revision_proof(self):
        revision = "a" * 40
        compact = verification_summary({
            "status": "verified", "label": "Verified", "feature_revision": 3,
            "evidence_present": True, "assessed_revisions": {"project": revision},
            "source_revisions": [revision], "tested_revisions": [revision],
            "gate_set": [{
                "key": "project:pkg/Suite", "label": "pkg/Suite", "workspace": "project",
                "package": "pkg", "suite": "Suite", "outcome": "passed",
                "tested_revision": revision, "run_id": "run-1", "fresh": True,
                "reason": "large diagnostic text", "passed_count": 500,
            }],
            "required_suites": [{"label": "pkg/Suite"}], "missing_suites": [],
            "coverage_reasons": [],
        })
        self.assertEqual(compact["source_revisions"], [revision])
        self.assertEqual(compact["tested_revisions"], [revision])
        self.assertEqual(compact["gate_set"], [{
            "key": "project:pkg/Suite", "label": "pkg/Suite", "package": "pkg", "suite": "Suite",
            "workspace": "project", "outcome": "passed", "tested_revision": revision,
            "run_id": "run-1", "fresh": True,
        }])
        self.assertEqual(compact["counts"]["required_suites"], 1)
        self.assertNotIn("required_suites", compact)

    def test_verification_read_failure_closes_and_gate_assessment_bypasses_cache(self):
        raw = self.store.get_feature(self.id)
        with patch.object(self.runtime, "_verification_read_identity",
                          side_effect=OSError("synthetic workspace failure")):
            unavailable = self.runtime._live_verification(raw)
        self.assertEqual(unavailable["status"], "unavailable")
        self.assertIn("synthetic workspace failure", unavailable["coverage_reasons"][0])

        with patch.object(self.runtime._assessment_reads, "get",
                          side_effect=AssertionError("gate decision used read cache")), \
                patch.object(self.runtime, "_verification_scope", return_value={
                    "revisions": {}, "changed_paths": {}, "complete": False,
                    "reasons": ["synthetic unavailable scope"], "aliases": {},
                }):
            assessment = self.runtime.verification_assessment(self.id)
        self.assertEqual(assessment["status"], "unavailable")

    def test_dirty_workspace_status_never_reuses_a_verification_assessment(self):
        raw = self.store.get_feature(self.id)
        computed = {"count": 0}

        def assess(_feature):
            computed["count"] += 1
            return {"status": "verified", "computed_at": str(computed["count"])}

        with patch.object(self.store, "list_verification_runs", return_value=[{"id": "run-1"}]), \
                patch.object(self.store, "list_suite_inventories", return_value=[]), \
                patch.object(self.runtime, "_verification_workspace_scope", return_value={
                    "workspaces": {"project": str(self.root)}, "anchors": {},
                    "registered_targets": [], "aliases": {}, "reasons": [],
                }), \
                patch.object(self.runtime, "_current_verification_selection", return_value=None), \
                patch.object(self.runtime, "_git", side_effect=lambda _path, *args:
                             "a" * 40 if args[0] == "rev-parse" else " M Sources/Feature.swift"), \
                patch.object(self.runtime, "_compute_live_verification", side_effect=assess):
            self.runtime._live_verification(raw)
            self.runtime._live_verification(raw)
        self.assertEqual(computed["count"], 2)

    def test_evidence_backed_unchanged_board_skips_projection_after_fresh_probe(self):
        verification = {
            "status": "verified", "evidence_present": True, "computed_at": "first",
            "source_revisions": ["a" * 40],
            "gate_set": [{"label": "pkg/Suite", "outcome": "passed"}],
        }
        with patch.object(self.runtime, "_live_verification", return_value=verification) as live:
            first = self.runtime.board(self.id)
            with patch.object(self.store, "board", side_effect=AssertionError("board projection built")):
                unchanged = self.runtime.board(self.id, if_version=first["version"])
        self.assertEqual(unchanged, {"version": first["version"], "unchanged": True})
        self.assertEqual(live.call_count, 2, "the conditional poll must freshly probe verification")


class FirstMateReadViewHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.runtime = FirstMateRuntime(
            self.store, environ={"PATH": "/usr/bin:/bin", "HERDR_FIRST_MATE_MODEL": "synthetic/coordinator"},
            runtime_root=self.root / "runtime")
        self.feature = self.store.create_feature({
            "title": "Synthetic HTTP projection", "goal": "G" * 5000,
            "cwd": str(self.root), "request_id": "create",
        })
        service = SimpleNamespace(
            environ={"HERDR_HARNESS_API_TOKEN": "synthetic-token"},
            first_mate_store=self.store, first_mate=self.runtime,
            first_mate_changed=lambda _feature_id: None,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.store.close()
        self.temp.cleanup()

    def request(self, path: str, *, accept_encoding: str | None = None):
        headers = {"Authorization": "Bearer synthetic-token"}
        if accept_encoding is not None:
            headers["Accept-Encoding"] = accept_encoding
        request = urllib.request.Request(self.origin + path, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, dict(response.headers), response.read()

    def json_request(self, path: str):
        status, headers, body = self.request(path)
        return status, headers, json.loads(body)

    def test_capabilities_presentation_and_legacy_snapshot_coexist(self):
        feature_id = self.feature["id"]
        status, _, capabilities = self.json_request("/api/v1/first-mate/capabilities")
        self.assertEqual(status, 200)
        self.assertIn("first-mate-read-views-v1", capabilities["capabilities"])
        self.assertIn("first-mate-verification-summary-v1", capabilities["capabilities"])

        path = f"/api/v1/first-mate/features/{feature_id}/presentation?view=chat&messages=2"
        status, _, presentation = self.json_request(path)
        self.assertEqual(status, 200)
        self.assertEqual((presentation["view"], presentation["unchanged"]), ("chat", False))
        unchanged_path = path + "&if_version=" + urllib.parse.quote(presentation["version"])
        status, _, unchanged = self.json_request(unchanged_path)
        self.assertEqual(status, 200)
        self.assertEqual({key: unchanged[key] for key in ("version", "unchanged", "view")}, {
            "version": presentation["version"], "unchanged": True, "view": "chat",
        })

        status, _, legacy = self.json_request(f"/api/v1/first-mate/features/{feature_id}?events=journal")
        self.assertEqual(status, 200)
        self.assertTrue({"feature", "visits", "assignments", "documents", "messages", "events",
                         "sessions", "handoffs", "links", "event_cursor"}.issubset(legacy))
        self.assertNotIn("version", legacy)

        status, _, listed = self.json_request("/api/v1/first-mate/features?summary=1")
        self.assertEqual(status, 200)
        self.assertTrue(listed["features"][0]["verification"].get("summary", False)
                        or listed["features"][0]["verification"] == {})

    def test_summary_list_and_chat_retain_verified_proof(self):
        revision = "b" * 40
        verification = {
            "status": "verified", "label": "Verified", "feature_revision": 1,
            "evidence_present": True, "assessed_revisions": {"project": revision},
            "source_revisions": [revision], "tested_revisions": [revision],
            "gate_set": [{"key": "project:pkg/Suite", "label": "pkg/Suite", "workspace": "project",
                          "outcome": "passed", "tested_revision": revision, "fresh": True}],
            "required_suites": [{"label": "pkg/Suite"}], "computed_at": "2030-01-01T00:00:00Z",
        }
        feature = {**self.runtime.feature(self.feature["id"]), "verification": verification}
        with patch.object(self.runtime, "list_features", return_value=[feature]):
            _, _, listed = self.json_request("/api/v1/first-mate/features?summary=1")
        summary = listed["features"][0]["verification"]
        self.assertTrue(summary["summary"])
        self.assertEqual(summary["source_revisions"], [revision])
        self.assertEqual(summary["gate_set"][0]["outcome"], "passed")

        with patch.object(self.runtime, "_live_verification", return_value=verification):
            _, _, chat = self.json_request(
                f"/api/v1/first-mate/features/{self.feature['id']}/presentation?view=chat")
        self.assertTrue(chat["feature"]["verification"]["summary"])
        self.assertEqual(chat["feature"]["verification"]["gate_set"][0]["tested_revision"], revision)

    def test_presentation_query_validation(self):
        base = f"/api/v1/first-mate/features/{self.feature['id']}/presentation?"
        for query in ("view=unknown", "view=chat&view=overview", "view=overview&before=cursor",
                      "messages=0", "messages=201", "messages=abc", "unknown=1"):
            with self.subTest(query=query):
                status, _, body = self.json_request(base + query)
                self.assertEqual(status, 400)
                self.assertEqual(body["error"]["code"], "invalid_request")

    def test_successful_get_json_negotiates_gzip_only_when_accepted(self):
        path = "/api/v1/first-mate/features"
        status, headers, packed = self.request(path, accept_encoding="br, gzip;q=1")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Encoding"), "gzip")
        self.assertEqual(int(headers["Content-Length"]), len(packed))
        self.assertEqual(json.loads(gzip.decompress(packed))["features"][0]["id"], self.feature["id"])

        status, headers, plain = self.request(path, accept_encoding="gzip;q=0, *;q=1")
        self.assertEqual(status, 200)
        self.assertNotIn("Content-Encoding", headers)
        self.assertEqual(json.loads(plain)["features"][0]["id"], self.feature["id"])


if __name__ == "__main__":
    unittest.main()
