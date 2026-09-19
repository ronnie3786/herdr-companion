"""HTTP contract of the Code Factory dashboard: page, state JSON, auth, actions, errors, hardening, host resolution."""
from __future__ import annotations

import json
import socket
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.code_factory.dashboard import (
    CONTENT_SECURITY_POLICY,
    DEFAULT_STATIC_PATH,
    DashboardServer,
    host_resolves,
    resolve_dashboard_host,
    tailscale_ipv4,
)
from herdr_harness.code_factory.errors import CodeFactoryError
from herdr_harness.code_factory.store import CodeFactoryStore

TOKEN = "dash-secret-token"


class FakeFactory:
    """Records ``action`` calls; ``fail_with`` makes the next call raise; ``replies`` override results."""

    def __init__(self):
        self.calls: list[tuple[int | None, str]] = []
        self.fail_with: CodeFactoryError | None = None
        self.replies: dict[str, object] = {}

    def action(self, number, action):
        self.calls.append((number, action))
        if self.fail_with is not None:
            error, self.fail_with = self.fail_with, None
            raise error
        if action in self.replies:
            return self.replies[action]
        return {"number": number, "queued": action} if number is not None else {"started": True}

    def poll_once(self):
        return {"discovered": 0}

    def run_issue(self, number):
        return None

    def run_release_batch(self):
        return None


class FakeSettings:
    def public_summary(self):
        return {
            "repository": "owner/repo", "trigger_label": "herdr-autofix", "planner_model": "openai-codex/gpt-6-astra",
            "implementer_model": "ollama-cloud/deepseek-v4.1-flash:cloud", "release_enabled": True,
            "release_channel": "preview", "max_review_rounds": 3, "poll_seconds": 60,
        }


def seed(store: CodeFactoryStore) -> None:
    store.upsert_issue({
        "number": 12, "title": "Crash when opening the HUD", "kind": "bug", "author": "your-username",
        "url": "https://github.com/owner/repo/issues/12", "labels": ["bug", "herdr-autofix"],
        "stage": "review", "branch": "codefactory/issue-12", "worktreePath": "/tmp/worktrees/issue-12",
        "prNumber": 34, "prUrl": "https://github.com/owner/repo/pull/34", "headSha": "abc123abc123",
        "ciStatus": "success", "reviewRound": 1, "planSummary": "Guard the HUD window controller against nil.",
    })
    store.add_session("s-plan", 12, "planner", "openai-codex/gpt-6-astra", "xhigh")
    store.finish_session("s-plan", 0, 0.12, "Planned two tasks")
    store.add_event(12, "plan", "success", "Plan accepted")
    store.add_event(12, "review", "info", "Review round 1 started")
    store.upsert_issue({
        "number": 13, "title": "Add a dark mode toggle", "kind": "feature", "author": "your-username",
        "url": "https://github.com/owner/repo/issues/13", "labels": ["enhancement", "herdr-autofix"],
        "status": "blocked", "stage": "plan", "blockedReason": "human_question", "error": "Which pane should host it?",
    })
    store.upsert_issue({
        "number": 14, "title": "Typo in settings", "kind": "bug", "author": "your-username",
        "url": "https://github.com/owner/repo/issues/14", "labels": ["bug"], "status": "done", "stage": "done",
        "worktreePath": "/tmp/worktrees/issue-14", "worktreeCleaned": True, "releaseTag": "macos-v0.20.1-beta.1",
        "releaseVersion": "0.20.1-beta.1", "releaseUrl": "https://github.com/owner/repo/releases/tag/macos-v0.20.1-beta.1",
    })
    store.upsert_release("macos-v0.20.1-beta.1", version="0.20.1-beta.1", channel="preview", status="published",
                         sourceSha="def456", url="https://github.com/owner/repo/releases/tag/macos-v0.20.1-beta.1",
                         issueNumbers=[14])
    store.set_daemon("started_at", "2026-09-18T12:00:00Z")
    store.set_daemon("last_poll_at", "2026-09-18T12:00:30Z")


