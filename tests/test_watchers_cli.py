"""CLI JSON, pre-checks and machine routing through an in-memory HTTP transport."""
from datetime import datetime, timedelta, timezone
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from scripts import herdr_watchers_cli as cli
from herdr_harness.watchers.validation import example


class Response:
    def __init__(self, url, data):
        self.url, self.data = url, json.dumps(data).encode()
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def read(self, *args):
        return self.data
    def geturl(self):
        return self.url


class WatchersCLITests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.caps = {"ok": True, "enabled": True, "capabilities": ["watchers-v1"], "supervised": True, "timezone": "UTC", "steps": ["script", "gate", "deliver"], "scheduler": {"running": True, "last_tick_at": datetime.now(timezone.utc).isoformat()}}
        self.failure = None
        self.environment = {"HERDR_HARNESS_API_TOKEN": "synthetic-cli-token", "HERDR_HARNESS_URL": "http://127.0.0.1:9092"}
        self.config = SimpleNamespace(environ=self.environment, public_machines=lambda: [{"id": "remote", "name": "Example remote"}])

    def opener(self, request, timeout):
        self.calls.append((request.method, request.full_url, json.loads(request.data) if request.data else None, request.headers))
        if self.failure:
            raise self.failure
        result = self.caps if request.full_url.endswith("/capabilities") else {"ok": True, "watchers": [], "watcher": {"id": "wat_example"}}
        return Response(request.full_url, result)

    def run_cli(self, args, data=""):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(cli, "load_configuration", return_value=self.config), patch.object(cli, "connection_environment", side_effect=lambda environment: environment), patch.object(cli, "machine_timezone", return_value="America/Chicago"):
            code = cli.main([*args, "--request-id", "synthetic-request"], environ=self.environment, stdin=io.StringIO(data), stdout=stdout, stderr=stderr, opener=self.opener)
        return code, json.loads(stdout.getvalue()) if stdout.getvalue() else None, json.loads(stderr.getvalue()) if stderr.getvalue() else None

    def test_schema_and_example_work_without_connection(self):
        for command in ("schema", "example"):
            code, result, error = self.run_cli([command, "--machine", "remote"])
            self.assertEqual(code, 0)
            self.assertTrue(result["ok"])
            self.assertIsNone(error)
        self.assertEqual(self.calls, [])
        self.assertEqual(result["definition"]["timezone"], "America/Chicago")
        self.assertEqual(set(result["scripts"]), {"check"})

    def test_validate_emits_normalized_definition_and_domain_errors(self):
        code, result, _ = self.run_cli(["validate", "--definition-file", "-"], json.dumps(example()["definition"]))
        self.assertEqual(code, 0)
        self.assertEqual(result["definition"]["kind"], "script")
        code, stdout, error = self.run_cli(["validate", "--definition-file", "-"], "{}")
        self.assertEqual(code, 2)
        self.assertIsNone(stdout)
        self.assertEqual(error["error"]["code"], "invalid_definition")

    def test_selected_machine_uses_control_machine_client(self):
        remote = SimpleNamespace(base_url="https://example.invalid", token="synthetic-remote-token")
        with patch.object(cli, "machine_client", return_value=remote) as select:
            code, _, _ = self.run_cli(["list", "--machine", "remote", "--source", "cronboard"])
        self.assertEqual(code, 0)
        self.assertEqual(select.call_args.args[1], "remote")
        self.assertEqual(self.calls[0][1], "https://example.invalid/api/v1/watchers/capabilities")
        self.assertEqual(self.calls[-1][1], "https://example.invalid/api/v1/watchers?source=cronboard")
        self.assertEqual(self.calls[-1][3]["Authorization"], "Bearer synthetic-remote-token")

    def test_every_remote_command_checks_capability_before_mutating(self):
        self.caps["enabled"] = False
        code, stdout, error = self.run_cli(["pause", "wat_example"])
        self.assertEqual(code, 2)
        self.assertIsNone(stdout)
        self.assertEqual(error["error"]["code"], "watchers_disabled")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], "GET")

    def test_draft_uses_creator_timezone_for_remote_machine(self):
        value = example()["definition"]
        value.pop("timezone")
        code, _, _ = self.run_cli(["draft", "create", "--definition-file", "-"], json.dumps(value))
        self.assertEqual(code, 0)
        self.assertEqual(self.calls[-1][0], "POST")
        self.assertEqual(self.calls[-1][2]["definition"]["timezone"], "America/Chicago")
        self.assertEqual(self.calls[-1][2]["request_id"], "synthetic-request")
        code, stdout, error = self.run_cli(["draft", "create", "--definition-file", "-"], "[]")
        self.assertEqual(code, 2)
        self.assertEqual(error["error"]["code"], "invalid_definition")

    def test_script_put_passes_revision_and_body_while_get_is_readonly(self):
        self.assertEqual(self.run_cli(["script", "put", "wat_example", "--step", "check", "--expected-revision", "3"], "printf example\n")[0], 0)
        self.assertEqual(self.calls[-1][:3], ("PUT", "http://127.0.0.1:9092/api/v1/watchers/wat_example/scripts/check", {"request_id": "synthetic-request", "expected_revision": 3, "content": "printf example\n"}))
        self.assertEqual(self.run_cli(["script", "get", "wat_example", "--step", "check"])[0], 0)
        self.assertEqual(self.calls[-1][0], "GET")

    def test_partial_draft_update_does_not_change_the_watchers_timezone(self):
        code, _, _ = self.run_cli(["draft", "update", "wat_example", "--expected-revision", "2", "--definition-file", "-"], '{"name":"Renamed watcher"}')
        self.assertEqual(code, 0)
        self.assertEqual(self.calls[-1][0], "PATCH")
        self.assertEqual(self.calls[-1][2]["definition"], {"name": "Renamed watcher"})

    def test_person_activation_requires_confirmation(self):
        code, _, error = self.run_cli(["activate", "wat_example"])
        self.assertEqual(code, 2)
        self.assertEqual(error["error"]["code"], "confirmation_required")
        self.assertTrue(all(call[0] == "GET" for call in self.calls))
        self.assertEqual(self.run_cli(["activate", "wat_example", "--i-confirm"])[0], 0)
        self.assertEqual(self.calls[-1][2]["confirmed_by"], "user")

    def test_doctor_requires_recent_tick_and_supervision(self):
        self.assertEqual(self.run_cli(["doctor"])[0], 0)
        self.caps["scheduler"]["last_tick_at"] = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        code, _, error = self.run_cli(["doctor"])
        self.assertEqual(code, 2)
        self.assertIn("tick is stale", error["error"]["message"])
        self.caps["supervised"] = False
        self.assertIn("supervised", self.run_cli(["doctor"])[2]["error"]["message"])

    def test_revision_conflict_exit_and_error_redaction(self):
        self.failure = HTTPError("http://127.0.0.1:9092", 409, "Conflict", {}, io.BytesIO(json.dumps({"ok": False, "error": {"code": "revision_conflict", "message": "Conflict synthetic-cli-token"}}).encode()))
        code, stdout, error = self.run_cli(["list"])
        self.assertEqual(code, 4)
        self.assertIsNone(stdout)
        self.assertEqual(error["error"]["code"], "revision_conflict")
        self.assertNotIn("synthetic-cli-token", error["error"]["message"])

    def test_unreachable_machine_gets_contract_error(self):
        self.failure = URLError("offline")
        code, _, error = self.run_cli(["list"])
        self.assertEqual(code, 2)
        self.assertEqual(error["error"]["code"], "machine_unreachable")

    def test_source_batch_and_import_preview_bodies(self):
        self.assertEqual(self.run_cli(["pause", "--source", "cronboard"])[0], 0)
        self.assertEqual(self.calls[-1][2], {"request_id": "synthetic-request", "action": "pause", "source": "cronboard"})
        self.assertEqual(self.run_cli(["import", "--cronboard-json", "-", "--dry-run", "--i-confirm"], "[]")[0], 0)
        self.assertEqual(self.calls[-1][2], {"request_id": "synthetic-request", "source": "cronboard", "jobs": [], "dry_run": True, "timezone": "America/Chicago", "confirmed_by": "user"})

    def test_machines_reports_reachability_and_supported_contract(self):
        with patch.object(cli, "machine_client", return_value=SimpleNamespace(base_url="https://example.invalid", token="synthetic-remote-token")):
            code, result, _ = self.run_cli(["machines"])
        self.assertEqual(code, 0)
        row = result["machines"][0]
        self.assertEqual(row["id"], "remote")
        self.assertTrue(row["reachable"])
        self.assertIn("watchers-v1", row["capabilities"])
        self.assertTrue(row["supervised"])

    def test_enable_and_disable_are_person_steps(self):
        for command in ("enable", "disable"):
            with self.subTest(command=command):
                code, stdout, error = self.run_cli([command, "--machine", "remote"])
                self.assertEqual(code, 2)
                self.assertIsNone(stdout)
                self.assertEqual(error["error"]["code"], "confirmation_required")
                self.assertIn("--i-confirm", error["error"]["message"])
        self.assertEqual(self.calls, [])

    def test_enable_and_disable_post_the_settings_body(self):
        self.caps.update(enabled=False, capabilities=[], settings={"enabled": False, "source": "default", "changeable": True})
        for command, enabled in (("enable", True), ("disable", False)):
            with self.subTest(command=command):
                self.assertEqual(self.run_cli([command, "--i-confirm"])[0], 0)
                self.assertEqual(self.calls[-1][:3], ("POST", "http://127.0.0.1:9092/api/v1/watchers/settings",
                                                     {"request_id": "synthetic-request", "enabled": enabled, "confirmed_by": "user", "changed_via": "cli"}))
                self.assertEqual(self.calls[-1][3]["Authorization"], "Bearer synthetic-cli-token")

    def test_enable_reports_an_older_companion_and_a_configuration_lock(self):
        self.caps.update(enabled=False, capabilities=[])
        code, _, error = self.run_cli(["enable", "--i-confirm"])
        self.assertEqual(code, 2)
        self.assertEqual(error["error"]["code"], "watchers_settings_unsupported")
        self.assertTrue(all(call[0] == "GET" for call in self.calls))
        self.caps["settings"] = {"enabled": False, "source": "config", "changeable": False}
        message = "HERDR_WATCHERS_ENABLED is set in this companion's configuration. Change it there and restart the companion."
        self.failure = HTTPError("http://127.0.0.1:9092", 409, "Conflict", {}, io.BytesIO(json.dumps({"ok": False, "error": {"code": "watchers_setting_locked", "message": message}}).encode()))
        code, _, error = self.run_cli(["enable", "--i-confirm"])
        self.assertEqual(code, 4)
        self.assertEqual(error["error"]["code"], "watchers_setting_locked")

    def test_disabled_guidance_points_to_the_app_or_configuration(self):
        self.caps.update(enabled=False, capabilities=[], settings={"enabled": False, "source": "default", "changeable": True})
        for args in (["doctor"], ["list"]):
            with self.subTest(args=args):
                code, _, error = self.run_cli(args)
                self.assertEqual(code, 2)
                self.assertIn("Mac app (Watchers → New watcher → Runs on)", error["error"]["message"])
                self.assertIn("herdr-watchers enable --i-confirm", error["error"]["message"])
                self.assertNotIn("HERDR_WATCHERS_ENABLED=1", error["error"]["message"])
        with patch.object(cli, "machine_client", return_value=SimpleNamespace(base_url="https://example.invalid", token="synthetic-remote-token")):
            self.assertIn("herdr-watchers enable --machine remote --i-confirm", self.run_cli(["doctor", "--machine", "remote"])[2]["error"]["message"])
        self.caps["settings"] = {"enabled": False, "source": "config", "changeable": False}
        message = self.run_cli(["doctor"])[2]["error"]["message"]
        self.assertIn("HERDR_WATCHERS_ENABLED in this companion's configuration", message)
        self.assertNotIn("enable --i-confirm", message)

    def test_machines_rows_include_settings_and_a_hint_when_off(self):
        self.caps["settings"] = {"enabled": True, "source": "app", "changeable": True}
        with patch.object(cli, "machine_client", return_value=SimpleNamespace(base_url="https://example.invalid", token="synthetic-remote-token")):
            row = self.run_cli(["machines"])[1]["machines"][0]
            self.assertEqual(row["settings"], {"enabled": True, "source": "app", "changeable": True})
            self.assertNotIn("hint", row)
            self.caps.update(enabled=False, capabilities=[], settings={"enabled": False, "source": "default", "changeable": True})
            row = self.run_cli(["machines"])[1]["machines"][0]
        self.assertEqual(row["settings"]["source"], "default")
        self.assertIn("herdr-watchers enable --machine remote --i-confirm", row["hint"])
