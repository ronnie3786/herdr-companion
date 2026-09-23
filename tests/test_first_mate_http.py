"""The First Mate surface retains the companion's authentication boundary."""
import base64
import http.client
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.server import make_handler
from herdr_harness.service import HerdrService


class FirstMateHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = FirstMateStore(Path(self.temp.name) / "work.sqlite3")
        self.wakes = []
        self.git_calls = []
        runtime = SimpleNamespace(capabilities=lambda: {"available": True}, health=lambda: {"status": "degraded", "scheduler_alive": True, "error_kind": "storage_full", "last_success_at": None, "consecutive_failures": 1}, session=lambda identity, **paging: {"ok": True, "native_session_id": identity, "messages": [], **paging})
        self.service = SimpleNamespace(
            environ={
                "HERDR_HARNESS_API_TOKEN": "synthetic-main-token",
                "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token",
                "HERDR_HARNESS_ATTACHMENTS_DIR": str(Path(self.temp.name) / "attachments"),
            },
            first_mate_store=self.store, first_mate=runtime,
            first_mate_changed=self.wakes.append,
            _decode_attachment=HerdrService._decode_attachment,
            first_mate_git_workspaces=lambda feature_id: {"ok": True, "workspaces": [{"id": "project", "title": "Project workspace", "path": self.temp.name}]},
            first_mate_git_status=lambda feature_id, workspace: self._git_call("status", feature_id, workspace),
            first_mate_git_diff=lambda feature_id, workspace, **values: self._git_call("diff", feature_id, workspace, **values),
            first_mate_git_stage=lambda feature_id, workspace, **values: self._git_call("stage", feature_id, workspace, **values),
            first_mate_git_unstage=lambda feature_id, workspace, **values: self._git_call("unstage", feature_id, workspace, **values),
            first_mate_git_open=lambda feature_id, workspace, **values: self._git_call("open", feature_id, workspace, **values),
            first_mate_git_commit_files=lambda feature_id, workspace, **values: self._git_call("commit-files", feature_id, workspace, **values),
            first_mate_git_commit_diff=lambda feature_id, workspace, **values: self._git_call("commit-diff", feature_id, workspace, **values),
        )
        self.service.first_mate_attachment = (
            lambda feature_id, **values: HerdrService.first_mate_attachment(
                self.service, feature_id, **values
            )
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

    def _git_call(self, action, feature_id, workspace, **values):
        self.git_calls.append((action, feature_id, workspace, values))
        return {"ok": True, "feature_id": feature_id, "workspace": workspace, "root_path": self.temp.name, "staged": [], "unstaged": [], "untracked": [], "commits": [], **values}

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

    def test_runtime_health_is_additive_authenticated_and_does_not_mutate_feature_state(self):
        _, data = self.create()
        identity = data['feature']['id']
        before = self.store.snapshot(identity)
        code, detail = self.request(f'/api/v1/first-mate/features/{identity}')
        self.assertEqual(code, 200)
        self.assertEqual(detail['runtime_health']['status'], 'degraded')
        self.assertEqual(detail['runtime_health']['error_kind'], 'storage_full')
        self.assertEqual(self.store.snapshot(identity), before)
        self.assertEqual(self.request(f'/api/v1/first-mate/features/{identity}', token=None)[0], 401)
        _, capabilities = self.request('/api/v1/first-mate/capabilities')
        self.assertIn('first-mate-runtime-health-v1', capabilities['capabilities'])

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
        for capability in (
            "first-mate-attachments-v1",
            "first-mate-context-v1",
            "first-mate-safe-model-settings-v1",
        ):
            self.assertIn(capability, top["capabilities"])
            self.assertIn(capability, first_mate["capabilities"])

    def test_git_capability_and_every_authenticated_operation_forward_the_complete_contract(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        base = f"/api/v1/first-mate/features/{feature_id}/git"
        root = self.temp.name
        self.assertIn("first-mate-git-v1", self.request("/api/v1")[1]["capabilities"])
        self.assertIn("first-mate-git-v1", self.request("/api/v1/first-mate/capabilities")[1]["capabilities"])
        encoded_root = urllib.parse.quote(root, safe="")
        unauthorized_operations = (
            (base + "/workspaces", None),
            (base + "?workspace=project", None),
            (base + f"/diff?workspace=project&file=tracked.txt&section=unstaged&expected_root={encoded_root}", None),
            (base + f"/commit-files?workspace=project&hash=a1b2c3d4&expected_root={encoded_root}", None),
            (base + f"/commit-diff?workspace=project&hash=a1b2c3d4&file=tracked.txt&expected_root={encoded_root}", None),
            (base + "/stage", {"workspace": "project", "file": "tracked.txt", "expected_root": root}),
            (base + "/unstage", {"workspace": "project", "file": "tracked.txt", "expected_root": root}),
            (base + "/open", {"workspace": "project", "file": "tracked.txt", "expected_root": root, "reveal": True}),
        )
        for token in (None, "synthetic-ingest-token"):
            for path, body in unauthorized_operations:
                with self.subTest(token=token, path=path):
                    self.assertEqual(self.request(path, body, token=token)[0], 401)

        self.assertEqual(self.request(base + "/workspaces")[1]["workspaces"][0]["id"], "project")
        operations = [
            (base + "?workspace=worker-1", None, ("status", feature_id, "worker-1", {})),
            (base + f"/diff?workspace=worker-1&file=Sources%2FApp.swift&section=unstaged&expected_root={urllib.parse.quote(root, safe='')}", None,
             ("diff", feature_id, "worker-1", {"file": "Sources/App.swift", "section": "unstaged", "expected_root": root})),
            (base + f"/commit-files?workspace=worker-1&hash=a1b2c3d4&expected_root={urllib.parse.quote(root, safe='')}", None,
             ("commit-files", feature_id, "worker-1", {"commit_hash": "a1b2c3d4", "expected_root": root})),
            (base + f"/commit-diff?workspace=worker-1&hash=a1b2c3d4&file=Sources%2FApp.swift&expected_root={urllib.parse.quote(root, safe='')}", None,
             ("commit-diff", feature_id, "worker-1", {"commit_hash": "a1b2c3d4", "file": "Sources/App.swift", "expected_root": root})),
            (base + "/stage", {"workspace": "worker-1", "file": "Sources/App.swift", "expected_root": root},
             ("stage", feature_id, "worker-1", {"file": "Sources/App.swift", "expected_root": root})),
            (base + "/unstage", {"workspace": "worker-1", "file": "Sources/App.swift", "expected_root": root},
             ("unstage", feature_id, "worker-1", {"file": "Sources/App.swift", "expected_root": root})),
            (base + "/open", {"workspace": "worker-1", "file": "Sources/App.swift", "expected_root": root, "reveal": True},
             ("open", feature_id, "worker-1", {"file": "Sources/App.swift", "expected_root": root, "reveal": True})),
        ]
        for path, body, expected_call in operations:
            with self.subTest(path=path):
                self.assertEqual(self.request(path, body)[0], 200)
                self.assertEqual(self.git_calls[-1], expected_call)

    def test_git_routes_reject_missing_preconditions_malformed_queries_and_unknown_fields_before_tools(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        base = f"/api/v1/first-mate/features/{feature_id}/git"
        root = self.temp.name
        invalid_requests = [
            (base + "/workspaces?path=%2Fclient", None),
            (base + "?workspace=project&workspace=other", None),
            (base + "?workspace=project&path=%2Fclient", None),
            (base + "/diff?workspace=project&file=tracked.txt&section=unstaged", None),
            (base + f"/diff?workspace=project&file=tracked.txt&section=unstaged&expected_root={urllib.parse.quote(root, safe='')}&path=%2Fclient", None),
            (base + "/commit-files?workspace=project&hash=a1b2c3d4", None),
            (base + "/commit-diff?workspace=project&hash=a1b2c3d4&file=tracked.txt", None),
            (base + f"/stage?workspace=project", {"workspace": "project", "file": "tracked.txt", "expected_root": root}),
            (base + "/stage", {"workspace": "project", "file": "tracked.txt"}),
            (base + "/unstage", {"workspace": "project", "file": "tracked.txt"}),
            (base + "/open", {"workspace": "project", "file": "tracked.txt"}),
            (base + "/stage", {"workspace": "project", "file": "tracked.txt", "expected_root": root, "reveal": True}),
            (base + "/open", {"workspace": "project", "file": "tracked.txt", "expected_root": root, "path": "/client"}),
            (base + "/open", {"workspace": "project", "file": "tracked.txt", "expected_root": root, "reveal": "yes"}),
        ]
        for path, body in invalid_requests:
            before = len(self.git_calls)
            with self.subTest(path=path, body=body):
                code, result = self.request(path, body)
                self.assertEqual(code, 400)
                self.assertEqual(result["error"]["code"], "invalid_request")
                self.assertEqual(len(self.git_calls), before)

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

    def test_attachment_upload_is_bounded_authenticated_and_feature_scoped(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/attachments"
        payload = {
            "filename": "../synthetic notes.txt",
            "content_type": "text/plain",
            "data_base64": base64.b64encode(b"synthetic notes").decode(),
        }
        for token in (None, "synthetic-ingest-token"):
            self.assertEqual(self.request(path, payload, token=token)[0], 401)
        code, result = self.request(path, payload)
        self.assertEqual(code, 200)
        attachment = result["attachment"]
        self.assertEqual(set(attachment), {
            "id", "filename", "originalFilename", "contentType", "size",
            "path", "workspaceId", "createdAt",
        })
        self.assertEqual(attachment["originalFilename"], payload["filename"])
        self.assertEqual(attachment["workspaceId"], "first-mate:" + identity)
        stored = Path(attachment["path"])
        self.assertEqual(stored.read_bytes(), b"synthetic notes")
        self.assertTrue(stored.resolve().is_relative_to(
            Path(self.service.environ["HERDR_HARNESS_ATTACHMENTS_DIR"]).resolve()))
        self.assertEqual(self.request(path, {**payload, "workspace_id": "arbitrary"})[0], 400)
        self.assertEqual(self.request(path, {**payload, "filename": "bad\nname.txt"})[0], 400)
        self.assertEqual(self.request(path, {**payload, "content_type": "text/plain\n"})[0], 400)
        self.assertEqual(self.request(path, {**payload, "data_base64": "invalid=="})[0], 400)
        self.assertEqual(self.request(
            "/api/v1/first-mate/features/missing/attachments", payload)[0], 404)

        with patch("herdr_harness.attachments.MAX_ATTACHMENT_BYTES", 3):
            code, body = self.request(path, {**payload, "data_base64": base64.b64encode(b"four").decode()})
        self.assertEqual(code, 413)
        self.assertEqual(body["error"]["code"], "attachment_too_large")

        self.store.feature_action(identity, "complete", "close-feature")
        code, body = self.request(path, payload)
        self.assertEqual(code, 409)
        self.assertEqual(body["error"]["code"], "feature_closed")

    def test_only_first_mate_attachment_route_receives_the_large_json_limit(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        encoded = base64.b64encode(b"x" * (1024 * 1024)).decode()
        upload = {
            "filename": "large.txt",
            "content_type": "text/plain",
            "data_base64": encoded,
        }
        code, result = self.request(
            f"/api/v1/first-mate/features/{identity}/attachments", upload)
        self.assertEqual(code, 200)
        self.assertEqual(result["attachment"]["size"], 1024 * 1024)
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_port, timeout=5)
        try:
            connection.request(
                "POST",
                f"/api/v1/first-mate/features/{identity}/messages",
                headers={
                    "Authorization": "Bearer synthetic-main-token",
                    "Content-Type": "application/json",
                    "Content-Length": str(1024 * 1024 + 1),
                },
            )
            response = connection.getresponse()
            code = response.status
            body = json.loads(response.read())
        finally:
            connection.close()
        self.assertEqual(code, 413)
        self.assertEqual(body["error"]["code"], "body_too_large")

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