def read_until_closed(sock: socket.socket, timeout: float = 5.0) -> tuple[bytes, bool]:
    """Read everything the server sends; returns ``(data, closed)`` where closed means EOF arrived."""
    sock.settimeout(timeout)
    chunks: list[bytes] = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            return b"".join(chunks), False
        if not chunk:
            return b"".join(chunks), True
        chunks.append(chunk)
    return b"".join(chunks), False


def split_response(raw: bytes) -> tuple[int, dict[str, str], bytes]:
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1").split("\r\n")
    status = int(lines[0].split(" ")[1])
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return status, headers, body


class DashboardTestCase(unittest.TestCase):
    token = ""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = CodeFactoryStore(Path(self.temp.name) / "ledger.sqlite3")
        self.addCleanup(self.store.close)
        seed(self.store)
        self.factory = FakeFactory()
        self.messages: list[str] = []
        self.server = DashboardServer(self.store, self.factory, host="127.0.0.1", port=0, token=self.token,
                                      settings=FakeSettings(), log=self.messages.append)
        self.server.start()
        self.addCleanup(self.server.stop)

    def request(self, path, *, method="GET", body=None, token=None, raw=None, headers=None):
        request_headers = {"Accept": "application/json"}
        data = None
        if raw is not None:
            data = raw
            request_headers["Content-Type"] = "application/json"
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        if token:
            request_headers["Authorization"] = "Bearer " + token
        request_headers.update(headers or {})
        request = urllib.request.Request(self.server.url.rstrip("/") + path, data=data, method=method, headers=request_headers)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers), error.read()

    def json_request(self, path, **kwargs):
        status, headers, body = self.request(path, **kwargs)
        return status, headers, json.loads(body.decode("utf-8"))

    def raw_request(self, text: str, *, server=None):
        """Send a hand-written request over one socket and return ``(status, headers, body, closed)``."""
        server = server or self.server
        with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
            sock.sendall(text.encode("iso-8859-1"))
            raw, closed = read_until_closed(sock, timeout=3.0)
        status, headers, body = split_response(raw)
        return status, headers, body, closed


class PageTests(DashboardTestCase):
    def test_root_serves_the_dashboard_page_with_strict_headers(self):
        for path in ("/", "/index.html", "/?tab=issues"):
            status, headers, body = self.request(path)
            self.assertEqual(status, 200, path)
            self.assertEqual(headers["Content-Type"], "text/html; charset=utf-8")
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
            self.assertEqual(headers["Content-Security-Policy"], CONTENT_SECURITY_POLICY)
            self.assertEqual(headers["X-Frame-Options"], "DENY")
            text = body.decode("utf-8")
            self.assertIn("Herdr Code Factory", text)
            for stat in ("active", "blocked", "failed", "released", "done", "worktreesPending"):
                self.assertIn(f'data-stat="{stat}"', text)
            self.assertIn('className: "stepper', text)
            self.assertIn("Report a Bug or Request a Feature", text)
            self.assertIn("herdr.code-factory.token", text)

    def test_csp_forbids_framing_and_navigation_tricks(self):
        for directive in ("frame-ancestors 'none'", "base-uri 'none'", "form-action 'self'", "connect-src 'self'"):
            self.assertIn(directive, CONTENT_SECURITY_POLICY)

    def test_page_is_self_contained(self):
        text = DEFAULT_STATIC_PATH.read_text(encoding="utf-8")
        self.assertNotIn("<script src=", text)
        self.assertNotIn("<link rel=\"stylesheet\"", text)
        self.assertNotIn("https://fonts", text)
        self.assertIn('@media (prefers-color-scheme: light)', text)
        self.assertIn(':root[data-theme="light"]', text)
        self.assertIn("#AAA6F4", text)
        self.assertIn("#191A23", text)
        self.assertNotIn(".innerHTML", text)

    def test_page_reads_action_results_and_keeps_operator_state(self):
        """The page must not paint "started"/"queued" unconditionally, hide a manually opened token form, or rebuild an unchanged drawer."""
        text = DEFAULT_STATIC_PATH.read_text(encoding="utf-8")
        self.assertIn("payload.releaseStarted === false", text)
        self.assertIn("A release batch is already running", text)
        self.assertIn("payload.queued === false", text)
        self.assertIn("state.tokenPromptForced", text)
        self.assertIn("if (state.tokenPromptForced) { hideTokenPrompt(); }", text)
        self.assertIn("state.drawerSignature", text)
        self.assertIn("openDetails", text)
        self.assertNotIn("-webkit-line-clamp: 3", text)
        problem = text[text.index(".problem {"):text.index(".problem.blocked")]
        self.assertIn("white-space: pre-wrap", problem)
        self.assertIn("overflow: auto", problem)

    def test_missing_static_file_is_a_clear_server_error(self):
        self.server.static_path = Path(self.temp.name) / "missing.html"
        status, _, payload = self.json_request("/")
        self.assertEqual(status, 500)
        self.assertEqual(payload["error"]["code"], "static_missing")

    def test_unknown_routes_are_json_404(self):
        for path in ("/nope", "/api/nope", "/api/issues/", "/api/issues/abc", "/static/x.js"):
            status, headers, payload = self.json_request(path)
            self.assertEqual(status, 404, path)
            self.assertEqual(payload["error"]["code"], "not_found")
            self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
            self.assertEqual(headers["Cache-Control"], "no-store")

    def test_wrong_methods_are_405(self):
        status, _, payload = self.json_request("/api/state", method="POST", body={})
        self.assertEqual(status, 405)
        status, _, payload = self.json_request("/api/issues/12/actions", method="GET")
        self.assertEqual(status, 405)
        status, _, payload = self.json_request("/", method="POST", body={})
        self.assertEqual(status, 405)


