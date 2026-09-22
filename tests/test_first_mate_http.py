"""The First Mate surface retains the companion's authentication boundary."""
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.server import make_handler


class FirstMateHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = FirstMateStore(Path(self.temp.name) / "work.sqlite3")
        self.wakes = []
        runtime = SimpleNamespace(capabilities=lambda: {"available": True}, session=lambda identity, **paging: {"ok": True, "native_session_id": identity, "messages": [], **paging})
        self.service = SimpleNamespace(
            environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token"},
            first_mate_store=self.store, first_mate=runtime,
            first_mate_changed=self.wakes.append,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.store.close()
        self.temp.cleanup()

    def request(self, path, body=None, token="synthetic-main-token"):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            data = response.read()
            return response.status, json.loads(data) if "application/json" in response.headers.get("Content-Type", "") else data

    def create(self):
        return self.request("/api/v1/first-mate/features", {"title": "Garden timer", "goal": "Plan a reliable watering timer", "cwd": self.temp.name, "request_id": "create-garden"})

    def test_public_shell_never_exposes_private_feature_data(self):
        self.create()
        code, html = self.request("/first-mate/", token=None)
        self.assertEqual(code, 200)
        self.assertIn(b"Message First Mate", html)
        self.assertNotIn(b"Garden timer", html)
        for token in (None, "synthetic-ingest-token"):
            code, _ = self.request("/api/v1/first-mate/features", token=token)
            self.assertEqual(code, 401)

    def test_creation_and_messages_are_durable_and_idempotent(self):
        code, first = self.create()
        self.assertEqual(code, 201)
        _, second = self.create()
        self.assertEqual(first["feature"]["id"], second["feature"]["id"])
        identity = first["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/messages"
        body = {"text": "Explore the sensor first; do not implement yet.", "request_id": "direction-one"}
        code, message = self.request(path, body)
        self.assertEqual(code, 202)
        _, duplicate = self.request(path, body)
        self.assertEqual(message["message"]["id"], duplicate["message"]["id"])
        _, detail = self.request(f"/api/v1/first-mate/features/{identity}")
        self.assertEqual(len(detail["messages"]), 2)
        self.assertEqual(detail["visits"], [])
        self.assertEqual(detail["feature"]["status"], "ready")
        self.assertEqual(detail["messages"][-1]["text"], body["text"])

    def test_request_id_reuse_cannot_change_a_direction(self):
        _, data = self.create()
        path = f'/api/v1/first-mate/features/{data["feature"]["id"]}/messages'
        self.request(path, {"text": "Plan only", "request_id": "same-direction"})
        code, result = self.request(path, {"text": "Deploy now", "request_id": "same-direction"})
        self.assertEqual(code, 409)
        self.assertFalse(result["ok"])

    def test_action_endpoint_cannot_approve_or_advance_a_stage(self):
        _, data = self.create()
        path = f'/api/v1/first-mate/features/{data["feature"]["id"]}/actions'
        for action in ("approve", "advance", "complete", "demo"):
            code, _ = self.request(path, {"action": action, "request_id": action})
            self.assertEqual(code, 400)

    def test_action_endpoint_archives_without_waking_or_changing_workflow(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/actions"
        before = self.store.snapshot(identity)
        wakes = list(self.wakes)
        body = {"action": "archive", "reason": "duplicate", "request_id": "archive-one"}
        code, archived = self.request(path, body)
        self.assertEqual(code, 200)
        self.assertEqual(self.request(path, body)[1], archived)
        self.assertEqual(self.wakes, wakes)
        self.assertEqual(archived["feature"]["status"], before["feature"]["status"])
        self.assertEqual(archived["feature"]["revision"], before["feature"]["revision"])
        self.assertEqual(archived["feature"]["archive_reason"], "duplicate")
        self.assertEqual(self.request("/api/v1/first-mate/features")[1]["features"], [])
        self.assertEqual(len(self.request("/api/v1/first-mate/features?view=archived")[1]["features"]), 1)
        self.assertEqual(len(self.request("/api/v1/first-mate/features?view=all")[1]["features"]), 1)
        self.assertEqual(self.request(path, {"action": "archive", "reason": "finished", "request_id": "bad"})[0], 400)
        code, restored = self.request(path, {"action": "unarchive", "request_id": "unarchive-one"})
        self.assertEqual(code, 200)
        self.assertIsNone(restored["feature"]["archived_at"])
        self.assertEqual(restored["feature"]["status"], before["feature"]["status"])

    def test_archive_capability_is_advertised_at_both_levels(self):
        code, top = self.request("/api/v1")
        self.assertEqual(code, 200)
        self.assertIn("first-mate-archive-v1", top["capabilities"])
        code, first_mate = self.request("/api/v1/first-mate/capabilities")
        self.assertEqual(code, 200)
        self.assertIn("first-mate-archive-v1", first_mate["capabilities"])

    def test_model_settings_require_auth_and_do_not_wake_agents(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/model-settings"
        body = {"model": "synthetic/reasoner", "thinking": "high", "expected_settings_revision": 0, "request_id": "settings-one"}
        for token in (None, "synthetic-ingest-token"):
            self.assertEqual(self.request(path, body, token=token)[0], 401)
        wakes = list(self.wakes)
        code, result = self.request(path, body)
        self.assertEqual(code, 200)
        self.assertEqual(result["feature"]["coordinator_model"], body["model"])
        self.assertEqual(self.wakes, wakes)
        self.assertEqual(len(result["messages"]), 1)
        self.assertEqual(self.request(path, body)[0], 200)
        self.assertEqual(self.request(path, {**body, "request_id": "stale"})[0], 409)
        self.assertEqual(self.request(path, {**body, "thinking": "invalid"})[0], 400)

    def test_events_and_validation(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        code, events = self.request(f"/api/v1/first-mate/features/{identity}/events?after=0")
        self.assertEqual(code, 200)
        self.assertGreater(events["cursor"], 0)
        code, _ = self.request(f"/api/v1/first-mate/features/{identity}/events?after=invalid")
        self.assertEqual(code, 400)

    def test_session_history_pagination_is_validated(self):
        code, result = self.request("/api/v1/first-mate/sessions/demo-session?before=250&limit=75")
        self.assertEqual(code, 200)
        self.assertEqual(result["before"], 250)
        self.assertEqual(result["limit"], 75)
        code, _ = self.request("/api/v1/first-mate/sessions/demo-session?before=-1")
        self.assertEqual(code, 400)
        code, _ = self.request("/api/v1/first-mate/sessions/demo-session?limit=101")
        self.assertEqual(code, 400)
        code, _ = self.request("/api/v1/first-mate/features", {"title": "Bad directory", "goal": "Plan", "cwd": "/nonexistent-first-mate-synthetic-dir", "request_id": "invalid-directory"})
        self.assertEqual(code, 400)


if __name__ == "__main__":
    unittest.main()
