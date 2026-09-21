from __future__ import annotations

import copy
import io
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

from herdr_harness import control_cli
from herdr_harness.control_store import ControlStore
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "agent-control-v1.json"
CHAT_TAB_COLOR_FIXTURE_PATH = Path(__file__).parent / "fixtures" / "chat-tab-colors-v1.json"


class SyntheticHerdrClient:
    def __init__(self, snapshot):
        self._snapshot = copy.deepcopy(snapshot)
        self.socket_path = "/synthetic/herdr.sock"
        self.session = "agent-control-contract"

    def snapshot(self):
        return copy.deepcopy(self._snapshot)

    def request(self, _method, _parameters):
        raise AssertionError("The wire contract test must not mutate a real Herdr terminal")

    def subscribe_forever(self, *_args, **_kwargs):
        return None


class SyntheticPiSemantic:
    def sync_snapshot(self, _snapshot):
        return None

    def enrich_snapshot(self, snapshot):
        return copy.deepcopy(snapshot)

    def session_label_checkpoint(self, _pane_id):
        return None

    def snapshot_response(self, _pane_id):
        return {"ok": True, "snapshot": {"entries": []}}

    def stop(self):
        return None


class StepClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value

    def sleep(self, duration):
        self.value += max(float(duration), 0.25)