class StateTests(DashboardTestCase):
    def test_state_combines_snapshot_daemon_and_settings(self):
        status, headers, payload = self.json_request("/api/state")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        self.assertTrue(payload["ok"])
        self.assertEqual({issue["number"] for issue in payload["issues"]}, {12, 13, 14})
        self.assertEqual(payload["stats"]["active"], 1)
        self.assertEqual(payload["stats"]["blocked"], 1)
        self.assertEqual(payload["stats"]["released"], 1)
        self.assertEqual(payload["stats"]["worktreesPending"], 1)
        self.assertEqual(payload["daemon"]["lastPollAt"], "2026-09-18T12:00:30Z")
        self.assertEqual(payload["daemon"]["dashboardUrl"], self.server.url)
        self.assertEqual(payload["settings"]["repository"], "owner/repo")
        self.assertEqual(payload["settings"]["dashboardUrl"], self.server.url)
        self.assertEqual(payload["settings"]["max_review_rounds"], 3)
        self.assertEqual(payload["releases"][0]["tag"], "macos-v0.20.1-beta.1")
        self.assertEqual(payload["releases"][0]["issueNumbers"], [14])
        issue = next(item for item in payload["issues"] if item["number"] == 12)
        self.assertEqual(issue["stageLabel"], "Reviewing (Astra)")
        self.assertEqual(issue["sessions"][0]["costUSD"], 0.12)
        self.assertEqual(issue["events"][0]["message"], "Review round 1 started")
        self.assertNotIn("planJson", issue)

    def test_state_without_settings_object_still_carries_dashboard_url(self):
        self.server.settings = None
        _, _, payload = self.json_request("/api/state")
        self.assertEqual(payload["settings"], {"dashboardUrl": self.server.url})

    def test_daemon_dashboard_url_from_store_wins(self):
        self.store.set_daemon("dashboard_url", "http://dashboard.example.invalid:9097/")
        _, _, payload = self.json_request("/api/state")
        self.assertEqual(payload["daemon"]["dashboardUrl"], "http://dashboard.example.invalid:9097/")

    def test_issue_detail_and_404(self):
        status, _, payload = self.json_request("/api/issues/12")
        self.assertEqual(status, 200)
        self.assertEqual(payload["issue"]["number"], 12)
        self.assertEqual(payload["issue"]["planJson"], None)
        self.assertEqual([event["message"] for event in payload["issue"]["events"]],
                         ["Review round 1 started", "Plan accepted"])
        self.assertEqual(payload["issue"]["sessions"][0]["role"], "planner")
        status, _, payload = self.json_request("/api/issues/999")
        self.assertEqual(status, 404)
        self.assertEqual(payload["error"]["code"], "not_found")
        status, _, payload = self.json_request("/api/issues/0")
        self.assertEqual(status, 404)


