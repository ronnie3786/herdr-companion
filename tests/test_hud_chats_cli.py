import contextlib
import io
import json
import unittest
import urllib.parse
from unittest.mock import Mock

from scripts.herdr_hud_chats_cli import main


PRIMARY = "ui_11111111-1111-4111-8111-111111111111"
SECONDARY = "ui_22222222-2222-4222-8222-222222222222"
CAPABILITIES = {
    "ok": True,
    "version": 1,
    "serverId": "srv_synthetic",
    "capabilities": ["agent-control-v1", "discovery-v1", "chat-tab-colors-v1"],
    "chatTabColorStaleAfterSeconds": 60,
}


def entry(client_id, color, label, *, status="assigned", stale=False):
    return {
        "clientId": client_id,
        "color": color,
        "label": label,
        "status": status,
        "updatedAt": "2030-01-01T00:00:00Z",
        "lastSeenAt": "2030-01-01T00:00:00Z",
        "stale": stale,
    }


def terminal_row(identifier, entries):
    return {
        "kind": "pane",
        "id": identifier,
        "title": identifier,
        "updatedAt": "2030-01-01T00:00:00Z",
        "status": "live",
        "target": {
            "kind": "pane",
            "serverId": "srv_synthetic",
            "paneId": identifier,
        },
        "matchEvidence": [],
        "openModes": ["chat", "terminal", "git", "skills"],
        "chatTabColors": entries,
    }


def discovery(*results, next_offset=None):
    return {
        "ok": True,
        "serverId": "srv_synthetic",
        "results": list(results),
        "nextOffset": next_offset,
        "coverage": {"liveTopology": {"searched": True}},
        "generatedAt": "2030-01-01T00:00:00Z",
    }


class RouteOpener:
    """Route canned JSON by path and record every request."""

    def __init__(self, responses):
        self.responses = dict(responses)
        self.requests = []

    def __call__(self, request, *, timeout):
        parsed = urllib.parse.urlsplit(request.full_url)
        self.requests.append(
            {
                "url": request.full_url,
                "path": parsed.path,
                "query": urllib.parse.parse_qs(parsed.query),
                "method": request.get_method(),
                "headers": {key.lower(): value for key, value in request.header_items()},
                "timeout": timeout,
            }
        )
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(self.responses[parsed.path]).encode("utf-8")
        response.geturl.return_value = request.full_url
        return response