def request_json(opener, url, *, method="GET", payload=None, token):
    data = None if payload is None else json.dumps(payload, sort_keys=True).encode("utf-8")
    headers = {"Accept": "application/json", "Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, method=method, data=data, headers=headers)
    try:
        with opener.open(request, timeout=2) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        with error:
            return error.code, json.loads(error.read())


def materialize(value, server_url):
    if isinstance(value, str):
        return value.replace("${SERVER_URL}", server_url)
    if isinstance(value, list):
        return [materialize(item, server_url) for item in value]
    if isinstance(value, dict):
        return {key: materialize(item, server_url) for key, item in value.items()}
    return value


class CompletingLoopbackOpener:
    """Completes one receiver command after the real enqueue response is available."""

    def __init__(self, test_case):
        self.test_case = test_case
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.requests = []
        self.did_complete = False

    def __call__(self, request, *, timeout):
        parsed = urllib.parse.urlsplit(request.full_url)
        body = json.loads(request.data) if request.data is not None else None
        self.requests.append((request.get_method(), parsed.path, body))
        response = self.opener.open(request, timeout=timeout)
        if (
            not self.did_complete
            and request.get_method() == "POST"
            and parsed.path.endswith("/commands")
            and "/api/v1/ui/clients/" in parsed.path
        ):
            self.did_complete = True
            self.test_case.complete_receiver_command()
        return response


class AgentControlWireContractTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.http_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        identifiers = self.fixture["identifiers"]
        self.assertEqual(uuid.UUID(identifiers["clientId"][3:]).version, 4)
        self.assertEqual(uuid.UUID(identifiers["instanceId"]).version, 4)
        self.assertEqual(uuid.UUID(identifiers["sessionId"]).version, 4)
        self.assertEqual(uuid.UUID(self.fixture["serverId"][4:]).version, 4)
        self.assertEqual(len(self.fixture["receiverToken"]), 64)
        self.assertNotIn("generation", self.fixture["target"])
        self.assertGreaterEqual(len(self.fixture["apiBearer"]), 48)

        self.control_store = ControlStore(
            self.root / "control.sqlite3",
            clock=lambda: float(self.fixture["fixedUnixTime"]),
        )
        # A stable server identity makes every expected response an exact shared fixture.
        with self.control_store._lock:
            self.control_store._db.execute(
                "UPDATE control_meta SET value=? WHERE key='server_id'",
                (self.fixture["serverId"],),
            )

        target = self.fixture["target"]
        current_timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        snapshot = {
            "version": "synthetic-v1",
            "protocol": 19,
            "focused_workspace_id": target["workspaceId"],
            "focused_tab_id": target["tabId"],
            "focused_pane_id": target["paneId"],
            "workspaces": [
                {
                    "workspace_id": target["workspaceId"],
                    "label": "Synthetic Contract Workspace",
                    "cwd": "/synthetic/agent-control",
                    "agent_status": "working",
                    "last_activity_at": current_timestamp,
                }
            ],
            "tabs": [
                {
                    "tab_id": target["tabId"],
                    "workspace_id": target["workspaceId"],
                    "label": "Synthetic Contract Tab",
                    "agent_status": "working",
                    "last_activity_at": current_timestamp,
                }
            ],
            "panes": [
                {
                    "pane_id": target["paneId"],
                    "terminal_id": target["terminalId"],
                    "workspace_id": target["workspaceId"],
                    "tab_id": target["tabId"],
                    "label": "Synthetic Contract Pane",
                    "agent_status": "working",
                    "last_activity_at": current_timestamp,
                    "pi_semantic": {
                        "connected": True,
                        "session_id": identifiers["sessionId"],
                    },
                }
            ],
            "agents": [],
            "layouts": [],
        }
        environment = {
            "HOME": str(self.root),
            "HERDR_STATE_DIR": str(self.root / "state"),
            "HERDR_HARNESS_AGENT_RUNS_ROOT": str(self.root / "agent-runs"),
        }
        self.service = HerdrService(
            SyntheticHerdrClient(snapshot),
            environ=environment,
            pi_semantic=SyntheticPiSemantic(),
            control_store=self.control_store,
        )
        self.server = make_server(
            self.service,
            host="127.0.0.1",
            port=0,
            api_token=self.fixture["apiBearer"],
        )
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.server_url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.addCleanup(self.stop_server)

        self.config = self.root / "config.toml"
        self.config.write_text(
            "\n".join(
                [
                    "version = 1",
                    "[machines.cli-alias]",
                    'name = "Synthetic CLI Alias"',
                    f'url = "{self.server_url}"',
                    "[machines.cli-alias.server]",
                    f'api_token = "{self.fixture["apiBearer"]}"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.config.chmod(0o600)
        status, registration = request_json(
            self.http_opener,
            self.server_url + "/api/v1/ui/clients/register",
            method="POST",
            payload=self.fixture["registration"],
            token=self.fixture["apiBearer"],
        )
        self.assertEqual(status, 200)
        self.assertTrue(registration["ok"])
        self.assertEqual(registration["serverId"], self.fixture["serverId"])
        self.assertNotIn("receiverToken", json.dumps(registration))

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2)
        self.service.stop()
        self.control_store.close()

    def run_cli(self, arguments, opener):
        stdout, stderr = io.StringIO(), io.StringIO()
        clock = StepClock()
        status = control_cli.main(
            ["--config", str(self.config), *arguments],
            environ={"HOME": str(self.root)},
            stdin=io.StringIO(),
            stdout=stdout,
            stderr=stderr,
            opener=opener,
            clock=clock,
            sleep=clock.sleep,
        )
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        error = json.loads(stderr.getvalue()) if stderr.getvalue() else None
        return status, output, error

    def complete_receiver_command(self):
        token = self.fixture["apiBearer"]
        client_id = self.fixture["identifiers"]["clientId"]
        status, claimed = request_json(
            self.http_opener,
            self.server_url + f"/api/v1/ui/clients/{client_id}/poll",
            method="POST",
            payload=self.fixture["poll"],
            token=token,
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            claimed,
            {"ok": True, "command": materialize(self.fixture["claimedCommand"], self.server_url)},
        )
        self.assertNotIn("receiverToken", json.dumps(claimed))

        request_id = self.fixture["identifiers"]["requestId"]
        status, acknowledged = request_json(
            self.http_opener,
            self.server_url
            + f"/api/v1/ui/clients/{client_id}/commands/{request_id}/result",
            method="POST",
            payload=self.fixture["acknowledgement"],
            token=token,
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            acknowledged,
            {"ok": True, "command": materialize(self.fixture["completedCommand"], self.server_url)},
        )
        self.assertNotIn("receiverToken", json.dumps(acknowledged))

    def test_cli_exact_pane_open_completes_through_real_relay(self):
        opener = CompletingLoopbackOpener(self)
        status, output, error = self.run_cli(
            [
                "--machine",
                "cli-alias",
                "--control-machine",
                "cli-alias",
                "ui",
                "open",
                "--pane",
                self.fixture["target"]["paneId"],
                "--view",
                "git",
                "--client",
                self.fixture["identifiers"]["clientId"],
                "--expected-revision",
                "7",
                "--request-id",
                self.fixture["identifiers"]["requestId"],
                "--wait",
                "1",
            ],
            opener,
        )
        self.assertEqual(status, 0, error)
        self.assertIsNone(error)
        self.assertEqual(
            output["command"],
            materialize(self.fixture["completedCommand"], self.server_url),
        )
        self.assertEqual(output["requestId"], self.fixture["identifiers"]["requestId"])
        self.assertNotIn(self.fixture["apiBearer"], json.dumps(output))
        self.assertTrue(opener.did_complete)

        paths = [(method, path) for method, path, _body in opener.requests]
        self.assertEqual(paths[0], ("POST", "/api/v1/control/inspect"))
        self.assertEqual(paths[1], ("GET", "/api/v1/ui/clients"))
        self.assertEqual(
            paths[2],
            (
                "POST",
                f"/api/v1/ui/clients/{self.fixture['identifiers']['clientId']}/commands",
            ),
        )
        self.assertEqual(
            paths[3],
            ("GET", f"/api/v1/ui/commands/{self.fixture['identifiers']['requestId']}"),
        )
        command_body = opener.requests[2][2]
        self.assertEqual(command_body["target"]["serverId"], self.fixture["serverId"])
        self.assertEqual(command_body["target"]["machineId"], "cli-alias")
        self.assertEqual(
            self.fixture["registration"]["state"]["selection"]["machineId"],
            "native-alias",
        )

    def test_same_pane_with_different_terminal_is_rejected_before_enqueue(self):
        stale_target = copy.deepcopy(self.fixture["target"])
        stale_target["terminalId"] = "term_reused"
        reference = self.root / "stale-target.json"
        reference.write_text(json.dumps(stale_target), encoding="utf-8")
        opener = CompletingLoopbackOpener(self)

        status, output, error = self.run_cli(
            [
                "--machine",
                "cli-alias",
                "--control-machine",
                "cli-alias",
                "ui",
                "open",
                "--ref-file",
                str(reference),
                "--view",
                "git",
                "--client",
                self.fixture["identifiers"]["clientId"],
                "--request-id",
                "contract-stale-pane",
            ],
            opener,
        )
        self.assertNotEqual(status, 0)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "stale_target")
        self.assertEqual(
            [(method, path) for method, path, _body in opener.requests],
            [("POST", "/api/v1/control/inspect")],
        )
        self.assertFalse(opener.did_complete)

    def test_forged_receiver_secret_is_rejected(self):
        forged_poll = copy.deepcopy(self.fixture["poll"])
        forged_poll["receiverToken"] = "f" + forged_poll["receiverToken"][1:]
        client_id = self.fixture["identifiers"]["clientId"]
        status, response = request_json(
            self.http_opener,
            self.server_url + f"/api/v1/ui/clients/{client_id}/poll",
            method="POST",
            payload=forged_poll,
            token=self.fixture["apiBearer"],
        )
        self.assertEqual(status, 401)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "receiver_unauthorized")
        self.assertNotIn(self.fixture["receiverToken"], json.dumps(response))

    def test_chat_tab_color_publication_snapshot_and_discovery_contract(self):
        colors = json.loads(CHAT_TAB_COLOR_FIXTURE_PATH.read_text(encoding="utf-8"))
        client = colors["clients"]["primary"]
        target = self.fixture["target"]
        request_body = {
            "serverId": colors["serverId"],
            "publisherToken": client["publisherToken"],
            "platform": client["platform"],
            "clientName": client["clientName"],
            "enabled": True,
            "revision": colors["publications"]["primary"]["revision"],
            "tabs": [
                {
                    "workspaceId": target["workspaceId"],
                    "tabId": target["tabId"],
                    "color": "sage",
                    "label": colors["labels"]["shared"],
                }
            ],
        }
        path = f"/api/v1/control/chat-tab-colors/{client['clientId']}"
        status, registered = request_json(
            self.http_opener,
            self.server_url + path,
            method="POST",
            payload=request_body,
            token=self.fixture["apiBearer"],
        )
        self.assertEqual(status, 200)
        self.assertEqual(registered["serverId"], self.fixture["serverId"])
        self.assertEqual(
            registered["publication"],
            {
                "clientId": client["clientId"],
                "platform": "macos",
                "clientName": client["clientName"],
                "enabled": True,
                "revision": 7,
                "tabCount": 1,
                "updatedAt": colors["expected"]["publishedAt"],
                "lastSeenAt": colors["expected"]["publishedAt"],
                "stale": False,
            },
        )
        self.assertNotIn("publisherToken", json.dumps(registered))
        self.assertNotIn(client["publisherToken"], json.dumps(registered))

        status, snapshot = request_json(
            self.http_opener, self.server_url + "/api/v1/snapshot", token=self.fixture["apiBearer"]
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            snapshot["chatTabColorSources"],
            [
                {
                    "clientId": client["clientId"],
                    "platform": "macos",
                    "clientName": client["clientName"],
                    "enabled": True,
                    "revision": 7,
                    "updatedAt": colors["expected"]["publishedAt"],
                    "lastSeenAt": colors["expected"]["publishedAt"],
                    "stale": False,
                }
            ],
        )
        tab = next(
            item for item in snapshot["snapshot"]["tabs"] if item["tab_id"] == target["tabId"]
        )
        self.assertEqual(
            tab["chatTabColors"],
            [
                {
                    "clientId": client["clientId"],
                    "color": "sage",
                    "label": colors["labels"]["shared"],
                    "status": "assigned",
                    "updatedAt": colors["expected"]["publishedAt"],
                    "lastSeenAt": colors["expected"]["publishedAt"],
                    "stale": False,
                }
            ],
        )
        self.assertEqual(tab["label"], "Synthetic Contract Tab")
        self.assertNotIn("chatTabColors", snapshot["snapshot"]["panes"][0])

        status, discovery = request_json(
            self.http_opener,
            self.server_url + "/api/v1/discovery?kind=chats&color=sage",
            token=self.fixture["apiBearer"],
        )
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in discovery["results"]], [target["paneId"]])
        result = discovery["results"][0]
        self.assertEqual(result["chatTabColors"][0]["label"], colors["labels"]["shared"])
        self.assertEqual(result["target"]["paneId"], target["paneId"])
        self.assertNotIn("chatTabColors", result["target"])
        self.assertTrue(discovery["coverage"]["chatTabColors"]["searched"])

        status, capabilities = request_json(
            self.http_opener,
            self.server_url + "/api/v1/control/capabilities",
            token=self.fixture["apiBearer"],
        )
        self.assertEqual(status, 200)
        self.assertIn("chat-tab-colors-v1", capabilities["capabilities"])


if __name__ == "__main__":
    unittest.main()