class ActionTests(DashboardTestCase):
    def test_issue_action_is_routed_to_the_factory(self):
        status, _, payload = self.json_request("/api/issues/13/actions", method="POST", body={"action": "retry"})
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["action"], "retry")
        self.assertEqual(payload["issue"]["number"], 13)
        self.assertEqual(self.factory.calls, [(13, "retry")])

    def test_issue_action_passes_the_queued_flag_through(self):
        self.factory.replies["retry"] = {"ok": True, "action": "retry", "issue": {"number": 13}, "queued": False}
        status, _, payload = self.json_request("/api/issues/13/actions", method="POST", body={"action": "retry"})
        self.assertEqual(status, 200)
        self.assertIs(payload["queued"], False)
        self.assertEqual(payload["issue"]["number"], 13)
        self.factory.replies["retry"] = {"ok": True, "action": "retry", "issue": {"number": 13}, "queued": True}
        _, _, payload = self.json_request("/api/issues/13/actions", method="POST", body={"action": "retry"})
        self.assertIs(payload["queued"], True)
        self.factory.replies["cleanup"] = None
        _, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "cleanup"})
        self.assertNotIn("queued", payload)

    def test_issue_action_returns_fresh_issue_when_factory_returns_nothing(self):
        self.factory.action = lambda number, action: None  # type: ignore[assignment]
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "cleanup"})
        self.assertEqual(status, 200)
        self.assertEqual(payload["issue"]["title"], "Crash when opening the HUD")

    def test_invalid_actions_and_bodies_are_400(self):
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "explode"})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "invalid_action")
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={})
        self.assertEqual(status, 400)
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", raw=b"{not json")
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "invalid_request")
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", raw=b"[1, 2]")
        self.assertEqual(status, 400)
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", raw=b"{" + b" " * 70_000 + b"}")
        self.assertEqual(status, 400)
        self.assertEqual(self.factory.calls, [])

    def test_action_on_unknown_issue_is_404(self):
        status, _, payload = self.json_request("/api/issues/999/actions", method="POST", body={"action": "retry"})
        self.assertEqual(status, 404)
        self.assertEqual(self.factory.calls, [])

    def test_factory_errors_map_to_status_codes(self):
        self.factory.fail_with = CodeFactoryError("retry is only allowed when blocked or failed", code="invalid_request")
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "retry"})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["message"], "retry is only allowed when blocked or failed")
        self.factory.fail_with = CodeFactoryError("gh pr merge failed: boom", code="github_failed")
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "skip"})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "github_failed")

    def test_release_retry(self):
        status, _, payload = self.json_request("/api/releases/retry", method="POST", body={})
        self.assertEqual(status, 200)
        self.assertEqual(payload["action"], "release_now")
        self.assertEqual(payload["result"], {"started": True})
        self.assertNotIn("releaseStarted", payload)
        self.assertEqual(self.factory.calls, [(None, "release_now")])
        status, _, _ = self.json_request("/api/releases/retry", method="POST", raw=b"")
        self.assertEqual(status, 200)

    def test_release_retry_reports_a_refused_start(self):
        self.factory.replies["release_now"] = {"ok": True, "action": "release_now", "issue": None, "releaseStarted": False}
        status, _, payload = self.json_request("/api/releases/retry", method="POST", body={})
        self.assertEqual(status, 200)
        self.assertIs(payload["releaseStarted"], False)
        self.assertIs(payload["result"]["releaseStarted"], False)
        self.factory.replies["release_now"] = {"ok": True, "action": "release_now", "issue": None, "releaseStarted": True}
        _, _, payload = self.json_request("/api/releases/retry", method="POST", body={})
        self.assertIs(payload["releaseStarted"], True)

    def test_actions_without_a_factory_are_503(self):
        self.server.factory = None
        status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "retry"})
        self.assertEqual(status, 503)
        self.assertEqual(payload["error"]["code"], "unavailable")
        status, _, payload = self.json_request("/api/releases/retry", method="POST", body={})
        self.assertEqual(status, 503)


