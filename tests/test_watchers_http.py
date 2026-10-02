"""Exercise the real HTTP auth/dispatch path with a private synthetic store."""
import json
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
from http.server import ThreadingHTTPServer
from pathlib import Path
import stat
import tempfile
import threading
from types import SimpleNamespace
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

from herdr_harness.events import EventBroker
from herdr_harness.server import make_handler
from herdr_harness.service import HerdrService
from herdr_harness.watchers.store import WatchersStore
from herdr_harness.watchers.validation import example


class WatchersHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.service = HerdrService.__new__(HerdrService)
        self.service.environ = {"HERDR_HARNESS_API_TOKEN": "synthetic-main-token", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token", "HERDR_WATCHERS_ENABLED": "1", "HERDR_MACHINE": "example", "HERDR_STATE_DIR": self.tmp.name}
        self.service._lock = threading.RLock()
        self.service._watchers_builder = None
        self.store = WatchersStore(Path(self.tmp.name) / "watchers.sqlite3", Path(self.tmp.name) / "watchers", {"id": "example", "name": "Example"})
        self.wakes = []
        self.runtime = SimpleNamespace(store=self.store, wake=lambda: self.wakes.append(True), status=lambda: {"running": True, "last_tick_at": "2026-10-02T00:00:00Z", "next_fire_at": None})
        self.service._watchers_runtime = self.runtime
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def request(self, suffix="", body=None, method=None, token="synthetic-main-token", api_root=False):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        path = "/api/v1" if api_root else "/api/v1/watchers" + suffix
        request = Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
        try:
            response = urlopen(request)
        except HTTPError as exc:
            response = exc
        with response:
            return response.status, json.loads(response.read())

    def create(self):
        return self.request(body={"request_id": "create-example", **example()})

    def test_full_auth_is_required_for_all_watcher_data(self):
        for token in (None, "synthetic-ingest-token", "wrong"):
            for path in ("", "/capabilities"):
                self.assertIn(self.request(path, token=token)[0], (401, 403))
        self.assertEqual(self.request("/capabilities")[0], 200)

    def test_disabled_discovery_never_constructs_store_or_runtime(self):
        self.service.environ["HERDR_WATCHERS_ENABLED"] = "0"
        self.service._watchers_runtime = None
        with patch("herdr_harness.watchers.store.WatchersStore", side_effect=AssertionError("constructed disabled store")):
            code, caps = self.request("/capabilities")
            self.assertEqual(code, 200)
            self.assertFalse(caps["enabled"])
            self.assertEqual(caps["capabilities"], [])
            self.assertEqual(caps["settings"], {"enabled": False, "source": "config", "changeable": False})
            code, data = self.request()
            self.assertEqual(code, 503)
            self.assertEqual(data["error"]["code"], "watchers_disabled")
            self.assertIn("HERDR_WATCHERS_ENABLED", data["error"]["message"])
            _, root = self.request(api_root=True)
            self.assertNotIn("watchers-v1", root["capabilities"])
            self.assertEqual(root["endpoints"]["watchersSettings"], "/api/v1/watchers/settings")
        self.assertIsNone(self.service._watchers_runtime)

    def test_discovery_lists_capability_and_events_only_when_enabled(self):
        _, root = self.request(api_root=True)
        self.assertIn("watchers-v1", root["capabilities"])
        for event in ("watchers.updated", "watchers.run", "watchers.inbox", "watchers.builder"):
            self.assertIn(event, root["sseEvents"])

    def test_create_idempotency_read_projection_and_conflict(self):
        code, first = self.create()
        self.assertEqual(code, 201)
        _, replay = self.create()
        self.assertEqual(first, replay)
        value = first["watcher"]
        required = {"id", "revision", "state", "schedule", "live", "avatar", "kind", "machine", "summary", "summary_tokens", "summary_text", "next_fire_at", "attention", "runs_count", "steps"}
        self.assertTrue(required <= value.keys())
        self.assertEqual(value["machine"]["id"], "example")
        self.assertIsNone(value["next_fire_at"])
        _, listing = self.request()
        self.assertEqual(listing["watchers"], [value])
        changed = example()
        changed["definition"]["name"] = "Another name"
        code, error = self.request(body={"request_id": "create-example", **changed})
        self.assertEqual(code, 409)
        self.assertEqual(error["error"]["code"], "idempotency_conflict")

    def test_script_put_parses_json_body_and_pins_revision(self):
        _, created = self.create()
        watcher = created["watcher"]
        path = "/" + watcher["id"] + "/scripts/check"
        code, response = self.request(path, {"request_id": "script-edit", "expected_revision": 1, "content": "printf changed\n"}, "PUT")
        self.assertEqual(code, 200)
        self.assertEqual(response["watcher"]["revision"], 2)
        self.assertEqual(self.request(path)[1]["content"], "printf changed\n")
        code, conflict = self.request(path, {"request_id": "stale-edit", "expected_revision": 1, "content": "printf stale\n"}, "PUT")
        self.assertEqual(code, 409)
        self.assertEqual(conflict["error"]["code"], "revision_conflict")

    def test_exact_body_keys_and_malformed_types_return_400(self):
        for payload in ({**example(), "request_id": "bad", "extra": True}, {"request_id": "missing"}, {**example(), "request_id": []}):
            with self.subTest(payload=payload):
                self.assertEqual(self.request(body=payload)[0], 400)
        for count in (True, 1.2, 0, 21):
            self.assertEqual(self.request("/schedule/preview", {"schedule": {"kind": "daily", "at": "09:00"}, "timezone": "UTC", "count": count})[0], 400)
        _, created = self.create()
        self.assertEqual(self.request("/" + created["watcher"]["id"] + "/actions", {"request_id": "bad-action", "action": []})[0], 400)

    def test_activation_requires_confirmation_and_supported_steps(self):
        _, created = self.create()
        path = "/" + created["watcher"]["id"] + "/actions"
        self.assertEqual(self.request(path, {"request_id": "unconfirmed", "action": "activate"})[0], 409)
        code, activated = self.request(path, {"request_id": "confirmed", "action": "activate", "confirmed_by": "user"})
        self.assertEqual(code, 200)
        self.assertEqual(activated["watcher"]["state"], "active")
        self.assertIsNotNone(activated["watcher"]["next_fire_at"])
        value = example()
        value["definition"]["steps"][0] = {"id": "agent", "kind": "agent", "model": "example/model", "instructions": "Read the synthetic report."}
        value["scripts"] = {}
        code, created = self.request(body={"request_id": "agent-draft", **value})
        self.assertEqual(code, 201)
        code, error = self.request("/" + created["watcher"]["id"] + "/actions", {"request_id": "unsupported", "action": "activate", "confirmed_by": "user"})
        self.assertEqual(code, 409)
        self.assertEqual(error["error"]["code"], "step_kind_unsupported")

    def test_script_and_definition_shapes_never_turn_bad_input_into_server_errors(self):
        for definition in (None, [], "not an object"):
            self.assertEqual(self.request(body={"request_id": "shape", "definition": definition})[0], 400)
        self.assertEqual(self.request(body={"request_id": "shape", **example(), "scripts": []})[0], 400)
        _, created = self.create()
        watcher_id = created["watcher"]["id"]
        for revision in (True, 1.0, "1", 0):
            self.assertEqual(self.request("/" + watcher_id, {"request_id": "bad-rev", "expected_revision": revision, "definition": {"name": "Changed"}}, "PATCH")[0], 400)
        self.assertEqual(self.request("/" + watcher_id + "/scripts/check", {"request_id": "bad-body", "expected_revision": 1, "content": None}, "PUT")[0], 400)
        self.assertEqual(self.store.get(watcher_id)["revision"], 1)

    def test_force_delete_conflicts_before_stopping_and_replays_after_deletion(self):
        from herdr_harness.watchers.runtime import WatchersRuntime
        self.service._watchers_runtime = WatchersRuntime(self.store, self.service.environ)
        _, created = self.create()
        watcher_id = created['watcher']['id']
        run = self.store.create_run(watcher_id, 'manual')
        code, error = self.request('/' + watcher_id + '?force=1', {'request_id': 'create-example'}, 'DELETE')
        self.assertEqual(code, 409)
        self.assertEqual(error['error']['code'], 'idempotency_conflict')
        self.assertEqual(self.store.get_run(run['id'])['status'], 'queued')
        self.assertEqual(self.store.get_run(run['id'])['stop_requested'], 0)
        request = {'request_id': 'delete-example'}
        self.assertEqual(self.request('/' + watcher_id + '?force=1', request, 'DELETE'), (200, {'ok': True}))
        self.assertEqual(self.request('/' + watcher_id + '?force=1', request, 'DELETE'), (200, {'ok': True}))

    def test_duplicate_replays_even_after_original_changes(self):
        _, created = self.create()
        watcher = created['watcher']
        request = {'request_id': 'duplicate-example', 'action': 'duplicate'}
        first = self.request('/' + watcher['id'] + '/actions', request)
        self.assertEqual(first[0], 200)
        self.store.patch(watcher['id'], {'name': 'Edited original'}, watcher['revision'])
        self.assertEqual(self.request('/' + watcher['id'] + '/actions', request), first)
        self.assertEqual(len(self.store.list()), 2)

    def test_runs_and_inbox_paginate_and_filter_before_limit(self):
        _, created = self.create()
        watcher = created['watcher']
        now = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
        with self.store.connection(write=True) as db:
            for i in range(225):
                stamp = (now - timedelta(minutes=i)).isoformat().replace('+00:00', 'Z')
                db.execute('INSERT INTO runs(id,watcher_id,revision,trigger,started_at,status,snapshot_json) VALUES(?,?,?,?,?,?,?)',
                           (f'run_{i}', watcher['id'], 1, 'manual', stamp, 'finished', json.dumps(watcher)))
                db.execute('INSERT INTO inbox_items VALUES(?,?,?,?,?,?,?)', (f'inbox_{i}', watcher['id'], f'run_{i}', 'Synthetic', 'Result', stamp, stamp if i < 224 else None))
        _, first = self.request('/' + watcher['id'] + '/runs?limit=2')
        self.assertEqual([row['id'] for row in first['runs']], ['run_0', 'run_1'])
        before = quote(first['runs'][-1]['started_at'])
        _, page = self.request('/' + watcher['id'] + '/runs?limit=2&before=' + before)
        self.assertEqual([row['id'] for row in page['runs']], ['run_2', 'run_3'])
        _, global_page = self.request('/runs?limit=2&before=' + before)
        self.assertEqual([row['id'] for row in global_page['runs']], ['run_2', 'run_3'])
        _, inbox = self.request('/inbox?limit=2&before=' + before)
        self.assertEqual([row['id'] for row in inbox['items']], ['inbox_2', 'inbox_3'])
        _, unread = self.request('/inbox?limit=2&unread=1')
        self.assertEqual([row['id'] for row in unread['items']], ['inbox_224'])
        self.assertEqual(unread['unread_count'], 1)


class WatchersSettingsHTTPTests(unittest.TestCase):
    """A person turns Watchers on and off without a restart; configuration wins."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)
        self.service = self.make_service({})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def make_service(self, extra):
        service = HerdrService.__new__(HerdrService)
        service.environ = {"HERDR_HARNESS_API_TOKEN": "synthetic-main-token", "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": "synthetic-ingest-token",
                           "HERDR_MACHINE": "example", "HERDR_STATE_DIR": self.tmp.name, "HERDR_WATCHERS_SUPERVISED": "1", **extra}
        service._lock = threading.RLock()
        service._watchers_builder = None
        service._watchers_runtime = None
        service.broker = EventBroker()
        return service

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        if self.service._watchers_runtime is not None:
            self.service._watchers_runtime.stop()
        self.tmp.cleanup()

    def request(self, suffix="", body=None, method=None, token="synthetic-main-token", api_root=False):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        path = "/api/v1" if api_root else "/api/v1/watchers" + suffix
        request = Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
        try:
            response = urlopen(request)
        except HTTPError as exc:
            response = exc
        with response:
            return response.status, json.loads(response.read())

    def change(self, enabled, request_id="settings-example", **extra):
        return self.request("/settings", {"request_id": request_id, "enabled": enabled, "confirmed_by": "user", **extra})

    @property
    def settings_file(self):
        return self.state / "watchers-settings.json"

    def settings_events(self):
        return [item["data"] for item in self.service.broker.after(0) if item["event"] == "watchers.updated" and "settings" in item["data"]]

    def test_default_is_off_with_default_source_and_settings_route_advertised(self):
        code, caps = self.request("/capabilities")
        self.assertEqual(code, 200)
        self.assertFalse(caps["enabled"])
        self.assertEqual(caps["capabilities"], [])
        self.assertEqual(caps["settings"], {"enabled": False, "source": "default", "changeable": True})
        code, error = self.request()
        self.assertEqual(code, 503)
        self.assertEqual(error["error"]["code"], "watchers_disabled")
        self.assertIn("herdr-watchers enable --i-confirm", error["error"]["message"])
        self.assertIn("Mac app", error["error"]["message"])
        _, root = self.request(api_root=True)
        self.assertEqual(root["endpoints"]["watchersSettings"], "/api/v1/watchers/settings")
        self.assertNotIn("watchers-v1", root["capabilities"])
        self.assertIsNone(self.service._watchers_runtime)
        self.assertFalse(self.settings_file.exists())

    def test_settings_route_requires_full_authentication(self):
        for token in (None, "synthetic-ingest-token", "wrong"):
            self.assertIn(self.request("/settings", {"request_id": "unauthorized", "enabled": True, "confirmed_by": "user"}, token=token)[0], (401, 403))
        self.assertIsNone(self.service._watchers_runtime)
        self.assertFalse(self.settings_file.exists())

    def test_enable_persists_privately_starts_the_scheduler_and_publishes(self):
        code, caps = self.change(True, changed_via="mac")
        self.assertEqual(code, 200)
        self.assertTrue(caps["ok"])
        self.assertTrue(caps["enabled"])
        self.assertEqual(caps["capabilities"], ["watchers-v1"])
        self.assertEqual(caps["settings"], {"enabled": True, "source": "app", "changeable": True})
        self.assertTrue(caps["scheduler"]["running"])
        self.assertTrue({"machine", "timezone", "steps", "delivery", "limits", "assets", "summary_tokens", "supervised"} <= caps.keys())
        self.assertEqual(stat.S_IMODE(self.settings_file.stat().st_mode), 0o600)
        saved = json.loads(self.settings_file.read_text())
        self.assertEqual({key: saved[key] for key in ("enabled", "changed_by", "changed_via")}, {"enabled": True, "changed_by": "user", "changed_via": "mac"})
        self.assertTrue(datetime.fromisoformat(saved["changed_at"].replace("Z", "+00:00")).tzinfo)
        code, fetched = self.request("/capabilities")
        self.assertEqual(code, 200)
        self.assertEqual({k: v for k, v in fetched.items() if k != "scheduler"}, {k: v for k, v in caps.items() if k != "scheduler"})
        self.assertEqual(self.request()[0], 200)
        _, root = self.request(api_root=True)
        self.assertIn("watchers-v1", root["capabilities"])
        self.assertEqual(self.settings_events(), [{"machine": {"id": "example", "name": "example"}, "settings": caps["settings"]}])
        # Enabling again is a no-op that keeps the same scheduler and record.
        runtime = self.service._watchers_runtime
        code, again = self.change(True, request_id="settings-again")
        self.assertEqual(code, 200)
        self.assertTrue(again["scheduler"]["running"])
        self.assertIs(self.service._watchers_runtime, runtime)
        self.assertEqual(json.loads(self.settings_file.read_text()), saved)
        self.assertEqual(len(self.settings_events()), 1)

    def test_choice_survives_a_new_service_on_the_same_state_directory(self):
        self.assertEqual(self.change(True)[0], 200)
        service = HerdrService(environ={"HERDR_STATE_DIR": self.tmp.name, "HERDR_MACHINE": "example"})
        try:
            self.assertEqual(service.watchers_settings(), {"enabled": True, "source": "app", "changeable": True})
            self.assertTrue(service.watchers_enabled)
        finally:
            service.stop()
        self.assertEqual(self.change(False)[0], 200)
        service = HerdrService(environ={"HERDR_STATE_DIR": self.tmp.name, "HERDR_MACHINE": "example"})
        try:
            self.assertEqual(service.watchers_settings(), {"enabled": False, "source": "app", "changeable": True})
        finally:
            service.stop()

    def test_disable_stops_the_scheduler_and_other_routes_return_503(self):
        self.assertEqual(self.change(True)[0], 200)
        runtime = self.service._watchers_runtime
        code, caps = self.change(False, request_id="settings-off")
        self.assertEqual(code, 200)
        self.assertFalse(caps["enabled"])
        self.assertEqual(caps["capabilities"], [])
        self.assertEqual(caps["settings"], {"enabled": False, "source": "app", "changeable": True})
        self.assertFalse(caps["scheduler"]["running"])
        self.assertIsNone(self.service._watchers_runtime)
        self.assertFalse(runtime._thread.is_alive())
        self.assertIsNone(runtime._lock_fd)
        self.assertFalse(json.loads(self.settings_file.read_text())["enabled"])
        code, error = self.request()
        self.assertEqual(code, 503)
        self.assertEqual(error["error"]["code"], "watchers_disabled")
        self.assertEqual(self.request("/schedule/preview", {"schedule": {"kind": "daily", "at": "09:00"}, "timezone": "UTC"})[0], 503)
        self.assertEqual([event["settings"]["enabled"] for event in self.settings_events()], [True, False])

    def test_disable_never_signals_detached_runners(self):
        self.assertEqual(self.change(True)[0], 200)
        with patch("herdr_harness.watchers.runtime.signal_process", side_effect=AssertionError("signalled a runner")), \
                patch("os.kill", side_effect=AssertionError("signalled a process")), \
                patch("os.killpg", side_effect=AssertionError("signalled a group")):
            self.assertEqual(self.change(False, request_id="off")[0], 200)

    def test_enable_disable_enable_builds_a_fresh_scheduler_that_keeps_definitions(self):
        self.assertEqual(self.change(True, request_id="first-on")[0], 200)
        first = self.service._watchers_runtime
        code, created = self.request(body={"request_id": "create-example", **example()})
        self.assertEqual(code, 201)
        self.assertEqual(self.change(False, request_id="off")[0], 200)
        code, caps = self.change(True, request_id="second-on")
        self.assertEqual(code, 200)
        self.assertTrue(caps["scheduler"]["running"])
        second = self.service._watchers_runtime
        self.assertIsNotNone(second)
        self.assertIsNot(second, first)
        self.assertTrue(second._thread.is_alive())
        _, listing = self.request()
        self.assertEqual([watcher["id"] for watcher in listing["watchers"]], [created["watcher"]["id"]])

    def test_failed_start_leaves_the_setting_unchanged(self):
        self.service.environ["HERDR_WATCHERS_MAX_RUNS"] = "0"
        code, error = self.change(True)
        self.assertEqual(code, 400)
        self.assertEqual(error["error"]["code"], "invalid_configuration")
        self.assertFalse(self.settings_file.exists())
        self.assertIsNone(self.service._watchers_runtime)
        self.assertEqual(self.request("/capabilities")[1]["settings"], {"enabled": False, "source": "default", "changeable": True})
        self.assertEqual(self.settings_events(), [])

    def test_configuration_locks_the_setting(self):
        for pinned in ("1", "0"):
            with self.subTest(pinned=pinned):
                self.service.environ["HERDR_WATCHERS_ENABLED"] = pinned
                enabled = pinned == "1"
                _, caps = self.request("/capabilities")
                self.assertEqual(caps["settings"], {"enabled": enabled, "source": "config", "changeable": False})
                code, error = self.change(not enabled, request_id="conflict-" + pinned)
                self.assertEqual(code, 409)
                self.assertEqual(error["error"], {"code": "watchers_setting_locked", "message": "HERDR_WATCHERS_ENABLED is set in this companion's configuration. Change it there and restart the companion."})
                code, same = self.change(enabled, request_id="same-" + pinned)
                self.assertEqual(code, 200)
                self.assertEqual(same["settings"], caps["settings"])
                self.assertEqual(same["enabled"], enabled)
                self.assertFalse(self.settings_file.exists())
                self.assertIsNone(self.service._watchers_runtime)
                self.assertEqual(self.settings_events(), [])

    def test_configuration_wins_over_a_saved_choice(self):
        self.assertEqual(self.change(True)[0], 200)
        self.service._watchers_runtime.stop()
        self.service._watchers_runtime = None
        service = self.make_service({"HERDR_WATCHERS_ENABLED": "0"})
        self.assertEqual(service.watchers_settings(), {"enabled": False, "source": "config", "changeable": False})
        self.assertFalse(service.watchers_enabled)

    def test_request_shape_is_exact(self):
        valid = {"request_id": "shape", "enabled": True, "confirmed_by": "user"}
        bad = [
            {key: value for key, value in valid.items() if key != "confirmed_by"},
            {**valid, "confirmed_by": "agent"},
            {**valid, "confirmed_by": None},
            {**valid, "extra": True},
            {key: value for key, value in valid.items() if key != "request_id"},
            {**valid, "request_id": ""},
            {**valid, "request_id": "x" * 201},
            {key: value for key, value in valid.items() if key != "enabled"},
            {**valid, "enabled": "yes"},
            {**valid, "enabled": 1},
            {**valid, "changed_via": ""},
            {**valid, "changed_via": "x" * 41},
            {**valid, "changed_via": 7},
            [],
        ]
        for payload in bad:
            with self.subTest(payload=payload):
                code, error = self.request("/settings", payload)
                self.assertEqual(code, 400)
                self.assertEqual(error["error"]["code"], "invalid_request")
        self.assertEqual(self.request("/settings")[0], 405)
        self.assertFalse(self.settings_file.exists())
        self.assertIsNone(self.service._watchers_runtime)
        code, caps = self.request("/settings", {**valid, "changed_via": "x" * 40})
        self.assertEqual(code, 200)
        self.assertTrue(caps["enabled"])
