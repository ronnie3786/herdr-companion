import json
import threading
import unittest
import urllib.error
import urllib.request

from herdr_harness.control_store import ControlStore
from herdr_harness.server import make_server


MAIN_TOKEN = "main-synthetic-token"
SCOPED_TOKEN = "active-work-synthetic-token"
CLIENT_ID = "ui_11111111-1111-4111-8111-111111111111"
INSTANCE_ID = "22222222-2222-4222-8222-222222222222"
RECEIVER_TOKEN = "a" * 64
STATE = {"revision": 4, "window": "main", "segment": "chat", "enabled": True}
ACTIONS = [
    {
        "id": "ui.open",
        "title": "Open",
        "parameters": {
            "type": "object",
            "properties": {"view": {"type": "string", "enum": ["chat", "terminal"]}},
            "required": ["view"],
            "additionalProperties": False,
        },
        "targetKinds": ["pane"],
        "effect": "navigation",
        "enabled": True,
    }
]
TARGET = {
    "kind": "pane",
    "workspaceId": "w1",
    "tabId": "t1",
    "paneId": "p1",
    "terminalId": "term-1",
    "sessionId": "session-1",
}


class FakeResources:
    def actions(self):
        return []


class FakeHTTPControlService:
    def __init__(self, environ=None):
        self.environ = dict(environ or {})
        self.control_store = ControlStore(":memory:")
        self.control_resources = FakeResources()


class ControlHTTPTests(unittest.TestCase):
    def start_server(self, *, api_token, environ=None):
        service = FakeHTTPControlService(environ)
        server = make_server(service, host="127.0.0.1", port=0, api_token=api_token)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def cleanup():
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)
            service.control_store.close()

        self.addCleanup(cleanup)
        return service, f"http://127.0.0.1:{server.server_address[1]}"

    def request(self, base, path, *, method="GET", payload=None, token=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"} if data is not None else {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(base + path, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_control_requires_full_bearer_not_active_work_scope(self):
        _, base = self.start_server(
            api_token=MAIN_TOKEN,
            environ={"HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": SCOPED_TOKEN},
        )
        path = "/api/v1/control/capabilities"
        self.assertEqual(self.request(base, path)[0], 401)
        self.assertEqual(self.request(base, path, token=SCOPED_TOKEN)[0], 401)
        status, body = self.request(base, path, token=MAIN_TOKEN)
        self.assertEqual(status, 200)
        self.assertEqual(body["capabilities"], ["agent-control-v1", "discovery-v1"])
        self.assertTrue(body["serverId"].startswith("srv_"))

    def test_control_stays_closed_when_legacy_insecure_local_mode_is_open(self):
        _, base = self.start_server(api_token="")
        self.assertEqual(self.request(base, "/api/v1/control/capabilities")[0], 401)
        self.assertEqual(self.request(base, "/api/v1/%63ontrol/capabilities")[0], 401)
        self.assertEqual(self.request(base, "/api/v1/%75i/clients")[0], 401)

    def test_encoded_control_segments_reject_scoped_credentials(self):
        _, base = self.start_server(
            api_token=MAIN_TOKEN,
            environ={"HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": SCOPED_TOKEN},
        )
        self.assertEqual(
            self.request(base, "/api/v1/%63ontrol/capabilities", token=SCOPED_TOKEN)[0],
            401,
        )
        self.assertEqual(self.request(base, "/api/v1/%75i/clients", token=SCOPED_TOKEN)[0], 401)

    def test_receiver_registration_command_poll_and_idempotent_result(self):
        _, base = self.start_server(api_token=MAIN_TOKEN)
        registration = {
            "clientId": CLIENT_ID,
            "name": "Synthetic Companion",
            "receiverToken": RECEIVER_TOKEN,
            "instanceId": INSTANCE_ID,
            "state": STATE,
            "actions": ACTIONS,
        }
        status, registered = self.request(
            base,
            "/api/v1/ui/clients/register",
            method="POST",
            payload=registration,
            token=MAIN_TOKEN,
        )
        self.assertEqual(status, 200)
        self.assertNotIn("receiverToken", json.dumps(registered))

        command_body = {
            "requestId": "open-1",
            "action": "ui.open",
            "target": TARGET,
            "parameters": {"view": "chat"},
            "expectedRevision": 4,
            "ttlSeconds": 30,
        }
        status, accepted = self.request(
            base,
            f"/api/v1/ui/clients/{CLIENT_ID}/commands",
            method="POST",
            payload=command_body,
            token=MAIN_TOKEN,
        )
        self.assertEqual(status, 200)
        self.assertEqual(accepted["command"]["status"], "accepted")

        poll = {
            "receiverToken": RECEIVER_TOKEN,
            "instanceId": INSTANCE_ID,
            "state": STATE,
        }
        status, claimed = self.request(
            base,
            f"/api/v1/ui/clients/{CLIENT_ID}/poll",
            method="POST",
            payload=poll,
            token=MAIN_TOKEN,
        )
        self.assertEqual(status, 200)
        self.assertEqual(claimed["command"]["status"], "running")

        receipt = {
            "receiverToken": RECEIVER_TOKEN,
            "instanceId": INSTANCE_ID,
            "status": "completed",
            "result": {"presentation": "main"},
            "state": {**STATE, "revision": 5},
        }
        path = f"/api/v1/ui/clients/{CLIENT_ID}/commands/open-1/result"
        first = self.request(base, path, method="POST", payload=receipt, token=MAIN_TOKEN)
        second = self.request(
            base,
            path,
            method="POST",
            payload={**receipt, "state": {**STATE, "revision": 6, "segment": "git"}},
            token=MAIN_TOKEN,
        )
        self.assertEqual(first, second)
        self.assertEqual(first[1]["command"]["status"], "completed")

    def test_registration_and_commands_reject_unknown_fields_and_schema_errors(self):
        _, base = self.start_server(api_token=MAIN_TOKEN)
        registration = {
            "clientId": CLIENT_ID,
            "name": "Synthetic Companion",
            "receiverToken": RECEIVER_TOKEN,
            "instanceId": INSTANCE_ID,
            "state": STATE,
            "actions": ACTIONS,
            "secretDraft": "must not be accepted",
        }
        self.assertEqual(
            self.request(
                base,
                "/api/v1/ui/clients/register",
                method="POST",
                payload=registration,
                token=MAIN_TOKEN,
            )[0],
            400,
        )