class TokenTests(DashboardTestCase):
    token = TOKEN

    def test_api_requires_bearer_token_but_page_does_not(self):
        status, headers, body = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn(b"<!doctype html>", body.lower())
        status, headers, payload = self.json_request("/api/state")
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "unauthorized")
        self.assertEqual(headers["WWW-Authenticate"], 'Bearer realm="Herdr Code Factory"')
        status, _, _ = self.json_request("/api/state", token="wrong")
        self.assertEqual(status, 401)
        status, _, _ = self.json_request("/api/issues/12/actions", method="POST", body={"action": "retry"}, token="wrong")
        self.assertEqual(status, 401)
        self.assertEqual(self.factory.calls, [])
        status, _, payload = self.json_request("/api/state", token=TOKEN)
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])

    def test_authorization_scheme_must_be_bearer(self):
        request = urllib.request.Request(self.server.url + "api/state", headers={"Authorization": "Basic " + TOKEN})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        self.assertEqual(caught.exception.code, 401)


class HardeningTests(DashboardTestCase):
    """Browser-facing protections that apply even when no token is configured."""

    def host(self) -> str:
        return f"127.0.0.1:{self.server.port}"

    def test_post_bodies_must_be_json(self):
        for content_type in (None, "text/plain", "application/x-www-form-urlencoded"):
            lines = [f"POST /api/issues/12/actions HTTP/1.1", f"Host: {self.host()}", "Content-Length: 17"]
            if content_type:
                lines.append(f"Content-Type: {content_type}")
            lines.append("Connection: close")
            status, _, body, _ = self.raw_request("\r\n".join(lines) + "\r\n\r\n" + '{"action":"skip"}')
            self.assertEqual(status, 415, content_type)
            self.assertEqual(json.loads(body)["error"]["code"], "unsupported_media_type")
        status, _, body, _ = self.raw_request(
            f"POST /api/releases/retry HTTP/1.1\r\nHost: {self.host()}\r\nConnection: close\r\n\r\n")
        self.assertEqual(status, 415)
        self.assertEqual(self.factory.calls, [])
        status, _, _ = self.json_request("/api/issues/12/actions", method="POST", body={"action": "skip"},
                                         headers={"Content-Type": "application/json; charset=utf-8"})
        self.assertEqual(status, 200)
        self.assertEqual(self.factory.calls, [(12, "skip")])

    def test_cross_site_requests_are_refused(self):
        origin = f"http://{self.host()}"
        for headers in (
            {"Origin": "https://evil.example"},
            {"Origin": "null"},
            {"Origin": origin, "Sec-Fetch-Site": "cross-site"},
            {"Sec-Fetch-Site": "same-site"},
            {"Origin": f"http://{self.host()}.evil.example"},
        ):
            status, _, payload = self.json_request("/api/issues/12/actions", method="POST", body={"action": "skip"}, headers=headers)
            self.assertEqual(status, 403, headers)
            self.assertEqual(payload["error"]["code"], "forbidden")
        status, _, payload = self.json_request("/api/state", headers={"Origin": "https://evil.example"})
        self.assertEqual(status, 403)
        self.assertEqual(self.factory.calls, [])
        for headers in (
            {"Origin": origin},
            {"Origin": origin.upper()},
            {"Origin": origin, "Sec-Fetch-Site": "same-origin"},
            {"Origin": "https://proxy.example.invalid", "Sec-Fetch-Site": "same-origin"},
            {"Sec-Fetch-Site": "none"},
        ):
            status, _, _ = self.json_request("/api/issues/12/actions", method="POST", body={"action": "skip"}, headers=headers)
            self.assertEqual(status, 200, headers)
        self.assertEqual(len(self.factory.calls), 5)

    def test_foreign_host_names_are_refused(self):
        # A dashboard bound to an IP answers for IP literals, loopback names and tailnet
        # MagicDNS names (``tailscale serve``); any other DNS name is a rebinding attempt.
        # The tailnet example is assembled at runtime so the source never contains one.
        tailnet_name = ".".join(["machine", "example-tailnet", "ts", "net"])
        for host in (self.host(), "localhost", f"localhost:{self.server.port}", "127.0.0.1", "[::1]:9097",
                     f"{tailnet_name}:9097", "api.localhost"):
            status, _, body, _ = self.raw_request(f"GET /api/state HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
            self.assertEqual(status, 200, host)
        for host in ("attacker.example", f"attacker.example:{self.server.port}", "127.0.0.1.attacker.example", "[bad"):
            status, _, body, _ = self.raw_request(f"GET /api/state HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
            self.assertEqual(status, 421, host)
            self.assertEqual(json.loads(body)["error"]["code"], "misdirected_request")
            status, _, _, _ = self.raw_request(f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
            self.assertEqual(status, 421, host)
        status, _, body, _ = self.raw_request("GET /api/state HTTP/1.0\r\n\r\n")
        self.assertEqual(status, 200, "HTTP/1.0 without Host carries no name to rebind")

    def test_configured_host_names_are_accepted(self):
        server = DashboardServer(self.store, self.factory, host="127.0.0.1", port=0, allowed_hosts=("Dashboard.Example.invalid",),
                                 log=self.messages.append).start()
        self.addCleanup(server.stop)
        status, _, _, _ = self.raw_request("GET /api/state HTTP/1.1\r\nHost: dashboard.example.invalid:9097\r\nConnection: close\r\n\r\n", server=server)
        self.assertEqual(status, 200)
        status, _, _, _ = self.raw_request("GET /api/state HTTP/1.1\r\nHost: other.example.invalid\r\nConnection: close\r\n\r\n", server=server)
        self.assertEqual(status, 421)

    def test_oversized_body_closes_the_connection_instead_of_desyncing_it(self):
        request = (f"POST /api/releases/retry HTTP/1.1\r\nHost: {self.host()}\r\nContent-Type: application/json\r\n"
                   "Content-Length: 70002\r\n\r\n")  # the body is deliberately never sent
        status, headers, body, closed = self.raw_request(request)
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)["error"]["code"], "invalid_request")
        self.assertEqual(headers.get("connection"), "close")
        self.assertTrue(closed, "the server must close a connection whose body it did not read")
        self.assertEqual(self.factory.calls, [])
        status, _, payload = self.json_request("/api/state")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])

    def test_keep_alive_connections_stay_in_sync_after_an_error(self):
        request = (f"POST /api/issues/12/actions HTTP/1.1\r\nHost: {self.host()}\r\nContent-Type: application/json\r\n"
                   "Content-Length: 19\r\n\r\n" + '{"action":"explode"}'[:19] +
                   f"GET /api/state HTTP/1.1\r\nHost: {self.host()}\r\nConnection: close\r\n\r\n")
        with socket.create_connection(("127.0.0.1", self.server.port), timeout=5) as sock:
            sock.sendall(request.encode("iso-8859-1"))
            raw, closed = read_until_closed(sock, timeout=3.0)
        self.assertTrue(closed)
        first, rest = raw.split(b"\r\n\r\n", 1)
        self.assertTrue(first.startswith(b"HTTP/1.1 400"))
        self.assertIn(b"HTTP/1.1 200", rest)
        self.assertIn(b'"generatedAt"', rest.rsplit(b"\r\n\r\n", 1)[-1])

    def test_idle_connections_are_closed_after_the_request_timeout(self):
        server = DashboardServer(self.store, self.factory, host="127.0.0.1", port=0, request_timeout=0.5,
                                 log=self.messages.append).start()
        self.addCleanup(server.stop)
        started = time.monotonic()
        with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
            raw, closed = read_until_closed(sock, timeout=5.0)
        self.assertEqual(raw, b"")
        self.assertTrue(closed, "an idle connection must not pin a handler thread")
        self.assertLess(time.monotonic() - started, 4.0)
        with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
            sock.sendall(b"POST /api/releases/retry HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 60000\r\n\r\n")
            raw, closed = read_until_closed(sock, timeout=5.0)
        self.assertTrue(closed, "a stalled body must not pin a handler thread")
        self.assertEqual(self.factory.calls, [])
        self.assertFalse([message for message in self.messages if "timed out" in message], self.messages)
        with self.assertRaises(CodeFactoryError):
            DashboardServer(self.store, self.factory, host="127.0.0.1", port=0, request_timeout=0)

    def test_only_errors_and_writes_are_logged_and_lines_are_sanitised(self):
        self.messages.clear()
        status, _, _ = self.json_request("/api/state")
        self.assertEqual(status, 200)
        self.request("/")
        self.assertEqual([message for message in self.messages if message.startswith("http ")], [])
        self.json_request("/api/issues/12/actions", method="POST", body={"action": "skip"})
        self.json_request("/nope")
        self.raw_request(f"GET /api/state\x1b[31mINJECT HTTP/1.1\r\nHost: {self.host()}\r\nConnection: close\r\n\r\n")
        http_lines = [message for message in self.messages if message.startswith("http ")]
        self.assertEqual(len(http_lines), 3, self.messages)
        self.assertIn('"POST /api/issues/12/actions HTTP/1.1" 200', http_lines[0])
        self.assertIn('"GET /nope HTTP/1.1" 404', http_lines[1])
        self.assertIn("/api/state?[31mINJECT", http_lines[2])
        for line in http_lines:
            self.assertFalse([char for char in line if ord(char) < 0x20 or ord(char) > 0x7E], repr(line))


