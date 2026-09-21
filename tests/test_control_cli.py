import hashlib
import io
import json
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path

from herdr_harness import control_cli as cli


class FakeResponse:
    def __init__(self, payload, *, status=200, final_url=None):
        self.status = status
        self.payload = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
        self.final_url = final_url
        self.request_url = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, maximum=-1):
        return self.payload if maximum < 0 else self.payload[:maximum]

    def geturl(self):
        return self.final_url or self.request_url


class QueueOpener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def __call__(self, request, *, timeout):
        self.requests.append(
            {
                "url": request.full_url,
                "method": request.get_method(),
                "headers": {key.lower(): value for key, value in request.header_items()},
                "body": request.data,
                "timeout": timeout,
            }
        )
        if not self.responses:
            raise AssertionError("unexpected request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        response.request_url = request.full_url
        return response


class FleetOpener:
    def __init__(self, responses_by_host):
        self.responses_by_host = dict(responses_by_host)
        self.requests = []

    def __call__(self, request, *, timeout):
        hostname = urllib.parse.urlsplit(request.full_url).hostname
        machine = hostname.split(".")[0]
        self.requests.append(
            {
                "url": request.full_url,
                "method": request.get_method(),
                "headers": {key.lower(): value for key, value in request.header_items()},
                "body": request.data,
                "timeout": timeout,
            }
        )
        response = self.responses_by_host[machine]
        if isinstance(response, BaseException):
            raise response
        response.request_url = request.full_url
        return response


class PagingOpener:
    def __init__(self, rows_by_host):
        self.rows_by_host = rows_by_host
        self.requests = []

    def __call__(self, request, *, timeout):
        parsed = urllib.parse.urlsplit(request.full_url)
        query = urllib.parse.parse_qs(parsed.query)
        offset = int(query.get("offset", ["0"])[0])
        limit = int(query.get("limit", ["20"])[0])
        machine = parsed.hostname.split(".")[0]
        rows = self.rows_by_host[machine]
        page = rows[offset:offset + limit]
        payload = discovery(machine, *page)
        payload["nextOffset"] = offset + limit if offset + limit < len(rows) else None
        response = FakeResponse(payload)
        response.request_url = request.full_url
        self.requests.append(
            {
                "url": request.full_url,
                "method": request.get_method(),
                "headers": {key.lower(): value for key, value in request.header_items()},
                "body": request.data,
                "timeout": timeout,
            }
        )
        return response


class JumpClock:
    def __init__(self):
        self.now = 10.0

    def __call__(self):
        return self.now

    def sleep(self, duration):
        self.now += max(duration, 10.0)


def discovery(machine, *results):
    return {
        "ok": True,
        "serverId": f"srv_{machine}",
        "results": list(results),
        "nextOffset": None,
        "coverage": {"live": True},
        "generatedAt": "2026-09-17T00:00:00Z",
    }


def resource(kind, identifier, *, updated="2026-09-17T00:00:00Z", **target):
    field = {"pane": "paneId", "workspace": "workspaceId", "tab": "tabId"}[kind]
    return {
        "kind": kind,
        "id": identifier,
        "title": identifier,
        "updatedAt": updated,
        "status": "live",
        "target": {"kind": kind, field: identifier, **target},
        "matchEvidence": [],
        "openModes": ["chat"],
    }


def clients(*items):
    return {"ok": True, "serverId": "srv_alpha", "clients": list(items)}


def ui_action(identifier, *, target_kinds=(), properties=None, required=(), enabled=True):
    return {
        "id": identifier,
        "title": identifier,
        "parameters": {
            "type": "object",
            "properties": properties or {},
            "required": list(required),
            "additionalProperties": False,
        },
        "targetKinds": list(target_kinds),
        "effect": "navigation",
        "enabled": enabled,
    }


def standard_ui_actions():
    return [
        ui_action(
            "ui.open",
            target_kinds=("pane", "workspace", "tab", "first-mate", "hud-chat"),
            properties={"view": {"type": "string", "enum": ["chat", "terminal", "git", "skills"]}},
        ),
        ui_action(
            "ui.segment",
            properties={"segment": {"type": "string", "enum": [
                "chat", "terminal", "git", "skills", "workspace", "active-work", "pr-review",
                "first-mate", "fleet", "attention", "activity",
            ]}},
            required=("segment",),
        ),
        ui_action("ui.back"),
        ui_action("ui.forward"),
        ui_action("ui.settings"),
        ui_action("chat.summarize", target_kinds=("pane",)),
    ]


def ui_client(identifier, *, online=True, revision=3, actions=None):
    return {
        "clientId": identifier,
        "name": "Synthetic Companion",
        "instanceId": "11111111-1111-1111-1111-111111111111",
        "online": online,
        "lastSeenAt": "2026-09-17T00:00:00Z",
        "state": {"revision": revision, "window": "main", "segment": "chat", "enabled": True},
        "actions": standard_ui_actions() if actions is None else actions,
    }


def selecting_ui_client(identifier, session_id, *, kind="pane", pane_id=None):
    receiver = ui_client(identifier)
    selection = {"kind": kind, "sessionId": session_id}
    if pane_id is not None:
        selection["paneId"] = pane_id
    receiver["state"]["selection"] = selection
    return receiver


class ControlCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / "config.toml"
        self.write_config(
            """version = 1
[machines.alpha]
name = "Alpha"
url = "https://alpha.example.test"
[machines.alpha.server]
api_token = { env = "ALPHA_TOKEN" }
[machines.beta]
name = "Beta"
url = "https://beta.example.test"
[machines.beta.server]
api_token = { env = "BETA_TOKEN" }
"""
        )
        self.environ = {
            "HOME": str(self.root),
            "ALPHA_TOKEN": "alpha-synthetic-token",
            "BETA_TOKEN": "beta-synthetic-token",
            # These belong to the invoking machine and must never override either roster entry.
            "HERDR_MACHINE": "local-machine",
            "HERDR_HARNESS_URL": "https://wrong.example.test",
            "HERDR_HARNESS_API_TOKEN": "inherited-wrong-token",
        }

    def write_config(self, text):
        self.config.write_text(text, encoding="utf-8")
        self.config.chmod(0o600)

    def write_json(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def run_cli(self, argv, *responses, environ=None, clock=None, opener=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        opener = opener or QueueOpener(*responses)
        clock = clock or JumpClock()
        status = cli.main(
            ["--config", str(self.config), *argv],
            environ=self.environ if environ is None else environ,
            stdin=io.StringIO(),
            stdout=stdout,
            stderr=stderr,
            opener=opener,
            clock=clock,
            sleep=clock.sleep,
        )
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        error = json.loads(stderr.getvalue()) if stderr.getvalue() else None
        return status, output, error, opener

    def test_help_needs_no_configuration_or_token(self):
        output, error = io.StringIO(), io.StringIO()
        status = cli.main(["--help"], environ={}, stdout=output, stderr=error)
        self.assertEqual(status, 0)
        self.assertIn("herdr-control", output.getvalue())
        self.assertEqual(error.getvalue(), "")

    def test_machine_roster_is_public_and_does_not_resolve_credentials(self):
        status, output, error, opener = self.run_cli(["machines"], environ={"HOME": str(self.root)})
        self.assertEqual(status, 0, error)
        self.assertEqual([item["id"] for item in output["machines"]], ["alpha", "beta"])
        self.assertNotIn("token", json.dumps(output).lower())
        self.assertEqual(opener.requests, [])

    def test_federated_auth_is_isolated_and_inherited_local_endpoint_is_ignored(self):
        fleet = FleetOpener({
            "alpha": FakeResponse(discovery("alpha")),
            "beta": FakeResponse(discovery("beta")),
        })
        status, output, error, opener = self.run_cli(
            ["--all-machines", "find", "all"], opener=fleet
        )
        self.assertEqual(status, 0, error)
        self.assertFalse(output["partial"])
        requests_by_host = {
            urllib.parse.urlsplit(request["url"]).hostname: request
            for request in opener.requests
        }
        self.assertEqual(set(requests_by_host), {"alpha.example.test", "beta.example.test"})
        self.assertEqual(requests_by_host["alpha.example.test"]["headers"]["authorization"], "Bearer alpha-synthetic-token")
        self.assertEqual(requests_by_host["beta.example.test"]["headers"]["authorization"], "Bearer beta-synthetic-token")
        rendered = json.dumps(output)
        self.assertNotIn("synthetic-token", rendered)
        self.assertNotIn("inherited-wrong-token", rendered)

    def test_remote_plain_http_and_redirects_are_rejected_without_leaking_auth(self):
        self.write_config(
            """[machines.alpha]
name = "Alpha"
url = "http://alpha.example.test"
[machines.alpha.server]
api_token = { env = "ALPHA_TOKEN" }
"""
        )
        status, output, error, opener = self.run_cli(["--machine", "alpha", "find", "all"])
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "all_sources_failed")
        self.assertEqual(opener.requests, [])
        self.assertNotIn("alpha-synthetic-token", json.dumps(error))

        self.write_config(
            """[machines.alpha]
name = "Alpha"
url = "https://alpha.example.test"
[machines.alpha.server]
api_token = { env = "ALPHA_TOKEN" }
"""
        )
        redirected = FakeResponse(
            discovery("alpha"), final_url="https://redirect.example.test/api/v1/discovery"
        )
        status, output, error, _ = self.run_cli(
            ["--machine", "alpha", "find", "all"], redirected
        )
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["details"]["sources"][0]["error"]["code"], "redirect_not_allowed")
        self.assertNotIn("alpha-synthetic-token", json.dumps(error))

    def test_multi_machine_roster_refuses_shared_credential_fallback(self):
        self.write_config(
            """[server]
api_token = "shared-synthetic-token"
[machines.alpha]
name = "Alpha"
url = "https://alpha.example.test"
[machines.beta]
name = "Beta"
url = "https://beta.example.test"
"""
        )
        status, _, error, opener = self.run_cli(["--machine", "beta", "find", "all"])
        self.assertEqual(status, 3)
        self.assertEqual(error["error"]["details"]["sources"][0]["error"]["code"], "machine_credential_required")
        self.assertEqual(opener.requests, [])
        self.assertNotIn("shared-synthetic-token", json.dumps(error))

    def test_partial_discovery_is_success_and_all_failed_is_not_success(self):
        status, output, error, opener = self.run_cli(
            ["--all-machines", "find", "all"],
            opener=FleetOpener({
                "alpha": urllib.error.URLError("synthetic unavailable"),
                "beta": FakeResponse(discovery("beta", resource("workspace", "w2"))),
            }),
        )
        self.assertEqual(status, 0, error)
        self.assertTrue(output["partial"])
        self.assertEqual(output["results"][0]["target"]["machineId"], "beta")
        self.assertEqual(output["sourceErrors"][0]["machineId"], "alpha")
        self.assertIsNotNone(output["nextCursor"])
        self.assertEqual(len(opener.requests), 2)

        status, output, error, _ = self.run_cli(
            ["--all-machines", "find", "all"],
            opener=FleetOpener({
                "alpha": urllib.error.URLError("alpha down"),
                "beta": urllib.error.URLError("beta down"),
            }),
        )
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "all_sources_failed")
        self.assertEqual(len(error["error"]["details"]["sources"]), 2)

    def test_updated_merge_is_deterministic_and_unknown_timestamps_sort_last(self):
        alpha = discovery(
            "alpha",
            resource("workspace", "unknown-alpha", updated=None),
            resource("workspace", "older", updated="2026-09-16T00:00:00Z"),
        )
        beta = discovery(
            "beta",
            resource("workspace", "newer", updated="2026-09-17T00:00:00Z"),
            resource("workspace", "unknown-beta", updated=None),
        )
        status, output, error, _ = self.run_cli(
            ["--all-machines", "find", "workspaces", "--sort", "updated"],
            opener=FleetOpener({"alpha": FakeResponse(alpha), "beta": FakeResponse(beta)}),
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(
            [item["id"] for item in output["results"]],
            ["newer", "older", "unknown-alpha", "unknown-beta"],
        )

    def test_federated_cursor_advances_only_emitted_rows_without_skips(self):
        rows = {
            "alpha": [
                resource("workspace", "a8", updated="2026-09-17T08:00:00Z"),
                resource("workspace", "a6", updated="2026-09-17T06:00:00Z"),
                resource("workspace", "a4", updated="2026-09-17T04:00:00Z"),
                resource("workspace", "a2", updated="2026-09-17T02:00:00Z"),
                resource("workspace", "unknown-alpha", updated=None),
            ],
            "beta": [
                resource("workspace", "b7", updated="2026-09-17T07:00:00Z"),
                resource("workspace", "b5", updated="2026-09-17T05:00:00Z"),
                resource("workspace", "b3", updated="2026-09-17T03:00:00Z"),
                resource("workspace", "b1", updated="2026-09-17T01:00:00Z"),
                resource("workspace", "unknown-beta", updated=None),
            ],
        }
        opener = PagingOpener(rows)
        cursor = None
        identifiers = []
        for _page in range(3):
            arguments = ["--all-machines", "find", "workspaces", "--limit", "4"]
            if cursor is not None:
                arguments += ["--cursor", cursor]
            status, output, error, _ = self.run_cli(arguments, opener=opener)
            self.assertEqual(status, 0, error)
            identifiers.extend(item["id"] for item in output["results"])
            cursor = output["nextCursor"]
        self.assertIsNone(cursor)
        self.assertEqual(
            identifiers,
            ["a8", "b7", "a6", "b5", "a4", "b3", "a2", "b1", "unknown-alpha", "unknown-beta"],
        )
        self.assertEqual(len(identifiers), len(set(identifiers)))
        offsets = {"alpha": [], "beta": []}
        for request in opener.requests:
            parsed = urllib.parse.urlsplit(request["url"])
            offsets[parsed.hostname.split(".")[0]].append(
                int(urllib.parse.parse_qs(parsed.query)["offset"][0])
            )
        self.assertEqual(offsets, {"alpha": [0, 2, 4], "beta": [0, 2, 4]})

    def test_cursor_is_bound_to_query_and_roster(self):
        first = PagingOpener({
            "alpha": [resource("workspace", "a2"), resource("workspace", "a1")],
            "beta": [resource("workspace", "b2"), resource("workspace", "b1")],
        })
        status, output, error, _ = self.run_cli(
            ["--all-machines", "find", "workspaces", "--limit", "1"], opener=first
        )
        self.assertEqual(status, 0, error)
        status, _, error, opener = self.run_cli(
            [
                "--all-machines", "find", "workspaces", "--limit", "1",
                "--query", "different", "--cursor", output["nextCursor"],
            ]
        )
        self.assertEqual(status, 2)
        self.assertEqual(error["error"]["code"], "cursor_mismatch")
        self.assertEqual(opener.requests, [])

    def test_ref_file_accepts_target_or_discovery_result(self):
        for index, document in enumerate(
            (
                {"kind": "pane", "paneId": "w1:p2", "terminalId": "t2", "sessionId": "s2"},
                resource("pane", "w1:p2", terminalId="t2", sessionId="s2"),
            )
        ):
            with self.subTest(index=index):
                path = self.write_json(f"ref-{index}.json", document)
                inspected = resource("pane", "w1:p2", terminalId="t2", sessionId="s2")
                status, output, error, opener = self.run_cli(
                    ["--machine", "alpha", "inspect", "--ref-file", str(path)],
                    FakeResponse({"ok": True, "result": inspected}),
                )
                self.assertEqual(status, 0, error)
                self.assertEqual(output["result"]["target"]["sessionId"], "s2")
                self.assertEqual(output["result"]["target"]["machineId"], "alpha")
                self.assertEqual(opener.requests[0]["method"], "POST")

    def test_explicit_id_resolution_uses_minimal_inspect_without_search(self):
        inspected = resource(
            "pane", "w1:p2", terminalId="term-2", sessionId="session-2"
        )
        accepted = {
            "ok": True,
            "operation": {
                "requestId": "close-two",
                "action": "pane.close",
                "status": "completed",
            },
        }
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "actions", "invoke", "pane.close",
                "--pane", "w1:p2", "--request-id", "close-two",
            ],
            FakeResponse({"ok": True, "result": inspected}),
            FakeResponse(accepted),
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(len(opener.requests), 2)
        self.assertTrue(opener.requests[0]["url"].endswith("/api/v1/control/inspect"))
        self.assertEqual(
            json.loads(opener.requests[0]["body"]),
            {"target": {"kind": "pane", "paneId": "w1:p2"}},
        )
        mutation_target = json.loads(opener.requests[1]["body"])["target"]
        self.assertEqual(mutation_target["terminalId"], "term-2")
        self.assertEqual(mutation_target["sessionId"], "session-2")

    def test_inspection_rejects_reused_pane_before_mutation(self):
        path = self.write_json(
            "stale.json",
            {"kind": "pane", "paneId": "w1:p2", "terminalId": "term-old", "sessionId": "session-old"},
        )
        changed = resource(
            "pane", "w1:p2", terminalId="term-new", sessionId="session-new"
        )
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "actions", "invoke", "pane.close",
                "--ref-file", str(path), "--request-id", "close-one",
            ],
            FakeResponse({"ok": True, "result": changed}),
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "stale_target")
        self.assertEqual(len(opener.requests), 1)
        self.assertTrue(opener.requests[0]["url"].endswith("/api/v1/control/inspect"))

    def test_current_ui_target_uses_fresh_selection_and_revision(self):
        receiver = ui_client("ui_one", revision=8)
        state = dict(receiver["state"])
        state["selection"] = {
            "kind": "pane", "serverId": "srv_beta", "paneId": "w2:p7",
            "terminalId": "term-7", "sessionId": "session-7",
        }
        receiver["state"] = state
        accepted = {
            "ok": True,
            "command": {
                "requestId": "open-current",
                "clientId": "ui_one",
                "instanceId": receiver["instanceId"],
                "action": "ui.open",
                "parameters": {"view": "git"},
                "expectedRevision": 8,
                "status": "accepted",
                "createdAt": "2026-09-17T00:00:00Z",
                "expiresAt": "2026-09-17T00:00:30Z",
            },
        }
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "open", "--current",
                "--view", "git", "--request-id", "open-current", "--client", "ui_one",
            ],
            FakeResponse(clients(receiver)),
            FakeResponse({"ok": True, "serverId": "srv_alpha", "client": receiver}),
            FakeResponse(accepted),
        )
        self.assertEqual(status, 6, error)
        self.assertEqual(output["requestId"], "open-current")
        body = json.loads(opener.requests[2]["body"])
        self.assertEqual(body["expectedRevision"], 8)
        self.assertEqual(body["target"]["sessionId"], "session-7")
        self.assertEqual(body["parameters"], {"view": "git"})

    def test_current_targetless_segment_pins_revision_but_omits_target(self):
        receiver = ui_client("ui_one", revision=11)
        accepted = {
            "ok": True,
            "command": {"requestId": "segment-current", "status": "accepted"},
        }
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "segment", "activity",
                "--current", "--client", "ui_one", "--request-id", "segment-current",
            ],
            FakeResponse(clients(receiver)),
            FakeResponse({"ok": True, "serverId": "srv_alpha", "client": receiver}),
            FakeResponse(accepted),
        )
        self.assertEqual(status, 6, error)
        body = json.loads(opener.requests[2]["body"])
        self.assertEqual(body["expectedRevision"], 11)
        self.assertNotIn("target", body)

    def test_segment_rejects_explicit_target_without_inspection(self):
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "segment", "activity",
                "--pane", "w1:p2", "--request-id", "bad-segment",
            ]
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "unsupported_target")
        self.assertEqual(opener.requests, [])

    def test_ui_dry_run_validates_registry_enabled_state_and_schema(self):
        receiver = ui_client("ui_one")
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "invoke", "not.advertised",
                "--client", "ui_one", "--dry-run", "--request-id", "unknown-plan",
            ],
            FakeResponse(clients(receiver)),
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "action_not_found")
        self.assertEqual(len(opener.requests), 1)

        parameters = self.write_json("invalid-ui-parameters.json", {"unexpected": True})
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "segment", "activity",
                "--client", "ui_one", "--parameters-file", str(parameters),
                "--dry-run", "--request-id", "invalid-plan",
            ],
            FakeResponse(clients(receiver)),
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_parameters")
        self.assertEqual(len(opener.requests), 1)

        disabled = ui_client(
            "ui_one", actions=[ui_action("ui.back", enabled=False)]
        )
        disabled["actions"][0]["disabledReason"] = "Synthetic disabled reason"
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "back", "--client", "ui_one",
                "--dry-run", "--request-id", "disabled-plan",
            ],
            FakeResponse(clients(disabled)),
        )
        self.assertEqual(status, 5)
        self.assertEqual(error["error"]["code"], "action_disabled")
        self.assertEqual(len(opener.requests), 1)

    def test_ui_client_selection_never_chooses_an_arbitrary_live_receiver(self):
        first, second = ui_client("ui_first"), ui_client("ui_second")
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "back", "--request-id", "back-one"],
            FakeResponse(clients(first, second)),
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "ambiguous_ui_client")
        self.assertEqual(error["error"]["details"]["candidates"], ["ui_first", "ui_second"])
        self.assertEqual(len(opener.requests), 1)

        hinted_environment = {**self.environ, "HERDR_UI_CLIENT_ID": "ui_second"}
        accepted = {
            "ok": True,
            "command": {"requestId": "back-two", "status": "accepted"},
        }
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "back", "--request-id", "back-two"],
            FakeResponse(clients(first, second)),
            FakeResponse(accepted),
            environ=hinted_environment,
        )
        self.assertEqual(status, 6, error)
        self.assertIn("/ui/clients/ui_second/commands", opener.requests[1]["url"])

    def test_explicit_ui_client_precedes_environment_and_current_session(self):
        session_id = "01a0ae0a-e4fe-7c6a-b6d6-fc6a56f891d2"
        first = selecting_ui_client("ui_first", session_id)
        second = ui_client("ui_second")
        environment = {
            **self.environ,
            "HERDR_UI_CLIENT_ID": "ui_second",
            "PI_SESSION_ID": session_id,
        }
        accepted = {"ok": True, "command": {"requestId": "explicit-one", "status": "accepted"}}
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "back", "--client", "ui_first",
                "--request-id", "explicit-one",
            ],
            FakeResponse(clients(first, second)),
            FakeResponse(accepted),
            environ=environment,
        )
        self.assertEqual(status, 6, error)
        self.assertIn("/ui/clients/ui_first/commands", opener.requests[1]["url"])

    def test_multiple_receivers_select_one_exact_current_pi_session(self):
        current_session = "01a0ae0a-e4fe-7c6a-b6d6-fc6a56f891d2"
        other_session = "11111111-2222-3333-4444-555555555555"
        first = selecting_ui_client("ui_first", other_session)
        second = selecting_ui_client("ui_second", current_session.lower())
        environment = {**self.environ, "PI_SESSION_ID": current_session.upper()}
        accepted = {"ok": True, "command": {"requestId": "origin-one", "status": "accepted"}}
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "back", "--request-id", "origin-one"],
            FakeResponse(clients(first, second)),
            FakeResponse(accepted),
            environ=environment,
        )
        self.assertEqual(status, 6, error)
        self.assertIn("/ui/clients/ui_second/commands", opener.requests[1]["url"])

    def test_duplicate_current_pi_session_matches_remain_ambiguous(self):
        session_id = "01a0ae0a-e4fe-7c6a-b6d6-fc6a56f891d2"
        first = selecting_ui_client("ui_first", session_id, kind="pane")
        second = selecting_ui_client("ui_second", session_id.upper(), kind="hud-chat")
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "back", "--request-id", "duplicate-origin"],
            FakeResponse(clients(first, second)),
            environ={**self.environ, "PI_SESSION_ID": session_id},
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "ambiguous_ui_client")
        self.assertEqual(error["error"]["details"]["candidates"], ["ui_first", "ui_second"])
        self.assertEqual(len(opener.requests), 1)

    def test_invalid_or_unmatched_pi_session_does_not_choose_receiver(self):
        first = selecting_ui_client(
            "ui_first", "11111111-2222-3333-4444-555555555555"
        )
        second = selecting_ui_client(
            "ui_second", "66666666-7777-8888-9999-aaaaaaaaaaaa"
        )
        for pi_session_id in (
            "not-a-uuid",
            "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
        ):
            with self.subTest(pi_session_id=pi_session_id):
                status, output, error, opener = self.run_cli(
                    [
                        "--control-machine", "alpha", "ui", "back",
                        "--request-id", "unmatched-origin",
                    ],
                    FakeResponse(clients(first, second)),
                    environ={**self.environ, "PI_SESSION_ID": pi_session_id},
                )
                self.assertEqual(status, 5)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "ambiguous_ui_client")
                self.assertEqual(len(opener.requests), 1)

    def test_pi_session_fallback_never_matches_a_bare_pane_id(self):
        session_id = "01a0ae0a-e4fe-7c6a-b6d6-fc6a56f891d2"
        bare_pane = ui_client("ui_first")
        bare_pane["state"]["selection"] = {"kind": "pane", "paneId": session_id}
        second = ui_client("ui_second")
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "back", "--request-id", "bare-pane"],
            FakeResponse(clients(bare_pane, second)),
            environ={**self.environ, "PI_SESSION_ID": session_id},
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "ambiguous_ui_client")
        self.assertEqual(len(opener.requests), 1)

    def test_pi_session_fallback_requires_selection_and_known_kind(self):
        session_id = "01a0ae0a-e4fe-7c6a-b6d6-fc6a56f891d2"
        missing_kind = ui_client("ui_first")
        missing_kind["state"]["selection"] = {"sessionId": session_id}
        missing_selection = ui_client("ui_second")
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "back", "--request-id", "missing-state"],
            FakeResponse(clients(missing_kind, missing_selection)),
            environ={**self.environ, "PI_SESSION_ID": session_id},
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "ambiguous_ui_client")
        self.assertEqual(len(opener.requests), 1)

    def test_unavailable_explicit_or_environment_hint_never_uses_pi_fallback(self):
        session_id = "01a0ae0a-e4fe-7c6a-b6d6-fc6a56f891d2"
        first = selecting_ui_client("ui_first", session_id)
        second = ui_client("ui_second")
        cases = (
            (["--client", "ui_missing"], self.environ),
            ([], {**self.environ, "HERDR_UI_CLIENT_ID": "ui_missing"}),
        )
        for arguments, base_environment in cases:
            with self.subTest(arguments=arguments, environment=base_environment):
                status, output, error, opener = self.run_cli(
                    [
                        "--control-machine", "alpha", "ui", "back", *arguments,
                        "--request-id", "missing-hint",
                    ],
                    FakeResponse(clients(first, second)),
                    environ={**base_environment, "PI_SESSION_ID": session_id},
                )
                self.assertEqual(status, 5)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "ui_client_unavailable")
                self.assertEqual(len(opener.requests), 1)

    def test_wait_timeout_returns_receipt_on_stdout_with_nonzero_status(self):
        receiver = ui_client("ui_one")
        accepted = {"ok": True, "command": {"requestId": "wait-one", "status": "accepted"}}
        running = {"ok": True, "command": {"requestId": "wait-one", "status": "running"}}
        clock = JumpClock()
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "forward", "--client", "ui_one",
                "--request-id", "wait-one", "--wait", "1",
            ],
            FakeResponse(clients(receiver)),
            FakeResponse(accepted),
            FakeResponse(running),
            clock=clock,
        )
        self.assertEqual(status, 6)
        self.assertIsNone(error)
        self.assertTrue(output["timedOut"])
        self.assertEqual(output["command"]["status"], "running")
        self.assertEqual(len(opener.requests), 3)

    def test_ui_receipt_does_not_require_an_online_receiver(self):
        pending = {"ok": True, "command": {"requestId": "recover-one", "status": "accepted"}}
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "receipt", "recover-one"],
            FakeResponse(pending),
        )
        self.assertEqual(status, 6)
        self.assertIsNone(error)
        self.assertEqual(output["command"]["status"], "accepted")
        self.assertEqual(len(opener.requests), 1)
        self.assertIn("/api/v1/ui/commands/recover-one", opener.requests[0]["url"])

        unknown = {
            "ok": True,
            "command": {"requestId": "recover-two", "status": "outcome_unknown"},
        }
        status, output, error, opener = self.run_cli(
            ["--control-machine", "alpha", "ui", "receipt", "recover-two"],
            FakeResponse(unknown),
        )
        self.assertEqual(status, 5)
        self.assertEqual(output["command"]["status"], "outcome_unknown")
        self.assertEqual(len(opener.requests), 1)

    def test_conflict_is_json_on_stderr_and_is_never_retried(self):
        receiver = ui_client("ui_one")
        conflict = urllib.error.HTTPError(
            "https://alpha.example.test/api/v1/ui/clients/ui_one/commands",
            409,
            "Conflict",
            {},
            io.BytesIO(b'{"ok":false,"error":{"code":"request_id_conflict","message":"Different payload"}}'),
        )
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "back", "--client", "ui_one",
                "--request-id", "same-request",
            ],
            FakeResponse(clients(receiver)),
            conflict,
        )
        self.assertEqual(status, 4)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "request_id_conflict")
        self.assertEqual(len(opener.requests), 2)

    def test_ui_dry_run_never_enqueues_and_still_prints_request_id(self):
        receiver = ui_client("ui_one")
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "ui", "segment", "activity",
                "--client", "ui_one", "--request-id", "segment-plan", "--dry-run",
            ],
            FakeResponse(clients(receiver)),
        )
        self.assertEqual(status, 0, error)
        self.assertTrue(output["dryRun"])
        self.assertEqual(output["requestId"], "segment-plan")
        self.assertEqual(output["command"]["parameters"], {"segment": "activity"})
        self.assertEqual(len(opener.requests), 1)

    def test_unified_actions_can_select_ui_domain_without_data_machine(self):
        receiver = ui_client("ui_one")
        advertised = {"ok": True, "serverId": "srv_alpha", "actions": receiver["actions"]}
        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "actions", "describe", "ui.segment",
                "--client", "ui_one",
            ],
            FakeResponse(clients(receiver)),
            FakeResponse(advertised),
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(output["action"]["id"], "ui.segment")
        self.assertEqual(len(opener.requests), 2)

        status, output, error, opener = self.run_cli(
            [
                "--control-machine", "alpha", "actions", "invoke", "ui.settings",
                "--ui", "--client", "ui_one", "--dry-run", "--request-id", "settings-plan",
            ],
            FakeResponse(clients(receiver)),
        )
        self.assertEqual(status, 0, error)
        self.assertTrue(output["dryRun"])
        self.assertEqual(output["command"]["action"], "ui.settings")
        self.assertEqual(len(opener.requests), 1)

    def test_no_confirmation_flag_exists_for_ui_or_resource_mutations(self):
        for arguments in (
            ["--control-machine", "alpha", "ui", "back", "--confirm"],
            ["--machine", "alpha", "workspace", "create", "--name", "X", "--cwd", "/tmp/x", "--confirm"],
        ):
            with self.subTest(arguments=arguments):
                status, output, error, opener = self.run_cli(arguments)
                self.assertEqual(status, 2)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "invalid_arguments")
                self.assertEqual(opener.requests, [])

    def test_chat_create_propagates_caller_session_and_uses_one_mutation(self):
        inspected = resource("workspace", "w1")
        completed = {
            "ok": True,
            "operation": {
                "requestId": "chat-create-one",
                "action": "chat.create",
                "status": "completed",
                "result": {"target": {"kind": "pane", "paneId": "w1:p3", "terminalId": "term-3", "sessionId": "session-3"}},
            },
        }
        environment = {**self.environ, "PI_SESSION_ID": "pi-parent-session"}
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "chat", "create", "--workspace", "w1",
                "--name", "Child", "--request-id", "chat-create-one",
            ],
            FakeResponse({"ok": True, "result": inspected}),
            FakeResponse(completed),
            environ=environment,
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(output["requestId"], "chat-create-one")
        mutation = json.loads(opener.requests[1]["body"])
        self.assertEqual(mutation["parameters"]["parentSessionId"], "pi-parent-session")
        self.assertEqual(
            [request["url"].endswith("/api/v1/control/actions") for request in opener.requests].count(True),
            1,
        )

    def test_create_then_open_preserves_creation_when_ui_selection_fails(self):
        creation = {
            "ok": True,
            "operation": {
                "requestId": "workspace-one",
                "action": "workspace.create",
                "status": "completed",
                "result": {"target": {"kind": "workspace", "serverId": "srv_alpha", "workspaceId": "w9"}},
            },
        }
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "--control-machine", "alpha", "workspace", "create",
                "--name", "Synthetic", "--cwd", "/tmp/synthetic", "--request-id", "workspace-one",
                "--open", "--open-request-id", "workspace-open-one",
            ],
            FakeResponse(creation),
            FakeResponse(clients(ui_client("ui_a"), ui_client("ui_b"))),
        )
        self.assertEqual(status, 5)
        self.assertIsNone(error)
        self.assertFalse(output["ok"])
        self.assertEqual(output["creation"]["operation"]["status"], "completed")
        self.assertEqual(output["navigation"]["error"]["code"], "ambiguous_ui_client")
        self.assertEqual(
            output["navigation"]["error"]["details"]["requestId"], "workspace-open-one"
        )
        self.assertEqual(
            [request["url"].endswith("/api/v1/control/actions") for request in opener.requests].count(True),
            1,
        )
        self.assertEqual(len(opener.requests), 2)

    def test_create_open_derives_recoverable_navigation_id_before_receiver_failure(self):
        creation = {
            "ok": True,
            "operation": {
                "requestId": "workspace-no-control",
                "action": "workspace.create",
                "status": "completed",
                "result": {"target": {"kind": "workspace", "workspaceId": "w10"}},
            },
        }
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "workspace", "create", "--name", "Synthetic",
                "--cwd", "/tmp/synthetic", "--request-id", "workspace-no-control", "--open",
            ],
            FakeResponse(creation),
        )
        self.assertEqual(status, 2)
        self.assertIsNone(error)
        self.assertEqual(output["creation"]["operation"]["status"], "completed")
        expected = "open_" + hashlib.sha256(b"workspace-no-control").hexdigest()[:32]
        self.assertEqual(output["navigation"]["error"]["details"]["requestId"], expected)
        self.assertEqual(len(opener.requests), 1)

    def test_mutation_transport_failure_reports_original_request_id(self):
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "workspace", "create", "--name", "Synthetic",
                "--cwd", "/tmp/synthetic", "--request-id", "workspace-uncertain",
            ],
            urllib.error.URLError("synthetic disconnect"),
        )
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "herdr_unavailable")
        self.assertEqual(error["error"]["details"]["requestId"], "workspace-uncertain")
        self.assertEqual(len(opener.requests), 1)

    def test_parameters_file_is_json_only_and_resource_receipt_controls_exit(self):
        parameters = self.write_json("parameters.json", {"starred": True})
        inspected = resource("pane", "w1:p2", terminalId="term-2", sessionId="session-2")
        completed = {
            "ok": True,
            "operation": {
                "requestId": "star-one", "action": "pane.star", "status": "completed",
                "result": {"target": inspected["target"]},
            },
        }
        status, output, error, opener = self.run_cli(
            [
                "--machine", "alpha", "actions", "invoke", "pane.star", "--pane", "w1:p2",
                "--parameters-file", str(parameters), "--request-id", "star-one",
            ],
            FakeResponse({"ok": True, "result": inspected}),
            FakeResponse(completed),
        )
        self.assertEqual(status, 0, error)
        self.assertEqual(output["requestId"], "star-one")
        self.assertEqual(json.loads(opener.requests[1]["body"])["parameters"], {"starred": True})


if __name__ == "__main__":
    unittest.main()
