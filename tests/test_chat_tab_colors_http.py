"""Authenticated publication, snapshot projection, and discovery for tab colors."""

import copy
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from herdr_harness.control_store import ControlStore
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "chat-tab-colors-v1.json"
MAIN_TOKEN = "main-synthetic-token"
RECEIVER_TOKEN = "b" * 64
INSTANCE_ID = "33333333-3333-4333-8333-333333333333"
FIXED_TIME = 1893456000.0
SNAPSHOT_TIME = "2030-01-01T00:00:00Z"

PRIMARY = "ui_11111111-1111-4111-8111-111111111111"
SECONDARY = "ui_22222222-2222-4222-8222-222222222222"


class StepClock:
    def __init__(self, value=FIXED_TIME):
        self.value = value

    def __call__(self):
        return self.value


class SyntheticHerdrClient:
    def __init__(self, snapshot):
        self._snapshot = copy.deepcopy(snapshot)
        self.socket_path = "/synthetic/chat-tab-colors.sock"
        self.session = "chat-tab-colors-contract"

    def snapshot(self):
        return copy.deepcopy(self._snapshot)

    def request(self, _method, _parameters):
        raise AssertionError("The tab color contract test must not mutate a real terminal")

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


def synthetic_snapshot():
    tabs = [
        {"tab_id": "ws_synthetic_alpha:t1", "workspace_id": "ws_synthetic_alpha", "label": "Alpha One"},
        {"tab_id": "ws_synthetic_alpha:t2", "workspace_id": "ws_synthetic_alpha", "label": "Alpha Two"},
        {"tab_id": "ws_synthetic_beta:t1", "workspace_id": "ws_synthetic_beta", "label": "Beta One"},
        {"tab_id": "ws_synthetic_beta:t2", "workspace_id": "ws_synthetic_beta", "label": "Beta Two"},
        {"tab_id": "ws_synthetic_gamma:t1", "workspace_id": "ws_synthetic_gamma", "label": "Gamma One"},
    ]
    panes = [
        {
            "pane_id": f"{tab['workspace_id']}:p{index}",
            "terminal_id": f"term_synthetic_{index}",
            "workspace_id": tab["workspace_id"],
            "tab_id": tab["tab_id"],
            "label": f"Synthetic Worker {index}",
            "agent_status": "working",
            "last_activity_at": SNAPSHOT_TIME,
        }
        for index, tab in enumerate(tabs, start=1)
    ]
    return {
        "version": "synthetic-v1",
        "protocol": 19,
        "workspaces": [
            {"workspace_id": "ws_synthetic_alpha", "label": "Synthetic Alpha"},
            {"workspace_id": "ws_synthetic_beta", "label": "Synthetic Beta"},
            {"workspace_id": "ws_synthetic_gamma", "label": "Synthetic Gamma"},
        ],
        "tabs": tabs,
        "panes": panes,
        "agents": [],
        "layouts": [],
    }


class ChatTabColorHTTPTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.clock = StepClock()
        self.store = ControlStore(self.root / "control.sqlite3", clock=self.clock)
        self.service = HerdrService(
            SyntheticHerdrClient(synthetic_snapshot()),
            environ={
                "HOME": str(self.root / "home"),
                "HERDR_STATE_DIR": str(self.root / "state"),
                "HERDR_HARNESS_AGENT_RUNS_ROOT": str(self.root / "agent-runs"),
            },
            pi_semantic=SyntheticPiSemantic(),
            control_store=self.store,
        )
        self.server = make_server(self.service, host="127.0.0.1", port=0, api_token=MAIN_TOKEN)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.addCleanup(self.stop)
        self.server_id = self.store.server_id

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.service.stop()
        self.store.close()

    def request(self, path, *, method="GET", payload=None, token=MAIN_TOKEN):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"} if data is not None else {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(self.base + path, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def publication(self, key, **overrides):
        body = copy.deepcopy(self.fixture["publications"][key])
        body["serverId"] = self.server_id
        body.update(overrides)
        return body

    def publish(self, key, **overrides):
        return self.request(
            f"/api/v1/control/chat-tab-colors/{self.fixture['clients'][key]['clientId']}",
            method="POST",
            payload=self.publication(key, **overrides),
        )

    def snapshot_colors(self):
        status, body = self.request("/api/v1/snapshot")
        self.assertEqual(status, 200)
        return {tab["tab_id"]: tab["chatTabColors"] for tab in body["snapshot"]["tabs"]}, body

    def test_capabilities_advertise_the_contract(self):
        description = self.request("/api/v1")[1]
        self.assertIn("chat-tab-colors-v1", description["capabilities"])
        self.assertEqual(
            description["endpoints"]["chatTabColors"],
            "/api/v1/control/chat-tab-colors/{clientId}",
        )
        status, body = self.request("/api/v1/control/capabilities")
        self.assertEqual(status, 200)
        self.assertEqual(
            body["capabilities"],
            ["agent-control-v1", "discovery-v1", "chat-tab-colors-v1"],
        )
        self.assertEqual(body["chatTabColorStaleAfterSeconds"], 60)

    def test_snapshot_reports_empty_color_metadata_before_any_publication(self):
        status, body = self.request("/api/v1/snapshot")
        self.assertEqual(status, 200)
        self.assertEqual(body["chatTabColorSources"], [])
        for tab in body["snapshot"]["tabs"]:
            self.assertEqual(tab["chatTabColors"], [])

    def test_publication_auth_binding_spoofing_and_encoded_routes(self):
        status, body = self.request(
            f"/api/v1/control/chat-tab-colors/{PRIMARY}",
            method="POST",
            payload=self.publication("primary"),
            token=None,
        )
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

        encoded = f"/api/v1/%63ontrol/chat-tab-colors/{PRIMARY}"
        status, body = self.request(encoded, method="POST", payload=self.publication("primary"))
        self.assertEqual(status, 200)
        self.assertNotIn("publisherToken", json.dumps(body))
        self.assertEqual(body["publication"]["clientId"], PRIMARY)
        self.assertEqual(body["publication"]["revision"], 7)
        self.assertEqual(body["publication"]["tabCount"], 4)
        self.assertEqual(body["publication"]["updatedAt"], "2030-01-01T00:00:00Z")

        status, body = self.request(
            f"/api/v1/control/chat-tab-colors/{PRIMARY}",
            method="POST",
            payload=self.publication("primary", publisherToken="f" * 64, revision=8),
        )
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "publisher_unauthorized")

        status, body = self.request(
            f"/api/v1/control/chat-tab-colors/{SECONDARY}",
            method="POST",
            payload=self.publication("primary", serverId="srv_99999999-9999-4999-8999-999999999999"),
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "stale_target")

        for invalid in (
            {**self.publication("primary"), "unknown": True},
            {**self.publication("primary"), "revision": 0},
            {**self.publication("primary"), "publisherToken": "short"},
            {**self.publication("primary"), "enabled": False},
            {**self.publication("primary"), "tabs": [{"workspaceId": "w1", "tabId": "w1:t1", "color": "purple", "label": "x"}]},
            {**self.publication("primary"), "tabs": [{"workspaceId": "w1", "tabId": "w1:t1", "color": "sage"}]},
        ):
            with self.subTest(body=invalid):
                status, _ = self.request(
                    f"/api/v1/control/chat-tab-colors/{PRIMARY}",
                    method="POST",
                    payload=invalid,
                )
                self.assertEqual(status, 400)

        with patch("herdr_harness.chat_tab_colors.MAX_CHAT_TAB_ENTRIES", 1):
            status, body = self.request(
                f"/api/v1/control/chat-tab-colors/{PRIMARY}",
                method="POST",
                payload=self.publication(
                    "primary",
                    revision=9,
                    tabs=[
                        {"workspaceId": "ws_synthetic_alpha", "tabId": "ws_synthetic_alpha:t1", "color": "sage", "label": "One"},
                        {"workspaceId": "ws_synthetic_alpha", "tabId": "ws_synthetic_alpha:t2", "color": "sage", "label": "One"},
                    ],
                ),
            )
        self.assertEqual(status, 413)
        self.assertEqual(body["error"]["code"], "publication_too_large")

        with patch("herdr_harness.control_store.MAX_CHAT_TAB_PUBLISHERS", 1):
            status, body = self.publish("secondary")
        self.assertEqual(status, 503)
        self.assertEqual(body["error"]["code"], "publisher_capacity")

    def test_snapshot_projects_entries_sources_and_staleness(self):
        self.assertEqual(self.publish("primary")[0], 200)
        self.assertEqual(self.publish("secondary")[0], 200)

        colors, body = self.snapshot_colors()
        self.assertEqual(body["chatTabColorSources"], self.fixture["expected"]["sources"])
        for key, expected in self.fixture["expected"]["tabs"].items():
            self.assertEqual(colors[key], expected, key)
        self.assertEqual(
            [entry["status"] for entry in colors["ws_synthetic_gamma:t1"]],
            ["unavailable", "unavailable"],
        )
        # Presentation metadata never enters a typed pane object.
        for pane in body["snapshot"]["panes"]:
            self.assertNotIn("chatTabColors", pane)

        self.clock.value += 61
        stale_colors, stale_body = self.snapshot_colors()
        self.assertTrue(all(entry["stale"] for entry in stale_colors["ws_synthetic_alpha:t1"]))
        self.assertTrue(all(source["stale"] for source in stale_body["chatTabColorSources"]))
        self.assertEqual(stale_colors["ws_synthetic_alpha:t1"][0]["color"], "sage")

    def test_two_servers_reuse_raw_tab_ids_without_cross_contamination(self):
        second_store = ControlStore(self.root / "control-second.sqlite3", clock=self.clock)
        self.addCleanup(second_store.close)
        second_service = HerdrService(
            SyntheticHerdrClient(synthetic_snapshot()),
            environ={},
            pi_semantic=SyntheticPiSemantic(),
            control_store=second_store,
        )
        second_server = make_server(second_service, host="127.0.0.1", port=0, api_token=MAIN_TOKEN)
        second_thread = threading.Thread(target=second_server.serve_forever, daemon=True)
        second_thread.start()
        second_base = f"http://127.0.0.1:{second_server.server_address[1]}"
        try:
            body = copy.deepcopy(self.fixture["publications"]["secondary"])
            body["serverId"] = second_store.server_id
            request = urllib.request.Request(
                second_base + f"/api/v1/control/chat-tab-colors/{SECONDARY}",
                method="POST",
                data=json.dumps(body).encode("utf-8"),
                headers={"Content-Type": "application/json", "Authorization": f"Bearer {MAIN_TOKEN}"},
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertEqual(response.status, 200)

            first_status, first_body = self.request("/api/v1/snapshot")
            second_request = urllib.request.Request(
                second_base + "/api/v1/snapshot",
                headers={"Authorization": f"Bearer {MAIN_TOKEN}"},
            )
            with urllib.request.urlopen(second_request, timeout=5) as response:
                second_body = json.loads(response.read())
        finally:
            second_server.shutdown()
            second_server.server_close()
            second_thread.join(timeout=2)
            second_service.stop()

        self.assertEqual(first_status, 200)
        self.assertEqual(
            [source["clientId"] for source in first_body["chatTabColorSources"]], []
        )
        self.assertEqual(
            [source["clientId"] for source in second_body["chatTabColorSources"]], [SECONDARY]
        )
        second_tab = next(
            tab for tab in second_body["snapshot"]["tabs"] if tab["tab_id"] == "ws_synthetic_alpha:t1"
        )
        self.assertEqual(second_tab["chatTabColors"][0]["color"], "rose")

    def test_insecure_loopback_snapshot_never_exposes_publications(self):
        status, _ = self.publish("primary")
        self.assertEqual(status, 200)
        open_server = make_server(self.service, host="127.0.0.1", port=0, api_token="")
        open_thread = threading.Thread(target=open_server.serve_forever, daemon=True)
        open_thread.start()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{open_server.server_address[1]}/api/v1/snapshot"
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                body = json.loads(response.read())
                self.assertEqual(response.status, 200)
        finally:
            open_server.shutdown()
            open_server.server_close()
            open_thread.join(timeout=2)
        self.assertNotIn("chatTabColorSources", body)
        for tab in body["snapshot"]["tabs"]:
            self.assertNotIn("chatTabColors", tab)

    def test_discovery_filters_same_entry_before_pagination_and_scope(self):
        self.assertEqual(self.publish("primary")[0], 200)
        self.assertEqual(self.publish("secondary")[0], 200)

        status, body = self.request(
            "/api/v1/discovery?kind=chats&color=sage&colorLabel=Synthetic%20Release%20Group"
            f"&colorClientId={PRIMARY}"
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            sorted(item["id"] for item in body["results"]),
            ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2"],
        )
        pane = body["results"][0]
        self.assertNotIn("chatTabColors", pane["target"])
        self.assertEqual(
            [entry["status"] for entry in pane["chatTabColors"]],
            ["assigned", "assigned"],
        )
        self.assertEqual(
            body["coverage"]["chatTabColors"], self.fixture["expected"]["coverage"]
        )

        status, first_page = self.request("/api/v1/discovery?kind=chats&color=sage&limit=1&offset=0")
        self.assertEqual(status, 200)
        self.assertEqual(len(first_page["results"]), 1)
        self.assertEqual(first_page["nextOffset"], 1)
        status, second_page = self.request("/api/v1/discovery?kind=chats&color=sage&limit=1&offset=1")
        self.assertEqual(status, 200)
        self.assertEqual(len(second_page["results"]), 1)
        self.assertNotEqual(
            first_page["results"][0]["id"], second_page["results"][0]["id"]
        )

        # Predicates must match one entry: the secondary client has no sage entry.
        status, body = self.request(
            f"/api/v1/discovery?kind=chats&color=sage&colorClientId={SECONDARY}"
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["results"], [])

        status, body = self.request(f"/api/v1/discovery?kind=chats&colorClientId={SECONDARY}")
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in body["results"]], ["ws_synthetic_alpha:p1"])

        status, body = self.request("/api/v1/discovery?kind=tabs&color=none")
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in body["results"]], ["ws_synthetic_beta:t2"])

        status, body = self.request(
            "/api/v1/discovery?kind=chats&colorLabel=SYNTHES%C3%89%20%E2%9C%A6%20Planning"
        )
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in body["results"]], ["ws_synthetic_beta:p3"])

        status, body = self.request(
            "/api/v1/discovery?kind=chats&q=Synthetic%20Release%20Group&color=sage"
        )
        self.assertEqual(status, 200)
        self.assertIn(
            "tabColorLabel",
            {item["field"] for item in body["results"][0]["matchEvidence"]},
        )

    def test_discovery_chat_scope_excludes_saved_hud_chats(self):
        saved = {
            "ok": True,
            "chats": [
                {
                    "id": "agr_000000000001",
                    "title": "Synthetic Saved Chat",
                    "updatedAt": "2030-01-01T00:00:00Z",
                    "status": "completed",
                }
            ],
            "nextOffset": None,
        }
        with patch("herdr_harness.hud_chats.catalog", return_value=saved):
            status, body = self.request("/api/v1/discovery?kind=chats&q=Synthetic%20Saved")
            self.assertEqual(status, 200)
            self.assertIn("hud-chat", {item["kind"] for item in body["results"]})
            status, scoped = self.request(
                "/api/v1/discovery?kind=chats&q=Synthetic%20Saved&chatScope=terminal"
            )
        self.assertEqual(status, 200)
        self.assertNotIn("hud-chat", {item["kind"] for item in scoped["results"]})

    def test_discovery_rejects_invalid_color_parameters(self):
        for query in (
            "kind=chats&color=purple",
            "kind=chats&colorLabel=%20",
            "kind=chats&colorClientId=not-a-client",
            "kind=chats&chatScope=all",
            "kind=chats&color=sage&color=rose",
        ):
            with self.subTest(query=query):
                status, body = self.request(f"/api/v1/discovery?{query}")
                self.assertEqual(status, 400)
                self.assertEqual(body["error"]["code"], "invalid_request")

    def test_inspect_propagates_entries_and_keeps_typed_targets(self):
        self.assertEqual(self.publish("primary")[0], 200)
        target = {
            "kind": "pane",
            "workspaceId": "ws_synthetic_alpha",
            "tabId": "ws_synthetic_alpha:t1",
            "paneId": "ws_synthetic_alpha:p1",
        }
        status, body = self.request(
            "/api/v1/control/inspect", method="POST", payload={"target": target}
        )
        self.assertEqual(status, 200)
        result = body["result"]
        self.assertEqual(result["target"]["paneId"], "ws_synthetic_alpha:p1")
        self.assertEqual(result["chatTabColors"][0]["status"], "assigned")
        self.assertNotIn("chatTabColors", result["target"])

    def test_disabled_publication_cannot_be_restored_by_a_delayed_revision(self):
        self.assertEqual(self.publish("primary")[0], 200)
        self.clock.value += 10
        disabled = self.publication("primary", enabled=False, revision=8, tabs=[])
        status, _ = self.request(
            f"/api/v1/control/chat-tab-colors/{PRIMARY}", method="POST", payload=disabled
        )
        self.assertEqual(status, 200)
        colors, body = self.snapshot_colors()
        entry = colors["ws_synthetic_alpha:t1"][0]
        self.assertEqual(entry["status"], "unavailable")
        self.assertIsNone(entry["color"])
        self.assertEqual(body["chatTabColorSources"][0]["enabled"], False)

        self.clock.value += 10
        status, body = self.publish("primary")
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "stale_publication_revision")
        self.assertEqual(self.snapshot_colors()[0]["ws_synthetic_alpha:t1"][0]["status"], "unavailable")

    def test_relay_tab_color_action_is_disabled_and_rejected(self):
        action = {
            "id": "chat.tab-color",
            "title": "Set tab color",
            "parameters": {
                "type": "object",
                "properties": {"color": {"type": "string", "enum": ["sage", "none"]}},
                "required": ["color"],
                "additionalProperties": False,
            },
            "targetKinds": ["pane", "tab"],
            "effect": "mutation",
            "enabled": True,
        }
        status, _ = self.request(
            "/api/v1/ui/clients/register",
            method="POST",
            payload={
                "clientId": PRIMARY,
                "name": "Synthetic Companion",
                "receiverToken": RECEIVER_TOKEN,
                "instanceId": INSTANCE_ID,
                "state": {"revision": 1, "window": "main", "segment": "chat", "enabled": True},
                "actions": [action],
            },
        )
        self.assertEqual(status, 200)
        status, body = self.request(f"/api/v1/ui/clients/{PRIMARY}/actions")
        self.assertEqual(status, 200)
        descriptor = body["actions"][0]
        self.assertFalse(descriptor["enabled"])
        self.assertIn("read-only", descriptor["disabledReason"])

        status, body = self.request(
            f"/api/v1/ui/clients/{PRIMARY}/commands",
            method="POST",
            payload={
                "requestId": "tab-color-1",
                "action": "chat.tab-color",
                "target": {
                    "kind": "pane",
                    "workspaceId": "ws_synthetic_alpha",
                    "tabId": "ws_synthetic_alpha:t1",
                    "paneId": "ws_synthetic_alpha:p1",
                },
                "parameters": {"color": "sage"},
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "action_disabled")

        status, body = self.request(
            "/api/v1/control/actions",
            method="POST",
            payload={
                "requestId": "tab-color-2",
                "action": "chat.tab-color",
                "parameters": {"color": "sage"},
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "action_disabled")
