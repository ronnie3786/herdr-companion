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

    def completed_reply(self, feature_id, *, session=None, text="Synthetic completed response."):
        message = self.store.claim_message(feature_id, "coordinator")
        if session:
            self.store.bind_coordinator_session(
                feature_id, "coordinator", session, f"/tmp/synthetic-pi/{session}.jsonl")
        self.store.finish_message(message["id"], "coordinator", reply=text, native_session_id=session)
        return next(
            item for item in self.store.snapshot(feature_id)["messages"]
            if item["role"] == "assistant"
        )

    def feedback_body(self, **overrides):
        body = {
            "rating": "down", "category_ids": [], "comment": "",
            "expected_revision": 0, "request_id": "feedback-one",
        }
        body.update(overrides)
        return body

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

    def test_feedback_capability_is_advertised_at_both_levels(self):
        self.assertEqual(self.request("/api/v1/first-mate/capabilities")[0], 200)
        self.assertIn("first-mate-feedback-v1", self.request("/api/v1")[1]["capabilities"])
        self.assertIn(
            "first-mate-feedback-v1", self.request("/api/v1/first-mate/capabilities")[1]["capabilities"])

    def test_feedback_routes_require_the_main_token(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        reply = self.completed_reply(feature_id)
        operations = [
            ("GET", "/api/v1/first-mate/feedback-categories", None),
            ("POST", "/api/v1/first-mate/feedback-categories", {"label": "Synthetic reason", "request_id": "category-auth"}),
            ("GET", f"/api/v1/first-mate/features/{feature_id}/feedback", None),
            ("POST", f"/api/v1/first-mate/features/{feature_id}/messages/{reply['id']}/feedback", self.feedback_body()),
        ]
        for token in (None, "synthetic-ingest-token"):
            for method, path, body in operations:
                with self.subTest(token=token, path=path):
                    self.assertEqual(self.request(path, body, token=token)[0], 401)

    def test_feedback_categories_reuse_equivalent_labels_without_waking_agents(self):
        code, defaults = self.request("/api/v1/first-mate/feedback-categories")
        self.assertEqual(code, 200)
        self.assertEqual(
            [item["id"] for item in defaults["categories"]],
            ["too_long", "unnecessary_message", "incorrect_assumption"])
        self.assertEqual(
            [item["label"] for item in defaults["categories"]],
            ["Longer than it needed to be", "Unnecessary message", "Incorrect assumption"])
        wakes = list(self.wakes)
        body = {"label": "  Needs   more evidence ", "request_id": "category-one"}
        code, created = self.request("/api/v1/first-mate/feedback-categories", body)
        self.assertEqual(code, 200)
        self.assertEqual(created["category"]["label"], "Needs more evidence")
        self.assertEqual(
            self.request("/api/v1/first-mate/feedback-categories", body)[1], created)
        code, reused = self.request(
            "/api/v1/first-mate/feedback-categories", {"label": "NEEDS MORE EVIDENCE", "request_id": "category-two"})
        self.assertEqual(code, 200)
        self.assertEqual(reused["category"]["id"], created["category"]["id"])
        self.assertEqual(self.wakes, wakes)
        for invalid in (
            {"label": "line\nbreak", "request_id": "category-bad"},
            {"label": "", "request_id": "category-bad"},
            {"label": "Synthetic", "request_id": "category-bad", "extra": 1},
            {"label": "Synthetic"},
        ):
            with self.subTest(body=invalid):
                self.assertEqual(self.request("/api/v1/first-mate/feedback-categories", invalid)[0], 400)
        self.assertEqual(
            self.request("/api/v1/first-mate/feedback-categories", body)[0], 200)

    def test_feedback_rating_round_trips_and_never_touches_workflow_state(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        self.completed_reply(feature_id, session="synthetic-http-coordinator")
        category = self.request(
            "/api/v1/first-mate/feedback-categories",
            {"label": "Needs more evidence", "request_id": "category-http"})[1]["category"]
        base = f"/api/v1/first-mate/features/{feature_id}"
        code, empty = self.request(base + "/feedback")
        self.assertEqual(code, 200)
        self.assertEqual(empty, {"ok": True, "feature_id": feature_id, "records": []})
        reply = next(
            item for item in self.store.snapshot(feature_id)["messages"] if item["role"] == "assistant")
        before = self.store.snapshot(feature_id)
        wakes, pending = list(self.wakes), self.store.pending_messages(feature_id)
        body = self.feedback_body(
            category_ids=["too_long", category["id"]],
            comment="Too long.\nKeep it shorter — synthetic ✨")
        code, result = self.request(base + f"/messages/{reply['id']}/feedback", body)
        self.assertEqual(code, 200)
        self.assertEqual(result["feature_id"], feature_id)
        record = result["feedback"]
        self.assertEqual(record["message_id"], reply["id"])
        self.assertEqual(record["rating"], "down")
        self.assertEqual(record["category_ids"], ["too_long", category["id"]])
        self.assertEqual(record["comment"], body["comment"])
        self.assertEqual(record["revision"], 1)
        self.assertEqual(record["provenance"]["coordinator_session_id"], "synthetic-http-coordinator")
        self.assertEqual(record["provenance"]["session_provenance"], "verified")
        self.assertEqual(record["provenance"]["source_kind"], "reply")
        self.assertEqual(record["provenance"]["response_text"], reply["text"])
        self.assertEqual(self.request(base + f"/messages/{reply['id']}/feedback", body)[1], result)
        self.assertEqual(self.request(base + "/feedback")[1]["records"], [record])
        stale = self.request(base + f"/messages/{reply['id']}/feedback", self.feedback_body(
            category_ids=["too_long"], expected_revision=0, request_id="feedback-stale"))
        self.assertEqual(stale[0], 409)
        self.assertEqual(stale[1]["error"]["code"], "stale_feedback_revision")
        edited = self.request(base + f"/messages/{reply['id']}/feedback", self.feedback_body(
            rating="up", expected_revision=1, request_id="feedback-up"))
        self.assertEqual(edited[0], 200)
        self.assertEqual(edited[1]["feedback"]["rating"], "up")
        cleared = self.request(base + f"/messages/{reply['id']}/feedback", self.feedback_body(
            rating=None, expected_revision=2, request_id="feedback-clear"))
        self.assertEqual(cleared[0], 200)
        self.assertIsNone(cleared[1]["feedback"]["rating"])
        records = self.request(base + "/feedback")[1]["records"]
        self.assertEqual(len(records), 1)
        self.assertIsNone(records[0]["rating"])
        self.assertEqual(records[0]["provenance"]["coordinator_session_id"], "synthetic-http-coordinator")
        after = self.store.snapshot(feature_id)
        for collection in ("feature", "messages", "events", "visits", "assignments"):
            self.assertEqual(after[collection], before[collection])
        self.assertEqual(self.wakes, wakes)
        self.assertEqual(self.store.pending_messages(feature_id), pending)
        conflict = self.request(base + f"/messages/{reply['id']}/feedback", self.feedback_body(
            rating="down", expected_revision=3, request_id="feedback-clear"))
        self.assertEqual(conflict[0], 409)
        self.assertEqual(conflict[1]["error"]["code"], "idempotency_conflict")

    def test_feedback_rejects_malformed_ineligible_and_cross_feature_requests(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        code, other = self.request("/api/v1/first-mate/features", {
            "title": "Garden lights", "goal": "Plan synthetic garden lighting",
            "cwd": self.temp.name, "request_id": "create-lights"})
        self.assertEqual(code, 201)
        other_id = other["feature"]["id"]
        reply = self.completed_reply(feature_id)
        other_reply = self.completed_reply(other_id, session=None)
        user = self.store.append_human_message(feature_id, "Human direction", "human-feedback")
        base = f"/api/v1/first-mate/features/{feature_id}"
        ineligible = self.request(
            base + f"/messages/{user['id']}/feedback", self.feedback_body(request_id="feedback-user"))
        self.assertEqual(ineligible[0], 409)
        self.assertEqual(ineligible[1]["error"]["code"], "feedback_ineligible")
        cross = self.request(base + f"/messages/{other_reply['id']}/feedback", self.feedback_body(
            request_id="feedback-cross"))
        self.assertEqual(cross[0], 409)
        self.assertEqual(cross[1]["error"]["code"], "feedback_scope_mismatch")
        missing = self.request(base + "/messages/fmm_missing/feedback", self.feedback_body(
            request_id="feedback-missing"))
        self.assertEqual(missing[0], 404)
        malformed = [
            self.feedback_body(rating="yes", request_id="feedback-bad-rating"),
            self.feedback_body(category_ids=["missing"], request_id="feedback-bad-category"),
            self.feedback_body(comment="x" * 4001, request_id="feedback-bad-comment"),
            self.feedback_body(expected_revision=-1, request_id="feedback-bad-revision"),
            {**self.feedback_body(), "extra": True},
            {"rating": "down", "category_ids": [], "comment": "", "expected_revision": 0},
        ]
        for payload in malformed:
            with self.subTest(payload=payload):
                code, body = self.request(base + f"/messages/{reply['id']}/feedback", payload)
                self.assertEqual(code, 400)
                self.assertEqual(body["error"]["code"], "invalid_request")
        self.assertEqual(self.request("/api/v1/first-mate/features/missing/feedback")[0], 404)
        self.assertEqual(
            self.request(f"/api/v1/first-mate/features/{feature_id}/messages/{reply['id']}/feedback", {})[0], 400)

    def test_archived_feature_feedback_remains_readable(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        reply = self.completed_reply(feature_id)
        base = f"/api/v1/first-mate/features/{feature_id}"
        self.request(base + f"/messages/{reply['id']}/feedback", self.feedback_body(
            rating="down", category_ids=["incorrect_assumption"], request_id="feedback-archive"))
        self.request(base + "/actions", {
            "action": "archive", "reason": "no longer relevant", "request_id": "archive-feedback"})
        code, records = self.request(base + "/feedback")
        self.assertEqual(code, 200)
        self.assertEqual(records["records"][0]["rating"], "down")

    def test_feedback_survives_a_companion_restart_and_reconnect(self):
        _, created = self.create()
        feature_id = created["feature"]["id"]
        reply = self.completed_reply(feature_id, session="synthetic-restart-coordinator")
        custom = self.request(
            "/api/v1/first-mate/feedback-categories",
            {"label": "Shorter next time", "request_id": "category-restart"})[1]["category"]
        base = f"/api/v1/first-mate/features/{feature_id}"
        code, saved = self.request(base + f"/messages/{reply['id']}/feedback", self.feedback_body(
            category_ids=["too_long", custom["id"]],
            comment="Kept across a synthetic restart.\nSecond line — naïve ✓",
            request_id="feedback-restart"))
        self.assertEqual(code, 200)
        record = saved["feedback"]

        # A disposable companion restart: stop the handler, close the store,
        # then reopen the same on-disk database and serve it again. This is the
        # HTTP-level companion half of the connected-app persistence check; the
        # Mac relaunch half stays an explicit final-gate step.
        self._restart_companion()

        code, records = self.request(base + "/feedback")
        self.assertEqual(code, 200)
        self.assertEqual(records, {"ok": True, "feature_id": feature_id, "records": [record]})
        code, categories = self.request("/api/v1/first-mate/feedback-categories")
        self.assertEqual(code, 200)
        self.assertIn(custom["id"], [item["id"] for item in categories["categories"]])
        self.assertEqual(saved["feedback"]["provenance"]["coordinator_session_id"], "synthetic-restart-coordinator")

    def _restart_companion(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.store.close()
        self.store = FirstMateStore(Path(self.temp.name) / "work.sqlite3")
        self.service.first_mate_store = self.store
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

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

    def test_links_capability_and_endpoint_are_advertised(self):
        code, top = self.request("/api/v1")
        self.assertEqual(code, 200)
        self.assertIn("first-mate-links-v1", top["capabilities"])
        self.assertEqual(top["endpoints"]["firstMateLinks"], "/api/v1/first-mate/features/{featureId}/links")
        self.assertIn("POST /api/v1/first-mate/features/{featureId}/links", top["mutations"])
        self.assertIn("POST /api/v1/first-mate/features/{featureId}/links/{linkId}/visibility", top["mutations"])
        code, first_mate = self.request("/api/v1/first-mate/capabilities")
        self.assertEqual(code, 200)
        self.assertIn("first-mate-links-v1", first_mate["capabilities"])

    def test_link_save_hide_restore_is_authenticated_idempotent_and_does_not_wake_agents(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/links"
        body = {
            "url": "https://github.com/synthetic-owner/synthetic-repo/pull/12/files#diff-1",
            "title": "Synthetic review",
            "request_id": "link-one",
        }
        for token in (None, "synthetic-ingest-token"):
            self.assertEqual(self.request(path, body, token=token)[0], 401)
        before = self.store.snapshot(identity)
        wakes = list(self.wakes)
        code, result = self.request(path, body)
        self.assertEqual(code, 200)
        self.assertEqual(result["link"]["url"], "https://github.com/synthetic-owner/synthetic-repo/pull/12")
        self.assertEqual(result["link"]["kind"], "pull_request")
        self.assertEqual(result["link"]["title"], "Synthetic review")
        self.assertFalse(result["link"]["hidden"])
        self.assertEqual(result["links"], [result["link"]])
        self.assertEqual(self.wakes, wakes)
        self.assertEqual(self.request(path, body)[1]["link"], result["link"])
        duplicate = {**body, "url": "https://github.com/synthetic-owner/synthetic-repo/pull/12", "request_id": "link-two"}
        code, repeated = self.request(path, duplicate)
        self.assertEqual(code, 200)
        self.assertEqual(repeated["link"]["id"], result["link"]["id"])
        self.assertEqual(len(repeated["links"]), 1)
        code, conflict = self.request(path, {**body, "title": "Different title"})
        self.assertEqual(code, 409)
        self.assertEqual(conflict["error"]["code"], "idempotency_conflict")
        visibility = f"{path}/{result['link']['id']}/visibility"
        code, hidden = self.request(visibility, {"hidden": True, "request_id": "hide-one"})
        self.assertEqual(code, 200)
        self.assertTrue(hidden["link"]["hidden"])
        self.assertTrue(hidden["links"][0]["hidden"])
        self.assertEqual(self.request(visibility, {"hidden": True, "request_id": "hide-one"})[1], hidden)
        code, restored = self.request(visibility, {"hidden": False, "request_id": "restore-one"})
        self.assertEqual(code, 200)
        self.assertFalse(restored["link"]["hidden"])
        after = self.store.snapshot(identity)
        for field in ("status", "revision", "native_session_id", "coordinator_owner"):
            self.assertEqual(after["feature"][field], before["feature"][field])
        for key in ("visits", "assignments", "documents", "messages", "handoffs"):
            self.assertEqual(after[key], before[key])
        self.assertEqual(self.wakes, wakes)

    def test_link_save_round_trips_ipv6_and_folds_github_casing(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/links"
        ipv6 = "https://[2001:db8::42]:8443/review?tab=links#evidence"
        code, saved = self.request(path, {"url": ipv6, "request_id": "link-ipv6"})
        self.assertEqual(code, 200)
        self.assertEqual(saved["link"]["url"], ipv6)
        self.assertEqual(saved["link"]["kind"], "link")
        self.assertEqual(saved["link"]["title"], "[2001:db8::42]")
        code, invalid = self.request(path, {"url": "https://user:secret@[2001:db8::42]/review", "request_id": "link-ipv6-credentials"})
        self.assertEqual(code, 400)
        self.assertEqual(len(self.store.list_links(identity)), 1)

        code, upper = self.request(path, {
            "url": "https://github.com/Synthetic-Owner/Synthetic-Repo/pull/42/files#diff-1",
            "request_id": "link-casing-upper",
        })
        self.assertEqual(code, 200)
        self.assertEqual(upper["link"]["url"], "https://github.com/synthetic-owner/synthetic-repo/pull/42")
        code, lower = self.request(path, {
            "url": "https://github.com/synthetic-owner/synthetic-repo/pull/42",
            "request_id": "link-casing-lower",
        })
        self.assertEqual(code, 200)
        self.assertEqual(lower["link"]["id"], upper["link"]["id"])
        self.assertEqual(len(lower["links"]), 2)
        visibility = f"{path}/{upper['link']['id']}/visibility"
        code, hidden = self.request(visibility, {"hidden": True, "request_id": "hide-casing"})
        self.assertEqual(code, 200)
        self.assertTrue(hidden["link"]["hidden"])
        code, replay = self.request(path, {
            "url": "https://github.com/SYNTHETIC-OWNER/SYNTHETIC-REPO/pull/42",
            "request_id": "link-casing-replay",
        })
        self.assertEqual(code, 200)
        self.assertEqual(replay["link"]["id"], upper["link"]["id"])
        self.assertTrue(replay["link"]["hidden"])
        self.assertEqual(len(self.store.list_links(identity)), 2)

    def test_link_mutations_reject_forged_provenance_cross_feature_ids_and_invalid_inputs(self):
        _, data = self.create()
        identity = data["feature"]["id"]
        _, other = self.request("/api/v1/first-mate/features", {
            "title": "Other synthetic timer", "goal": "Plan a separate synthetic outcome",
            "cwd": self.temp.name, "request_id": "create-other",
        })
        other_id = other["feature"]["id"]
        path = f"/api/v1/first-mate/features/{identity}/links"
        code, saved = self.request(path, {
            "url": "https://share.example.test:8443/private/report?token=synthetic#summary",
            "request_id": "share-one",
        })
        self.assertEqual(code, 200)
        self.assertEqual(saved["link"]["url"], "https://share.example.test:8443/private/report?token=synthetic#summary")
        self.assertEqual(saved["link"]["kind"], "link")
        code, foreign = self.request(f"/api/v1/first-mate/features/{other_id}/links", {
            "url": "https://share.example.test/private/other", "request_id": "share-other",
        })
        self.assertEqual(code, 200)
        invalid = [
            (path, {"url": "javascript:alert(1)", "request_id": "scheme"}, 400),
            (path, {"url": "https://user@example.test/report", "request_id": "credentials"}, 400),
            (path, {"url": "https://example.test:99999/report", "request_id": "port"}, 400),
            (path, {"url": "https://share.example.test/report", "kind": "issue", "request_id": "kind"}, 400),
            (path, {"url": "https://share.example.test/report", "provenance": {"native_session_id": "forged"},
             "request_id": "provenance"}, 400),
            (f"{path}/{saved['link']['id']}/visibility", {"hidden": "yes", "request_id": "hidden"}, 400),
            (f"{path}/{saved['link']['id']}/visibility", {"hidden": True, "request_id": "extra", "provenance": {}}, 400),
            (f"{path}/{foreign['link']['id']}/visibility", {"hidden": True, "request_id": "cross-feature"}, 404),
            (path + "?url=duplicate", {"url": "https://share.example.test/report", "request_id": "query"}, 400),
            ("/api/v1/first-mate/features/fmf_synthetic_missing/links",
             {"url": "https://share.example.test/report", "request_id": "missing"}, 404),
        ]
        for target, body, expected in invalid:
            with self.subTest(target=target, body=body):
                code, result = self.request(target, body)
                self.assertEqual(code, expected)
                self.assertFalse(result["ok"])
        self.assertEqual(len(self.store.snapshot(identity)["links"]), 1)
        self.assertEqual(self.store.snapshot(other_id)["links"][0]["id"], foreign["link"]["id"])


if __name__ == "__main__":
    unittest.main()
