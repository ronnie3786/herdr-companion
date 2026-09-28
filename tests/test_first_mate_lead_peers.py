"""The lead First Mate's reach into other machines (first-mate-lead-peers-v1).

A lead reaches every other machine in its companion's roster whose API
credential is configured on its host, through that machine's
POST /api/v1/first-mate/lead/remote. Peer calls run off the runtime loop, a
machine that does not answer reads as offline, and only the human's own turn
relays anywhere. Synthetic data only.
"""
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from types import SimpleNamespace

from herdr_harness.first_mate_peers import CAPABILITY, OFFLINE_SECONDS, Peer, PeerDirectory
from herdr_harness.first_mate_runtime import DeferredOperation, FirstMateRuntime
from herdr_harness.first_mate_store import LEAD_KIND, FirstMateError, FirstMateStore
from herdr_harness.server import make_handler

HOME_TOKEN = "synthetic-home-token-" + "a" * 40
DEVBOX_TOKEN = "synthetic-devbox-token-" + "b" * 40


def private(path: Path, text: str) -> Path:
    path.write_text(text)
    path.chmod(0o600)
    return path


def roster_config(root: Path, devbox_url: str = "https://devbox.example.invalid") -> Path:
    """A private cluster configuration: this home machine, a devbox with its
    credential here, and a studio without one."""
    home_token = private(root / "home-token", HOME_TOKEN + "\n")
    devbox_token = private(root / "devbox-token", DEVBOX_TOKEN + "\n")
    return private(root / "config.toml", f'''version = 1
machine = "home"

[machines.home]
name = "Synthetic home"
role = "work"
url = "https://home.example.invalid"

[machines.home.server]
api_token_file = "{home_token}"

[machines.devbox]
name = "Synthetic devbox"
role = "development"
url = "{devbox_url}"

[machines.devbox.server]
api_token_file = "{devbox_token}"

[machines.studio]
name = "Synthetic studio"
role = "local"
url = "https://studio.example.invalid"
''')


class FakeResponse(io.BytesIO):
    def __init__(self, url: str, body: dict, status: int = 200):
        super().__init__(json.dumps(body).encode())
        self.url, self.status = url, status

    def geturl(self):
        return self.url


class PeerDirectoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = roster_config(self.root)
        self.requests = []
        self.answer = lambda request: FakeResponse(request.full_url, {"ok": True, "result": {"features": []}})
        self.now = 1000.0

        def opener(request, timeout=None):
            self.requests.append((request, timeout))
            return self.answer(request)

        # The home companion's own credential is in its environment; a peer
        # call must use the peer's credential instead.
        self.peers = PeerDirectory({"HERDR_CONFIG": str(self.config), "HERDR_MACHINE": "home",
                                    "HOME": str(self.root), "HERDR_HARNESS_API_TOKEN_FILE": str(self.root / "home-token")},
                                   opener=opener, clock=lambda: self.now)

    def test_peers_are_roster_machines_with_a_credential_here(self):
        self.assertEqual(self.peers.local(), {"id": "home", "name": "Synthetic home"})
        self.assertEqual(self.peers.peers(), [Peer("devbox", "Synthetic devbox", "https://devbox.example.invalid")])
        self.assertIsNone(self.peers.peer("studio"))
        self.assertEqual(PeerDirectory({"HOME": str(self.root)}).peers(), [])

    def test_a_call_posts_the_action_with_the_peers_own_credential(self):
        result = self.peers.call("devbox", "fm_relay", {"feature_id": "fmf_remote", "text": "Use CSV."},
                                 request_id="request-1", lead={"machine": "home", "message_id": "fmm_turn"})
        self.assertEqual(result, {"features": []})
        request, timeout = self.requests[0]
        self.assertEqual(request.full_url, "https://devbox.example.invalid/api/v1/first-mate/lead/remote")
        self.assertEqual(request.get_header("Authorization"), "Bearer " + DEVBOX_TOKEN)
        self.assertEqual(json.loads(request.data), {"action": "fm_relay", "request_id": "request-1",
                                                    "params": {"feature_id": "fmf_remote", "text": "Use CSV."},
                                                    "lead": {"machine": "home", "message_id": "fmm_turn"}})
        self.assertLessEqual(timeout, 10)
        self.assertIsNotNone(self.peers.last_seen("devbox"))

    def test_a_machine_that_does_not_answer_is_offline_for_a_while(self):
        def down(request):
            raise urllib.error.URLError("synthetic outage")
        self.answer = down
        with self.assertRaises(FirstMateError) as raised:
            self.peers.call("devbox", "fm_fleet", {}, request_id="r1", lead={"machine": "home", "message_id": "m"})
        self.assertEqual(raised.exception.code, "machine_offline")
        self.assertIn("Synthetic devbox", str(raised.exception))
        self.assertTrue(self.peers.offline("devbox"))
        # Within the window nothing is asked again.
        with self.assertRaises(FirstMateError):
            self.peers.call("devbox", "fm_fleet", {}, request_id="r2", lead={"machine": "home", "message_id": "m"})
        self.assertEqual(len(self.requests), 1)
        self.now += OFFLINE_SECONDS + 1
        self.assertFalse(self.peers.offline("devbox"))
        self.answer = lambda request: FakeResponse(request.full_url, {"ok": True, "result": {"features": []}})
        self.peers.call("devbox", "fm_fleet", {}, request_id="r3", lead={"machine": "home", "message_id": "m"})
        self.assertEqual(len(self.requests), 2)

    def test_an_old_companion_and_a_refusal_are_not_outages(self):
        def status(code, error):
            def answer(request):
                raise urllib.error.HTTPError(request.full_url, code, "synthetic", {},
                                             io.BytesIO(json.dumps({"error": error}).encode()))
            return answer
        self.answer = status(404, {"code": "not_found", "message": "Not found"})
        with self.assertRaises(FirstMateError) as raised:
            self.peers.call("devbox", "fm_fleet", {}, request_id="r1", lead={"machine": "home", "message_id": "m"})
        self.assertEqual(raised.exception.code, "machine_unsupported")
        self.answer = status(409, {"code": "feature_closed", "message": "Feature is closed"})
        with self.assertRaises(FirstMateError) as raised:
            self.peers.call("devbox", "fm_relay", {"feature_id": "f", "text": "t"}, request_id="r2",
                            lead={"machine": "home", "message_id": "m"})
        self.assertEqual(raised.exception.code, "feature_closed")
        self.assertFalse(self.peers.offline("devbox"))
        with self.assertRaises(FirstMateError) as raised:
            self.peers.call("studio", "fm_fleet", {}, request_id="r3", lead={"machine": "home", "message_id": "m"})
        self.assertEqual(raised.exception.code, "unknown_machine")


class FakePeers:
    """A peer directory whose one peer answers when released."""

    def __init__(self):
        self.calls = []
        self.release = threading.Event()
        self.down = set()
        self.cached_offline = set()

    def local(self):
        return {"id": "home", "name": "Synthetic home"}

    def peers(self):
        return [Peer("devbox", "Synthetic devbox", "https://devbox.example.invalid")]

    def peer(self, machine_id):
        return next((peer for peer in self.peers() if peer.id == machine_id), None)

    def offline(self, machine_id):
        return machine_id in self.cached_offline

    def last_seen(self, machine_id):
        return "2026-09-28T12:00:00Z"

    def call(self, machine_id, action, params, *, request_id, lead):
        self.release.wait(10)
        self.calls.append({"machine": machine_id, "action": action, "params": params,
                           "request_id": request_id, "lead": lead})
        if machine_id in self.down:
            raise FirstMateError("Synthetic devbox is offline right now", code="machine_offline", status=503)
        if action == "fm_fleet":
            return {"features": [{"feature_id": "fmf_remote", "label": "Calendar export", "hud_status": "blocked"}],
                    "hud_status_meanings": {}}
        return {"relayed": True, "feature_id": params.get("feature_id"), "message_id": "fmm_remote"}


class LeadPeerRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        pi = self.root / "pi"
        pi.write_text("#!/bin/sh\nexit 1\n")
        pi.chmod(0o700)
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, environ={
            "HOME": str(self.root), "PATH": os.environ.get("PATH", ""),
            "HERDR_HARNESS_AGENT_PI_BIN": str(pi)}, runtime_root=self.root / "runtime")
        self.addCleanup(self.runtime.stop)
        self.peers = FakePeers()
        self.runtime.peers = self.peers
        self.feature = self.store.create_feature({"title": "Receipt export", "goal": "Export synthetic receipts",
                                                  "cwd": str(self.root), "request_id": "create"})
        self.lead_id = self.runtime.ensure_lead()["feature"]["id"]
        self.store.append_human_message(self.lead_id, "What needs me everywhere?", "ask")
        self.claim = self.store.claim_message(self.lead_id, self.runtime.owner)
        self.job = self.runtime._new_job(self.store.get_feature(self.lead_id), kind="coordinator",
                                         prompt="What needs me everywhere?", claim=self.claim)

    def settle(self, action, params, request_id, timeout=10):
        """Asks like the spool does: again on each pass until it lands."""
        deadline = time.monotonic() + timeout
        while True:
            try:
                return self.runtime._tool(self.job, action, params, request_id)
            except DeferredOperation:
                if time.monotonic() > deadline:
                    self.fail("The peer call never landed")
                time.sleep(.01)

    def test_the_fleet_covers_this_machine_and_its_peers_without_blocking_the_loop(self):
        with self.assertRaises(DeferredOperation):
            self.runtime._tool(self.job, "fm_fleet", {}, "fleet")
        self.peers.release.set()
        fleet = self.settle("fm_fleet", {}, "fleet")
        self.assertEqual((fleet["machine"], fleet["machine_name"]), ("home", "Synthetic home"))
        self.assertEqual([item["label"] for item in fleet["features"]], ["Receipt export"])
        self.assertEqual(fleet["other_machines"], [{"machine": "devbox", "name": "Synthetic devbox", "features": [
            {"feature_id": "fmf_remote", "label": "Calendar export", "hud_status": "blocked"}]}])
        self.assertEqual(self.peers.calls[0]["lead"], {"machine": "home", "message_id": self.claim["id"]})
        self.assertEqual(self.runtime._peer_calls, {})

    def test_an_offline_machine_is_listed_as_offline_and_never_waited_on(self):
        self.peers.release.set()
        self.peers.down.add("devbox")
        fleet = self.settle("fm_fleet", {}, "fleet-down")
        self.assertEqual(fleet["other_machines"], [{"machine": "devbox", "name": "Synthetic devbox", "offline": True,
                                                    "last_seen": "2026-09-28T12:00:00Z"}])
        self.peers.cached_offline.add("devbox")
        calls = len(self.peers.calls)
        fleet = self.runtime._tool(self.job, "fm_fleet", {}, "fleet-cached")
        self.assertTrue(fleet["other_machines"][0]["offline"])
        self.assertEqual(len(self.peers.calls), calls)
        self.assertEqual([item["label"] for item in fleet["features"]], ["Receipt export"])
        self.assertIn('Your tools also reach Synthetic devbox (machine "devbox", offline right now)',
                      self.runtime._lead_input({}, self.claim))

    def test_a_relay_to_another_machine_carries_this_lead_and_only_the_humans_turn(self):
        self.peers.release.set()
        result = self.settle("fm_relay", {"feature_id": "fmf_remote", "text": "Use CSV.", "machine": "devbox"},
                             "relay")
        self.assertEqual(result["message_id"], "fmm_remote")
        call = self.peers.calls[0]
        self.assertEqual({key: call[key] for key in ("machine", "action", "params", "lead")},
                         {"machine": "devbox", "action": "fm_relay",
                          "params": {"feature_id": "fmf_remote", "text": "Use CSV."},
                          "lead": {"machine": "home", "message_id": self.claim["id"]}})
        # One receipt per exact action on the human's turn, so a continued
        # turn's new tool call replays it on the peer instead of relaying twice.
        self.assertTrue(call["request_id"].startswith("lead-action:"))
        self.settle("fm_relay", {"feature_id": "fmf_remote", "text": "Use CSV.", "machine": "devbox"}, "relay-again")
        self.assertEqual(self.peers.calls[1]["request_id"], call["request_id"])
        self.settle("fm_relay", {"feature_id": "fmf_remote", "text": "Use JSON.", "machine": "devbox"}, "relay-other")
        self.assertNotEqual(self.peers.calls[2]["request_id"], call["request_id"])
        del self.peers.calls[1:]
        # This machine's own ID, or none, stays here.
        status = self.runtime._tool(self.job, "fm_feature_status", {"feature_id": self.feature["id"], "machine": "home"},
                                    "status-here")
        self.assertEqual(status["feature"]["label"], "Receipt export")
        background = {**self.job, "claim": {**self.claim, "role": "system"}}
        for action in ("fm_relay", "fm_create_feature"):
            with self.assertRaises(FirstMateError) as raised:
                self.runtime._tool(background, action, {"feature_id": "fmf_remote", "text": "Ship it",
                                                        "machine": "devbox"}, "bg-" + action)
            self.assertEqual(raised.exception.code, "lead_unauthorized")
        with self.assertRaises(FirstMateError) as raised:
            self.runtime._tool(self.job, "fm_mark_read", {"feature_id": "fmf_remote", "machine": "studio"}, "unknown")
        self.assertEqual(raised.exception.code, "unknown_machine")
        self.assertEqual(len(self.peers.calls), 1)
        # Machines by name or ID, an empty value for here, and a hint for a
        # feature asked for without its machine.
        self.settle("fm_mark_read", {"feature_id": "fmf_remote", "machine": " synthetic DEVBOX "}, "by-name")
        self.assertEqual(self.peers.calls[-1]["machine"], "devbox")
        for here in ("", "Synthetic home"):
            status = self.runtime._tool(self.job, "fm_feature_status", {"feature_id": self.feature["id"], "machine": here},
                                        "here-" + here)
            self.assertEqual(status["feature"]["label"], "Receipt export")
        with self.assertRaises(FirstMateError) as raised:
            self.runtime._tool(self.job, "fm_feature_status", {"feature_id": "fmf_remote"}, "missing-machine")
        self.assertEqual(raised.exception.code, "not_found")
        self.assertIn("pass its machine from fm_fleet", str(raised.exception))

    def test_the_summary_and_the_turn_name_the_machines_the_lead_reaches(self):
        summary = self.runtime.lead()
        self.assertEqual(summary["machine"], {"id": "home", "name": "Synthetic home"})
        self.assertEqual(summary["peers"], [{"id": "devbox", "name": "Synthetic devbox",
                                             "url": "https://devbox.example.invalid"}])
        prompt = self.runtime._lead_input({}, self.claim)
        self.assertIn('This machine is Synthetic home (machine "home"). Your tools also reach Synthetic devbox '
                      '(machine "devbox"); fm_fleet covers every machine.', prompt)

    def test_a_remote_lead_acts_on_this_machines_features_once_per_request(self):
        first = self.runtime.lead_remote("fm_relay", {"feature_id": self.feature["id"], "text": "Use CSV."},
                                         request_id="relay-1", lead_machine="studio", lead_message_id="fmm_elsewhere")
        again = self.runtime.lead_remote("fm_relay", {"feature_id": self.feature["id"], "text": "Use CSV."},
                                         request_id="relay-1", lead_machine="studio", lead_message_id="fmm_elsewhere")
        self.assertEqual(first["message_id"], again["message_id"])
        relayed = [m for m in self.store.snapshot(self.feature["id"])["messages"]
                   if (m.get("metadata") or {}).get("relayed_by") == LEAD_KIND]
        self.assertEqual(len(relayed), 1)
        self.assertEqual(relayed[0]["metadata"]["lead_machine"], "studio")
        self.assertEqual(relayed[0]["metadata"]["lead_message_id"], "fmm_elsewhere")
        journal = self.store.snapshot(self.feature["id"], events="journal")["events"]
        self.assertIn("Human direction relayed by the lead First Mate on studio", [event["summary"] for event in journal])
        fleet = self.runtime.lead_remote("fm_fleet", {}, request_id="fleet", lead_machine="studio",
                                         lead_message_id="fmm_elsewhere")
        self.assertEqual([item["label"] for item in fleet["features"]], ["Receipt export"])
        self.assertNotIn("other_machines", fleet)
        for action, params, code in (("fm_status", {}, "lead_unsupported"),
                                     ("fm_fleet", {"machine": "home"}, "invalid_request")):
            with self.assertRaises(FirstMateError) as raised:
                self.runtime.lead_remote(action, params, request_id="bad", lead_machine="studio",
                                         lead_message_id="fmm_elsewhere")
            self.assertEqual(raised.exception.code, code)


