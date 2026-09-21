"""Synthetic loopback integration for tab color discovery (issue #27).

This suite publishes the shared ``chat-tab-colors-v1`` fixture to real companion
HTTP routes and invokes both installed CLI entry points against them. It is
deliberately separate from the unit suites: it proves the published fixture, the
authenticated snapshot and discovery routes, and the two CLI surfaces agree on
the same synthetic chats, including matching membership after assignment, label
rename, reset, removal, and a new sibling pane; conflicting publishers; identical
raw IDs on separate servers; filter-before-pagination; freshness; publication
withdrawal; and the read-only refusal of ``chat.tab-color``.

Everything here is synthetic. No installed app, real UserDefaults store, real
configuration, or captured personal data is used. Installed-app behavior is
covered by the native unit suites and the manual checklist; this suite only
covers the Python server plus CLI transport.
"""

import copy
import io
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from herdr_harness import control_cli
from herdr_harness.control_store import ControlStore
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService
from scripts.herdr_hud_chats_cli import main as hud_chats_main


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "chat-tab-colors-v1.json"
MAIN_TOKEN = "issue-27-synthetic-main-bearer-token"
RECEIVER_TOKEN = "c" * 64
INSTANCE_ID = "99999999-9999-4999-8999-999999999999"
FIXED_TIME = 1893456000.0
SNAPSHOT_TIME = "2030-01-01T00:00:00Z"

PRIMARY = "ui_11111111-1111-4111-8111-111111111111"
SECONDARY = "ui_22222222-2222-4222-8222-222222222222"
PRIMARY_MACHINE = "alpha"
SECOND_MACHINE = "beta"


class StepClock:
    """Deterministic clock shared by the store and the fixture."""

    def __init__(self, value=FIXED_TIME):
        self.value = value

    def __call__(self):
        return self.value


class SyntheticHerdrClient:
    """Mutable synthetic topology so a later sibling pane can be observed."""

    def __init__(self, snapshot):
        self._snapshot = copy.deepcopy(snapshot)
        self.socket_path = "/synthetic/chat-tab-colors.sock"
        self.session = "chat-tab-colors-integration"

    def snapshot(self):
        return copy.deepcopy(self._snapshot)

    def add_pane(self, pane):
        self._snapshot["panes"].append(copy.deepcopy(pane))

    def request(self, _method, _parameters):
        raise AssertionError("The tab color integration suite must not mutate a real terminal")

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


class RecordingOpener:
    """Call the real loopback server while recording every CLI request."""

    def __init__(self):
        self.requests = []
        self._open = urllib.request.build_opener(urllib.request.ProxyHandler({})).open

    def __call__(self, request, *, timeout):
        parsed = urllib.parse.urlsplit(request.full_url)
        self.requests.append(
            {
                "url": request.full_url,
                "path": parsed.path,
                "query": urllib.parse.parse_qs(parsed.query),
                "method": request.get_method(),
                "headers": {key.lower(): value for key, value in request.header_items()},
            }
        )
        return self._open(request, timeout=timeout)


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


class ChatTabColorIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.clock = StepClock()
        self.store = ControlStore(self.root / "control.sqlite3", clock=self.clock)
        self.client = SyntheticHerdrClient(synthetic_snapshot())
        self.service = HerdrService(
            self.client,
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
        self.config = self.root / "config.toml"
        self.write_config()
        self.control_environ = {
            "HOME": str(self.root),
            "SYNTHETIC_HERDR_TOKEN": MAIN_TOKEN,
            "SYNTHETIC_HERDR_SECOND_TOKEN": MAIN_TOKEN,
        }
        self.hud_environ = {
            "HOME": str(self.root),
            "HERDR_HARNESS_URL": self.base,
            "HERDR_HARNESS_API_TOKEN": MAIN_TOKEN,
        }

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.service.stop()
        self.store.close()

    def write_config(self, second_base=None):
        lines = [
            "version = 1",
            "[machines.alpha]",
            'name = "Alpha"',
            f'url = "{self.base}"',
            "[machines.alpha.server]",
            'api_token = { env = "SYNTHETIC_HERDR_TOKEN" }',
        ]
        if second_base is not None:
            lines += [
                "[machines.beta]",
                'name = "Beta"',
                f'url = "{second_base}"',
                "[machines.beta.server]",
                'api_token = { env = "SYNTHETIC_HERDR_SECOND_TOKEN" }',
            ]
        self.config.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.config.chmod(0o600)

    # -- HTTP transport -------------------------------------------------------

    def request(self, path, *, method="GET", payload=None, base=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"} if data is not None else {}
        headers["Authorization"] = f"Bearer {MAIN_TOKEN}"
        request = urllib.request.Request(
            (base or self.base) + path, method=method, data=data, headers=headers
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def publish(self, key="primary", *, base=None, server_id=None, **overrides):
        body = copy.deepcopy(self.fixture["publications"][key])
        body["serverId"] = server_id or self.server_id
        body.update(overrides)
        return self.request(
            f"/api/v1/control/chat-tab-colors/{self.fixture['clients'][key]['clientId']}",
            method="POST",
            payload=body,
            base=base,
        )

    def publish_primary(self, revision, tabs, **overrides):
        return self.publish("primary", revision=revision, tabs=tabs, **overrides)

    def snapshot(self):
        status, body = self.request("/api/v1/snapshot")
        self.assertEqual(status, 200)
        return body

    def tab_entries(self, tab_id, *, base=None):
        body = self.snapshot() if base is None else self.request("/api/v1/snapshot", base=base)[1]
        tab = next(tab for tab in body["snapshot"]["tabs"] if tab["tab_id"] == tab_id)
        return tab["chatTabColors"]

    # -- CLI entry points -----------------------------------------------------

    def run_control(self, argv, *, machine=PRIMARY_MACHINE, control_machine=None):
        arguments = ["--config", str(self.config), "--machine", machine]
        if control_machine is not None:
            arguments += ["--control-machine", control_machine]
        arguments += list(argv)
        stdout, stderr = io.StringIO(), io.StringIO()
        opener = RecordingOpener()
        status = control_cli.main(
            arguments,
            environ=self.control_environ,
            stdin=io.StringIO(),
            stdout=stdout,
            stderr=stderr,
            opener=opener,
        )
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        error = json.loads(stderr.getvalue()) if stderr.getvalue() else None
        return status, output, error, opener

    def run_hud(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        opener = RecordingOpener()
        status = hud_chats_main(
            list(argv),
            environ=self.hud_environ,
            stdout=stdout,
            stderr=stderr,
            opener=opener,
        )
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        error = json.loads(stderr.getvalue()) if stderr.getvalue() else None
        return status, output, error, opener

    @staticmethod
    def result_ids(output):
        return sorted(row["id"] for row in output["results"])

    def assert_all_get(self, opener):
        self.assertTrue(opener.requests)
        for request in opener.requests:
            self.assertEqual(request["method"], "GET", request["url"])

    # -- Tests ----------------------------------------------------------------

    def test_shared_fixture_projects_into_snapshot_and_both_clis(self):
        self.assertEqual(self.publish("primary")[0], 200)
        self.assertEqual(self.publish("secondary")[0], 200)

        body = self.snapshot()
        self.assertEqual(body["chatTabColorSources"], self.fixture["expected"]["sources"])
        entries = {tab["tab_id"]: tab["chatTabColors"] for tab in body["snapshot"]["tabs"]}
        for tab_id, expected in self.fixture["expected"]["tabs"].items():
            self.assertEqual(entries[tab_id], expected, tab_id)
        self.assertEqual(
            [entry["status"] for entry in entries["ws_synthetic_gamma:t1"]],
            ["unavailable", "unavailable"],
        )

        published_before = self.store.chat_tab_color_publications()

        status, output, error, opener = self.run_control([
            "find", "chats",
            "--color", "sage",
            "--color-label", "Synthetic Release Group",
            "--color-client", PRIMARY,
            "--group-by", "label",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(
            self.result_ids(output),
            ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2"],
        )
        self.assertEqual(output["groupingScope"], "page")
        self.assertEqual(len(output["groups"]), 1)
        group = output["groups"][0]
        self.assertEqual(group["clientId"], PRIMARY)
        self.assertEqual(group["status"], "assigned")
        self.assertEqual(group["key"], "synthetic release group")
        self.assertEqual(group["colors"], ["sage"])
        self.assertEqual(group["count"], 2)
        self.assertEqual(group["scope"], "page")
        self.assertEqual(
            [member["result"]["id"] for member in group["members"]],
            ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2"],
        )
        self.assertEqual(
            {member["chatTabColor"]["clientId"] for member in group["members"]},
            {PRIMARY},
        )
        discovery = next(
            request for request in opener.requests if request["path"].endswith("/discovery")
        )
        self.assertEqual(discovery["query"]["color"], ["sage"])
        self.assertEqual(discovery["query"]["colorLabel"], ["Synthetic Release Group"])
        self.assertEqual(discovery["query"]["colorClientId"], [PRIMARY])
        self.assertEqual(discovery["query"]["chatScope"], ["terminal"])
        self.assertEqual(discovery["headers"]["authorization"], "Bearer " + MAIN_TOKEN)
        self.assertNotIn(MAIN_TOKEN, json.dumps(output, ensure_ascii=False))
        self.assert_all_get(opener)

        status, output, error, opener = self.run_hud(
            ["list", "--scope", "terminal", "--color", "iris", "--group-by", "color"]
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(self.result_ids(output), ["ws_synthetic_beta:p3"])
        self.assertEqual(output["scope"], "terminal")
        self.assertEqual(output["groupingScope"], "page")
        self.assertEqual(output["groups"][0]["color"], "iris")
        self.assertEqual(output["groups"][0]["clientId"], PRIMARY)
        self.assertEqual(output["groups"][0]["count"], 1)
        self.assertEqual(
            output["groups"][0]["members"][0]["chatTabColor"]["label"],
            "Synthesé ✦ Planning",
        )
        self.assertEqual(output["results"][0]["target"]["paneId"], "ws_synthetic_beta:p3")
        self.assertNotIn(MAIN_TOKEN, json.dumps(output, ensure_ascii=False))
        self.assertEqual(
            [request["path"] for request in opener.requests],
            ["/api/v1/control/capabilities", "/api/v1/discovery"],
        )
        self.assert_all_get(opener)

        # Saved HUD history keeps its own path and envelope with no color metadata.
        status, output, error, opener = self.run_hud(["list"])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["chats"], [])
        self.assertNotIn("chatTabColors", json.dumps(output))
        self.assertEqual([request["path"] for request in opener.requests], ["/api/v1/hud-chats"])
        self.assert_all_get(opener)

        # Reading through either CLI never changes the server-side publication copy.
        self.assertEqual(self.store.chat_tab_color_publications(), published_before)

    def test_assignment_rename_reset_removal_and_new_sibling_pane(self):
        self.assertEqual(self.publish("primary")[0], 200)
        self.assertEqual(self.publish("secondary")[0], 200)

        def sage_entry(tab_id, label):
            return {
                "workspaceId": "ws_synthetic_alpha",
                "tabId": tab_id,
                "color": "sage",
                "label": label,
            }

        stable_tabs = [
            {
                "workspaceId": "ws_synthetic_beta",
                "tabId": "ws_synthetic_beta:t1",
                "color": "iris",
                "label": "Synthesé ✦ Planning",
            },
            {
                "workspaceId": "ws_synthetic_beta",
                "tabId": "ws_synthetic_beta:t2",
                "color": None,
                "label": None,
            },
        ]

        # Assignment plus label rename: old text stops matching, new text matches.
        self.assertEqual(
            self.publish_primary(
                8,
                [
                    sage_entry("ws_synthetic_alpha:t1", "Synthetic Group Renamed"),
                    sage_entry("ws_synthetic_alpha:t2", "Synthetic Group Renamed"),
                    *stable_tabs,
                ],
            )[0],
            200,
        )
        self.assertEqual(
            self.tab_entries("ws_synthetic_alpha:t1")[0]["label"], "Synthetic Group Renamed"
        )
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "sage", "--color-label", "Synthetic Release Group",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["results"], [])
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "sage", "--color-label", "Synthetic Group Renamed",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(
            self.result_ids(output), ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2"]
        )
        # Labels belong to one publisher entry: the other client keeps its own text.
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "rose", "--color-client", SECONDARY,
            "--color-label", "Synthetic Release Group",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(self.result_ids(output), ["ws_synthetic_alpha:p1"])

        # Reset the label to the palette default; only the default matches now.
        reset_tabs = [
            sage_entry("ws_synthetic_alpha:t1", "Sage"),
            sage_entry("ws_synthetic_alpha:t2", "Sage"),
            *stable_tabs,
        ]
        self.assertEqual(self.publish_primary(9, reset_tabs)[0], 200)
        status, output, error, _ = self.run_control([
            "find", "chats", "--color-label", "Synthetic Group Renamed",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["results"], [])
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "sage", "--color-label", "  sage  ",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(
            self.result_ids(output), ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2"]
        )

        # Removing a tab from the publication reports unavailable, never unassigned.
        removed_tabs = [
            sage_entry("ws_synthetic_alpha:t2", "Sage"),
            stable_tabs[0],
            {
                "workspaceId": "ws_synthetic_beta",
                "tabId": "ws_synthetic_beta:t2",
                "color": "slate",
                "label": "Synthetic Ops",
            },
        ]
        self.assertEqual(self.publish_primary(10, removed_tabs)[0], 200)
        self.assertEqual(
            self.tab_entries("ws_synthetic_alpha:t1")[0]["status"], "unavailable"
        )
        status, output, error, _ = self.run_control(["find", "chats", "--color", "none"])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["results"], [])
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "sage", "--color-client", PRIMARY,
        ])
        self.assertEqual(self.result_ids(output), ["ws_synthetic_alpha:p2"])
        status, output, error, _ = self.run_control([
            "find", "chats", "--color-client", PRIMARY,
        ])
        self.assertEqual(
            self.result_ids(output),
            ["ws_synthetic_alpha:p2", "ws_synthetic_beta:p3", "ws_synthetic_beta:p4"],
        )

        # Manual removal is an explicit known-no-color entry that `none` matches.
        explicit_none_tabs = [
            {
                "workspaceId": "ws_synthetic_alpha",
                "tabId": "ws_synthetic_alpha:t1",
                "color": None,
                "label": None,
            },
            *removed_tabs,
        ]
        self.assertEqual(self.publish_primary(11, explicit_none_tabs)[0], 200)
        self.assertEqual(self.tab_entries("ws_synthetic_alpha:t1")[0]["status"], "unassigned")
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "none", "--color-client", PRIMARY,
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(self.result_ids(output), ["ws_synthetic_alpha:p1"])

        # A pane added later in the same tab inherits the tab's published color.
        self.client.add_pane({
            "pane_id": "ws_synthetic_beta:p6",
            "terminal_id": "term_synthetic_6",
            "workspace_id": "ws_synthetic_beta",
            "tab_id": "ws_synthetic_beta:t2",
            "label": "Synthetic Worker 6",
            "agent_status": "working",
            "last_activity_at": SNAPSHOT_TIME,
        })
        self.service.refresh_snapshot(force=True)
        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "slate", "--group-by", "color",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(
            self.result_ids(output), ["ws_synthetic_beta:p4", "ws_synthetic_beta:p6"]
        )
        self.assertEqual(output["groups"][0]["colors"], ["slate"])
        self.assertEqual(output["groups"][0]["count"], 2)
        status, output, error, _ = self.run_hud(
            ["list", "--scope", "terminal", "--color", "slate"]
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(
            self.result_ids(output), ["ws_synthetic_beta:p4", "ws_synthetic_beta:p6"]
        )

    def test_conflicting_publishers_and_raw_id_isolation_across_servers(self):
        self.assertEqual(self.publish("primary")[0], 200)
        self.assertEqual(self.publish("secondary")[0], 200)

        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "rose", "--color-label", "Synthetic Release Group",
            "--color-client", SECONDARY, "--group-by", "label",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(self.result_ids(output), ["ws_synthetic_alpha:p1"])
        group = output["groups"][0]
        self.assertEqual(group["clientId"], SECONDARY)
        self.assertEqual(group["colors"], ["rose"])
        self.assertEqual(group["members"][0]["chatTabColor"]["color"], "rose")

        # One normalized label stays separate per publisher entry.
        status, output, error, _ = self.run_control(["find", "chats", "--group-by", "label"])
        self.assertEqual(status, 0, error)
        shared_label = [
            (group["clientId"], group["key"], group["count"])
            for group in output["groups"]
            if group["key"] == "synthetic release group"
        ]
        self.assertEqual(
            sorted(shared_label),
            sorted([
                (PRIMARY, "synthetic release group", 2),
                (SECONDARY, "synthetic release group", 1),
            ]),
        )

        # A second independent companion reuses the same raw tab and pane IDs.
        second_store = ControlStore(self.root / "control-second.sqlite3", clock=self.clock)
        self.addCleanup(second_store.close)
        second_service = HerdrService(
            SyntheticHerdrClient(synthetic_snapshot()),
            environ={
                "HOME": str(self.root / "home-second"),
                "HERDR_STATE_DIR": str(self.root / "state-second"),
            },
            pi_semantic=SyntheticPiSemantic(),
            control_store=second_store,
        )
        second_server = make_server(
            second_service, host="127.0.0.1", port=0, api_token=MAIN_TOKEN
        )
        second_thread = threading.Thread(target=second_server.serve_forever, daemon=True)
        second_thread.start()
        second_base = f"http://127.0.0.1:{second_server.server_address[1]}"
        try:
            self.assertNotEqual(second_store.server_id, self.server_id)
            self.write_config(second_base=second_base)
            status, payload = self.publish(
                "secondary", base=second_base, server_id=second_store.server_id
            )
            self.assertEqual(status, 200, payload)

            first_status, first_body = self.request("/api/v1/snapshot")
            self.assertEqual(first_status, 200)
            self.assertEqual(
                [source["clientId"] for source in first_body["chatTabColorSources"]],
                [PRIMARY, SECONDARY],
            )
            second_status, second_body = self.request("/api/v1/snapshot", base=second_base)
            self.assertEqual(second_status, 200)
            self.assertEqual(
                [source["clientId"] for source in second_body["chatTabColorSources"]],
                [SECONDARY],
            )

            status, first_output, error, _ = self.run_control([
                "find", "chats", "--color", "rose", "--group-by", "color",
            ])
            self.assertEqual(status, 0, error)
            self.assertEqual(self.result_ids(first_output), ["ws_synthetic_alpha:p1"])
            first_row = first_output["results"][0]
            self.assertEqual(first_row["target"]["serverId"], self.server_id)
            self.assertEqual(first_row["sourceMachine"], PRIMARY_MACHINE)

            status, second_output, error, _ = self.run_control(
                ["find", "chats", "--color", "rose", "--group-by", "color"],
                machine=SECOND_MACHINE,
            )
            self.assertEqual(status, 0, error)
            self.assertEqual(self.result_ids(second_output), ["ws_synthetic_alpha:p1"])
            second_row = second_output["results"][0]
            self.assertEqual(second_row["target"]["serverId"], second_store.server_id)
            self.assertNotEqual(
                second_row["target"]["serverId"], first_row["target"]["serverId"]
            )
            self.assertEqual(second_row["target"]["paneId"], first_row["target"]["paneId"])
            self.assertEqual(second_row["sourceMachine"], SECOND_MACHINE)
            self.assertNotEqual(
                second_output["sources"][0]["serverId"],
                first_output["sources"][0]["serverId"],
            )
        finally:
            second_server.shutdown()
            second_server.server_close()
            second_thread.join(timeout=2)
            second_service.stop()

    def test_color_filtering_happens_before_pagination(self):
        self.assertEqual(
            self.publish_primary(
                8,
                [
                    {
                        "workspaceId": "ws_synthetic_alpha",
                        "tabId": "ws_synthetic_alpha:t1",
                        "color": "sage",
                        "label": "Synthetic Page Group",
                    },
                    {
                        "workspaceId": "ws_synthetic_alpha",
                        "tabId": "ws_synthetic_alpha:t2",
                        "color": "sage",
                        "label": "Synthetic Page Group",
                    },
                    {
                        "workspaceId": "ws_synthetic_beta",
                        "tabId": "ws_synthetic_beta:t1",
                        "color": "sage",
                        "label": "Synthetic Page Group",
                    },
                ],
            )[0],
            200,
        )

        first_status, first, error, _ = self.run_control([
            "find", "chats", "--color", "sage", "--group-by", "color", "--limit", "2",
        ])
        self.assertEqual(first_status, 0, error)
        self.assertEqual(len(first["results"]), 2)
        self.assertIsNotNone(first["nextCursor"])
        self.assertEqual(first["groupingScope"], "page")
        self.assertEqual(first["groups"][0]["count"], 2)
        self.assertEqual(first["groups"][0]["scope"], "page")

        second_status, second, error, second_opener = self.run_control([
            "find", "chats", "--color", "sage", "--group-by", "color", "--limit", "2",
            "--cursor", first["nextCursor"],
        ])
        self.assertEqual(second_status, 0, error)
        self.assertEqual(len(second["results"]), 1)
        self.assertIsNone(second["nextCursor"])
        self.assertEqual(second["groups"][0]["count"], 1)
        combined = sorted(row["id"] for row in first["results"] + second["results"])
        self.assertEqual(
            combined,
            ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2", "ws_synthetic_beta:p3"],
        )
        self.assertEqual(len(combined), len(set(combined)))
        offsets = [
            request["query"].get("offset", [None])[0]
            for request in second_opener.requests
            if request["path"].endswith("/discovery")
        ]
        self.assertEqual(offsets, ["2"])

        # The HUD CLI filters before its offset page too.
        status, output, error, opener = self.run_hud([
            "list", "--scope", "terminal", "--color", "sage", "--offset", "2",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(self.result_ids(output), ["ws_synthetic_beta:p3"])
        self.assert_all_get(opener)

    def test_stale_metadata_and_publication_withdrawal_are_explicit(self):
        self.assertEqual(self.publish("primary")[0], 200)

        self.clock.value += 61
        body = self.snapshot()
        self.assertTrue(body["chatTabColorSources"][0]["stale"])
        self.assertTrue(self.tab_entries("ws_synthetic_alpha:t1")[0]["stale"])

        status, output, error, _ = self.run_control([
            "find", "chats", "--color", "sage", "--group-by", "color",
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(
            self.result_ids(output), ["ws_synthetic_alpha:p1", "ws_synthetic_alpha:p2"]
        )
        self.assertTrue(output["groups"][0]["stale"])
        self.assertEqual(
            output["sources"][0]["coverage"]["chatTabColors"]["freshness"], "stale"
        )
        self.assertEqual(
            output["sources"][0]["coverage"]["chatTabColors"]["stalePublisherCount"], 1
        )
        self.assertTrue(output["results"][0]["chatTabColors"][0]["stale"])

        status, output, error, _ = self.run_hud(["list", "--scope", "terminal", "--color", "sage"])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["coverage"]["chatTabColors"]["freshness"], "stale")
        self.assertTrue(output["results"][0]["chatTabColors"][0]["stale"])

        # Withdrawing publication clears exported values without deleting the binding.
        self.assertEqual(self.publish_primary(8, [], enabled=False)[0], 200)
        body = self.snapshot()
        self.assertFalse(body["chatTabColorSources"][0]["enabled"])
        self.assertEqual(self.tab_entries("ws_synthetic_alpha:t1")[0]["status"], "unavailable")

        status, output, error, _ = self.run_control(["find", "chats", "--color", "sage"])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["results"], [])
        self.assertFalse(
            output["sources"][0]["coverage"]["chatTabColors"]["available"]
        )
        self.assertEqual(
            output["sources"][0]["coverage"]["chatTabColors"]["freshness"], "none"
        )
        status, output, error, _ = self.run_control(["find", "chats", "--color", "none"])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["results"], [])
        status, output, error, _ = self.run_control([
            "find", "chats", "--color-client", PRIMARY,
        ])
        self.assertEqual(status, 0, error)
        self.assertEqual(output["results"], [])

        # A delayed older revision cannot clear or restore newer metadata.
        status, payload = self.publish("primary")
        self.assertEqual(status, 409)
        self.assertEqual(payload["error"]["code"], "stale_publication_revision")
        self.assertEqual(self.tab_entries("ws_synthetic_alpha:t1")[0]["status"], "unavailable")

    def test_agent_color_mutation_is_refused_end_to_end(self):
        self.assertEqual(self.publish("primary")[0], 200)
        published_before = self.store.chat_tab_color_publications()

        tab_color_action = {
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
                "actions": [tab_color_action],
            },
        )
        self.assertEqual(status, 200)

        # The relay catalog reports the action disabled with a read-only reason.
        status, output, error, opener = self.run_control(
            ["ui", "actions", "--client", PRIMARY], control_machine=PRIMARY_MACHINE
        )
        self.assertEqual(status, 0, error)
        descriptor = output["actions"][0]
        self.assertEqual(descriptor["id"], "chat.tab-color")
        self.assertFalse(descriptor["enabled"])
        self.assertIn("read-only", descriptor["disabledReason"])
        self.assert_all_get(opener)

        # The CLI refuses before enqueueing any command.
        parameters = self.root / "tab-color-parameters.json"
        parameters.write_text(json.dumps({"color": "sage"}), encoding="utf-8")
        status, output, error, opener = self.run_control(
            [
                "ui", "invoke", "chat.tab-color",
                "--client", PRIMARY,
                "--request-id", "synthetic-tab-color-1",
                "--parameters-file", str(parameters),
            ],
            control_machine=PRIMARY_MACHINE,
        )
        self.assertNotEqual(status, 0)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "action_disabled")
        self.assertIn("read-only", error["error"]["message"])
        self.assertEqual([request["path"] for request in opener.requests], ["/api/v1/ui/clients"])
        self.assert_all_get(opener)

        # A caller that ignores the catalog is rejected at server admission too.
        status, body = self.request(
            f"/api/v1/ui/clients/{PRIMARY}/commands",
            method="POST",
            payload={
                "requestId": "synthetic-tab-color-2",
                "action": "chat.tab-color",
                "parameters": {"color": "sage"},
            },
        )
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "action_disabled")

        # Neither refusal changed the exported colors.
        self.assertEqual(self.store.chat_tab_color_publications(), published_before)
        self.assertEqual(self.tab_entries("ws_synthetic_alpha:t1")[0]["color"], "sage")


if __name__ == "__main__":
    unittest.main()