class LifecycleTests(unittest.TestCase):
    def test_constructor_validation(self):
        store = CodeFactoryStore(":memory:")
        self.addCleanup(store.close)
        with self.assertRaises(CodeFactoryError):
            DashboardServer(store, None, host="", port=1)
        with self.assertRaises(CodeFactoryError):
            DashboardServer(store, None, host="127.0.0.1", port=70000)
        with self.assertRaises(CodeFactoryError):
            DashboardServer(store, None, host="127.0.0.1", port=1, token="bad\ntoken")
        server = DashboardServer(store, None, host="127.0.0.1", port=1234)
        self.assertEqual(server.url, "http://127.0.0.1:1234/")
        self.assertFalse(server.running)
        server.stop()  # tolerated before start

    def test_url_normalizes_wildcard_hosts(self):
        store = CodeFactoryStore(":memory:")
        self.addCleanup(store.close)
        self.assertEqual(DashboardServer(store, None, host="0.0.0.0", port=9097).url, "http://127.0.0.1:9097/")
        self.assertEqual(DashboardServer(store, None, host="::", port=9097).url, "http://[::1]:9097/")
        self.assertEqual(DashboardServer(store, None, host="::1", port=9097).url, "http://[::1]:9097/")

    def test_start_is_idempotent_and_stop_releases_the_port(self):
        store = CodeFactoryStore(":memory:")
        self.addCleanup(store.close)
        server = DashboardServer(store, None, host="127.0.0.1", port=0, log=lambda message: None)
        server.start()
        port = server.port
        self.assertGreater(port, 0)
        self.assertIs(server.start(), server)
        self.assertEqual(server.port, port)
        server.stop()
        self.assertFalse(server.running)
        server.stop()
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", port))  # raises if the server left the port bound

    def test_bind_failure_is_a_typed_error(self):
        store = CodeFactoryStore(":memory:")
        self.addCleanup(store.close)
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", 0))
            probe.listen(1)
            port = probe.getsockname()[1]
            server = DashboardServer(store, None, host="127.0.0.1", port=port, log=lambda message: None)
            with self.assertRaises(CodeFactoryError) as caught:
                server.start()
        self.assertEqual(caught.exception.code, "dashboard_bind_failed")
        self.assertIn(f"127.0.0.1:{port}", str(caught.exception))
        self.assertFalse(server.running)
        server = DashboardServer(store, None, host="dashboard.example.invalid", port=0, log=lambda message: None)
        with self.assertRaises(CodeFactoryError) as caught:
            server.start()
        self.assertEqual(caught.exception.code, "dashboard_bind_failed")
        self.assertIn("dashboard.example.invalid", str(caught.exception))

    def test_ipv6_literals_bind(self):
        try:
            with socket.socket(socket.AF_INET6) as probe:
                probe.bind(("::1", 0))
        except OSError:
            self.skipTest("IPv6 loopback is not available")
        store = CodeFactoryStore(":memory:")
        self.addCleanup(store.close)
        server = DashboardServer(store, None, host="::1", port=0, log=lambda message: None).start()
        self.addCleanup(server.stop)
        self.assertEqual(server.url, f"http://[::1]:{server.port}/")
        with urllib.request.urlopen(server.url + "api/state", timeout=5) as response:
            self.assertEqual(response.status, 200)