class LeadPeerHTTPTests(unittest.TestCase):
    """Two companions: the home lead relays through the devbox's real HTTP route."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        pi = self.root / "pi"
        pi.write_text("#!/bin/sh\nexit 1\n")
        pi.chmod(0o700)
        self.devbox_store = FirstMateStore(self.root / "devbox.sqlite3")
        self.devbox = FirstMateRuntime(self.devbox_store, environ={
            "HOME": str(self.root), "PATH": os.environ.get("PATH", ""), "HERDR_HARNESS_AGENT_PI_BIN": str(pi)},
            runtime_root=self.root / "devbox-runtime")
        self.wakes = []
        service = SimpleNamespace(environ={"HERDR_HARNESS_API_TOKEN": DEVBOX_TOKEN},
                                  first_mate_store=self.devbox_store, first_mate=self.devbox,
                                  first_mate_changed=self.wakes.append)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        config = roster_config(self.root, devbox_url=self.origin)
        self.home_store = FirstMateStore(self.root / "home.sqlite3")
        self.home = FirstMateRuntime(self.home_store, environ={
            "HOME": str(self.root), "PATH": os.environ.get("PATH", ""), "HERDR_HARNESS_AGENT_PI_BIN": str(pi),
            "HERDR_CONFIG": str(config), "HERDR_MACHINE": "home"}, runtime_root=self.root / "home-runtime")

    def tearDown(self):
        self.home.stop()
        self.devbox.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.home_store.close()
        self.devbox_store.close()

    def request(self, path, body=None, token=DEVBOX_TOKEN):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.origin + path, headers=headers,
                                         data=json.dumps(body).encode() if body is not None else None)
        try:
            response = urllib.request.urlopen(request)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def test_the_remote_route_is_authenticated_strict_and_advertised(self):
        status, capabilities = self.request("/api/v1/first-mate/capabilities")
        self.assertIn(CAPABILITY, capabilities["capabilities"])
        body = {"action": "fm_fleet", "params": {}, "request_id": "r1", "lead": {"machine": "home", "message_id": "m"}}
        self.assertEqual(self.request("/api/v1/first-mate/lead/remote", body, token=None)[0], 401)
        self.assertEqual(self.request("/api/v1/first-mate/lead/remote", body, token=HOME_TOKEN)[0], 401)
        status, answer = self.request("/api/v1/first-mate/lead/remote", body)
        self.assertEqual((status, answer["result"]["features"]), (200, []))
        for broken in ({**body, "surprise": True}, {**body, "lead": {"machine": "home"}}, {**body, "params": []}):
            self.assertEqual(self.request("/api/v1/first-mate/lead/remote", broken)[0], 400)
        status, refused = self.request("/api/v1/first-mate/lead/remote", {**body, "action": "fm_delegate"})
        self.assertEqual((status, refused["error"]["code"]), (409, "lead_unsupported"))

    def test_the_home_lead_relays_to_a_devbox_feature_over_http(self):
        feature = self.devbox_store.create_feature({"title": "Calendar export", "goal": "Synthetic goal",
                                                    "cwd": str(self.root), "request_id": "create-remote"})
        message = self.devbox_store.claim_message(feature["id"], "settled")
        self.devbox_store.finish_message(message["id"], "settled", "CSV or JSON?")
        lead_id = self.home.ensure_lead()["feature"]["id"]
        self.home_store.append_human_message(lead_id, "Tell calendar export to use CSV", "ask")
        claim = self.home_store.claim_message(lead_id, self.home.owner)
        job = self.home._new_job(self.home_store.get_feature(lead_id), kind="coordinator", prompt="ask", claim=claim)

        def settle(action, params, request_id):
            deadline = time.monotonic() + 15
            while True:
                try:
                    return self.home._tool(job, action, params, request_id)
                except DeferredOperation:
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.01)

        fleet = settle("fm_fleet", {}, "fleet")
        remote = fleet["other_machines"][0]
        self.assertEqual((remote["machine"], remote["name"]), ("devbox", "Synthetic devbox"))
        self.assertEqual([item["label"] for item in remote["features"]], ["Calendar export"])
        self.assertTrue(remote["features"][0]["unread"])
        relayed = settle("fm_relay", {"feature_id": feature["id"], "text": "Use CSV for the calendar export.",
                                      "machine": "devbox"}, "relay")
        self.assertTrue(relayed["relayed"])
        messages = [m for m in self.devbox_store.snapshot(feature["id"])["messages"]
                    if (m.get("metadata") or {}).get("relayed_by") == LEAD_KIND]
        self.assertEqual([m["text"] for m in messages], ["Use CSV for the calendar export."])
        self.assertEqual(messages[0]["metadata"], {"relayed_by": LEAD_KIND, "lead_message_id": claim["id"],
                                                   "lead_machine": "home"})
        row = self.devbox_store.fleet_row(feature["id"])
        self.assertEqual(row["read_through_message_id"], row["first_mate_id"])
        status = settle("fm_feature_status", {"feature_id": feature["id"], "machine": "devbox"}, "status")
        self.assertEqual(status["recent_conversation"][-1]["relayed_by_lead"], True)
        self.assertEqual(self.home.lead()["peers"], [{"id": "devbox", "name": "Synthetic devbox", "url": self.origin}])


if __name__ == "__main__":
    unittest.main()