class HudChatsCLITests(unittest.TestCase):
    def setUp(self):
        self.environ = {
            "HERDR_HARNESS_URL": "http://localhost:9092",
            "HERDR_HARNESS_API_TOKEN": "fixture-secret",
        }

    def run_cli(self, arguments, *, opener, routes=None):
        opener = opener if opener is not None else RouteOpener(routes or {})
        output, error = io.StringIO(), io.StringIO()
        status = main(
            arguments, environ=self.environ, opener=opener, stdout=output, stderr=error
        )
        return (
            status,
            json.loads(output.getvalue()) if output.getvalue() else None,
            json.loads(error.getvalue()) if error.getvalue() else None,
            opener,
        )

    def test_read_only_search_and_show_use_private_auth_and_pagination(self):
        for arguments, suffix in [(["search", "herb garden"], "?offset=0&q=herb+garden"),
                                  (["--offset", "50", "show", "agr_0123456789ab"], "/agr_0123456789ab?offset=50")]:
            response = Mock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            response.read.return_value = b'{"ok":true,"chats":[]}'
            expected_url = "http://localhost:9092/api/v1/hud-chats" + suffix
            response.geturl.return_value = expected_url
            opener = Mock(return_value=response)
            output = io.StringIO()
            self.assertEqual(main(arguments, environ={"HERDR_HARNESS_URL": "http://localhost:9092",
                                                      "HERDR_HARNESS_API_TOKEN": "fixture-secret"},
                                  opener=opener, stdout=output), 0)
            request = opener.call_args.args[0]
            self.assertEqual(request.full_url, expected_url)
            self.assertEqual(request.method, "GET")
            self.assertEqual(request.get_header("Authorization"), "Bearer fixture-secret")
            self.assertNotIn("fixture-secret", output.getvalue())

    def test_missing_credentials_and_unsafe_origin_never_send(self):
        for env in ({}, {"HERDR_HARNESS_URL": "http://example.invalid", "HERDR_HARNESS_API_TOKEN": "fixture-secret"}):
            opener, error = Mock(), io.StringIO()
            self.assertEqual(main(["list"], environ=env, opener=opener, stderr=error), 2)
            opener.assert_not_called()
            self.assertFalse(json.loads(error.getvalue())["ok"])
            self.assertNotIn("fixture-secret", error.getvalue())

    def test_saved_list_keeps_its_path_and_envelope(self):
        saved = {
            "ok": True,
            "chats": [
                {
                    "id": "agr_000000000001",
                    "title": "Synthetic Saved Chat",
                    "updatedAt": "2030-01-01T00:00:00Z",
                    "status": "promoted",
                    "promotedPaneId": "w1:p9",
                }
            ],
            "nextOffset": None,
        }
        opener = RouteOpener({"/api/v1/hud-chats": saved})
        status, output, error, opener = self.run_cli(["list"], opener=opener)
        self.assertEqual(status, 0, error)
        self.assertEqual(opener.requests[0]["method"], "GET")
        self.assertEqual(
            opener.requests[0]["url"], "http://localhost:9092/api/v1/hud-chats?offset=0"
        )
        # Saved history is never joined to a terminal tab or given color metadata.
        self.assertEqual(output, saved)
        self.assertNotIn("chatTabColors", json.dumps(output))
        self.assertEqual(len(opener.requests), 1)

    def test_terminal_scope_reads_discovery_with_capability_check(self):
        opener = RouteOpener(
            {
                "/api/v1/control/capabilities": CAPABILITIES,
                "/api/v1/discovery": discovery(
                    terminal_row("w1:p1", [entry(PRIMARY, "sage", "Synthetic Release Group")]),
                    next_offset=50,
                ),
            }
        )
        status, output, error, opener = self.run_cli(
            ["list", "--scope", "terminal"], opener=opener
        )
        self.assertEqual(status, 0, error)
        self.assertEqual([row["method"] for row in opener.requests], ["GET", "GET"])
        self.assertEqual(
            [row["path"] for row in opener.requests],
            ["/api/v1/control/capabilities", "/api/v1/discovery"],
        )
        self.assertEqual(
            opener.requests[1]["headers"]["authorization"], "Bearer fixture-secret"
        )
        query = opener.requests[1]["query"]
        self.assertEqual(query["kind"], ["chats"])
        self.assertEqual(query["chatScope"], ["terminal"])
        self.assertEqual(query["offset"], ["0"])
        self.assertNotIn("color", query)
        self.assertEqual(output["scope"], "terminal")
        self.assertEqual(output["nextOffset"], 50)
        self.assertEqual(output["coverage"], {"liveTopology": {"searched": True}})
        self.assertEqual([row["id"] for row in output["results"]], ["w1:p1"])
        self.assertNotIn("groups", output)

    def test_offset_is_accepted_before_or_after_list_and_search(self):
        cases = (
            (["list", "--scope", "terminal", "--offset", "2"], "/api/v1/discovery", "2"),
            (["--offset", "2", "list", "--scope", "terminal"], "/api/v1/discovery", "2"),
            (["search", "planning", "--scope", "terminal", "--offset", "3"], "/api/v1/discovery", "3"),
            (["--offset", "3", "search", "planning", "--scope", "terminal"], "/api/v1/discovery", "3"),
            (["list", "--offset", "4"], "/api/v1/hud-chats", "4"),
            (["--offset", "4", "search", "planning"], "/api/v1/hud-chats", "4"),
        )
        for arguments, path, expected in cases:
            with self.subTest(arguments=arguments):
                opener = RouteOpener(
                    {
                        "/api/v1/control/capabilities": CAPABILITIES,
                        "/api/v1/discovery": discovery(
                            terminal_row(
                                "w1:p1",
                                [entry(PRIMARY, "sage", "Synthetic Release Group")],
                            )
                        ),
                        "/api/v1/hud-chats": {"ok": True, "chats": [], "nextOffset": None},
                    }
                )
                status, output, error, opener = self.run_cli(arguments, opener=opener)
                self.assertEqual(status, 0, error)
                request = next(row for row in opener.requests if row["path"] == path)
                self.assertEqual(request["query"]["offset"], [expected])
                self.assertEqual(request["method"], "GET")

        # The range check still applies to the post-subcommand position.
        for arguments in (
            ["list", "--scope", "terminal", "--offset", "100001"],
            ["search", "planning", "--offset", "-1"],
        ):
            with self.subTest(arguments=arguments):
                status, output, error, opener = self.run_cli(arguments, opener=RouteOpener({}))
                self.assertEqual(status, 2)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "invalid_arguments")
                self.assertEqual(opener.requests, [])

    def test_terminal_search_forwards_filters_and_groups_by_label(self):
        opener = RouteOpener(
            {
                "/api/v1/control/capabilities": CAPABILITIES,
                "/api/v1/discovery": discovery(
                    terminal_row(
                        "w1:p1",
                        [
                            entry(PRIMARY, "sage", "Synthesé ✦ Planning"),
                            entry(SECONDARY, "iris", "Synthesé ✦ Planning"),
                        ],
                    )
                ),
            }
        )
        status, output, error, opener = self.run_cli(
            [
                "search", "planning", "--scope", "terminal",
                "--color", "sage",
                "--color-label", "Synthesé ✦ Planning",
                "--color-client", PRIMARY,
                "--group-by", "label",
            ],
            opener=opener,
        )
        self.assertEqual(status, 0, error)
        query = opener.requests[1]["query"]
        self.assertEqual(query["q"], ["planning"])
        self.assertEqual(query["color"], ["sage"])
        self.assertEqual(query["colorLabel"], ["Synthesé ✦ Planning"])
        self.assertEqual(query["colorClientId"], [PRIMARY])
        self.assertEqual(output["scope"], "terminal")
        self.assertEqual(output["groupingScope"], "page")
        self.assertEqual(len(output["groups"]), 1)
        group = output["groups"][0]
        self.assertEqual(group["clientId"], PRIMARY)
        self.assertEqual(group["status"], "assigned")
        self.assertEqual(group["key"], "synthesé ✦ planning")
        self.assertEqual(group["colors"], ["sage"])
        self.assertEqual(group["count"], 1)
        self.assertEqual(group["scope"], "page")
        self.assertEqual(group["members"][0]["chatTabColor"]["label"], "Synthesé ✦ Planning")
        self.assertEqual(
            group["members"][0]["result"]["target"]["paneId"], "w1:p1"
        )
        self.assertNotIn("fixture-secret", json.dumps(output))

    def test_terminal_scope_requires_the_capability_and_never_discovers(self):
        opener = RouteOpener(
            {
                "/api/v1/control/capabilities": {
                    "ok": True,
                    "capabilities": ["agent-control-v1", "discovery-v1"],
                }
            }
        )
        status, output, error, opener = self.run_cli(
            ["list", "--scope", "terminal", "--color", "iris"], opener=opener
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "chat_tab_colors_unsupported")
        self.assertIn("chat-tab-colors-v1", error["error"]["message"])
        self.assertEqual(
            [row["path"] for row in opener.requests], ["/api/v1/control/capabilities"]
        )

    def test_saved_scope_rejects_terminal_only_options_with_suggestion(self):
        for arguments in (
            ["list", "--color", "iris"],
            ["list", "--color-label", "Synthetic Release Group"],
            ["search", "planning", "--color-client", PRIMARY],
            ["list", "--scope", "saved", "--group-by", "color"],
        ):
            with self.subTest(arguments=arguments):
                status, output, error, opener = self.run_cli(
                    arguments, opener=RouteOpener({})
                )
                self.assertEqual(status, 2)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "invalid_arguments")
                self.assertIn("--scope terminal", error["error"]["message"])
                self.assertEqual(opener.requests, [])

    def test_list_help_needs_no_credentials_and_documents_terminal_options(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as context:
                main(["list", "--help"], environ={})
        self.assertEqual(context.exception.code, 0)
        rendered = stdout.getvalue()
        self.assertIn("--scope", rendered)
        self.assertIn("--color", rendered)
        self.assertIn("--group-by", rendered)
        self.assertIn("terminal", rendered)


if __name__ == "__main__":
    unittest.main()