class FakeRunner:
    def __init__(self, replies):
        self.replies = replies
        self.calls = []
        self.kwargs = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        self.kwargs.append(kwargs)
        reply = self.replies.get(argv[0])
        if isinstance(reply, BaseException):
            raise reply
        if reply is None:
            raise FileNotFoundError(argv[0])
        return SimpleNamespace(**reply)


class HostResolutionTests(unittest.TestCase):
    def test_literal_hosts_pass_through(self):
        self.assertEqual(resolve_dashboard_host("192.0.2.10", runner=None), "192.0.2.10")
        self.assertEqual(resolve_dashboard_host(" dashboard.example.invalid ", runner=None), "dashboard.example.invalid")
        self.assertEqual(resolve_dashboard_host("", runner=None), "127.0.0.1")

    def test_tailscale_uses_first_answering_binary(self):
        runner = FakeRunner({"tailscale": {"returncode": 0, "stdout": "203.0.113.7\n", "stderr": ""}})
        self.assertEqual(resolve_dashboard_host("tailscale", runner=runner), "203.0.113.7")
        self.assertEqual(runner.calls, [["tailscale", "ip", "-4"]])

    def test_tailscale_probe_never_inherits_herdr_settings(self):
        runner = FakeRunner({"tailscale": {"returncode": 0, "stdout": "203.0.113.7\n", "stderr": ""}})
        environ = {"PATH": "/usr/bin", "HOME": "/home/example", "HERDR_CODE_FACTORY_DASHBOARD_TOKEN": "secret",
                   "HERDR_CONTROL_TOKEN": "secret", "OLLAMA_API_KEY": "provider"}
        address, _ = tailscale_ipv4(runner, environ=environ)
        self.assertEqual(address, "203.0.113.7")
        env = runner.kwargs[0]["env"]
        self.assertEqual([key for key in env if key.startswith("HERDR_")], [])
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertEqual(resolve_dashboard_host("tailscale", runner=runner, environ=environ), "203.0.113.7")
        self.assertEqual([key for key in runner.kwargs[1]["env"] if key.startswith("HERDR_")], [])
        tailscale_ipv4(runner)  # default: the process environment, still filtered
        self.assertEqual([key for key in runner.kwargs[2]["env"] if key.startswith("HERDR_")], [])

    def test_tailscale_falls_back_to_the_app_bundle_binary(self):
        runner = FakeRunner({
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale": {"returncode": 0, "stdout": "203.0.113.8", "stderr": ""},
        })
        self.assertEqual(resolve_dashboard_host("Tailscale", runner=runner), "203.0.113.8")
        self.assertEqual(len(runner.calls), 2)

    def test_tailscale_failure_falls_back_to_loopback_with_a_warning(self):
        messages = []
        runner = FakeRunner({
            "tailscale": {"returncode": 1, "stdout": "", "stderr": "not running"},
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale": {"returncode": 0, "stdout": "fe80::1\n", "stderr": ""},
        })
        self.assertEqual(resolve_dashboard_host("tailscale", runner=runner, log=messages.append), "127.0.0.1")
        self.assertEqual(len(messages), 1)
        self.assertIn("exit status 1", messages[0])
        self.assertIn("IPv6", messages[0])
        address, detail = tailscale_ipv4(runner)
        self.assertIsNone(address)
        self.assertIn("tailscale", detail)

    def test_host_resolves_accepts_ip_literals_and_rejects_garbage(self):
        self.assertTrue(host_resolves("127.0.0.1"))
        self.assertTrue(host_resolves("::1"))
        self.assertFalse(host_resolves(""))
        self.assertFalse(host_resolves("bad host/name"))
        self.assertFalse(host_resolves("a" * 300))


if __name__ == "__main__":
    unittest.main()
