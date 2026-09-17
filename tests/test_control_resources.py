import tempfile
import unittest

from herdr_harness.client import HerdrClientError
from herdr_harness.control_resources import ResourceActionService
from herdr_harness.control_store import ControlStore
from herdr_harness.control_validation import ControlError


class FakePiSemantic:
    def capability(self, pane_id):
        return {"connected": True, "session_id": "session-1"}


class FakeResourceService:
    def __init__(self):
        self.pi_semantic = FakePiSemantic()
        self.calls = []
        self.failure = None
        self.invoke_response = {"ok": True, "result": {}}
        self.snapshot = {
            "workspaces": [{"workspace_id": "w1", "label": "Synthetic"}],
            "tabs": [{"tab_id": "t1", "workspace_id": "w1", "label": "Work"}],
            "panes": [
                {
                    "pane_id": "p1",
                    "terminal_id": "terminal-1",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                }
            ],
        }

    def refresh_snapshot(self, force=False):
        return self.snapshot

    def invoke(self, method, parameters):
        self.calls.append((method, parameters))
        if self.failure is not None:
            raise self.failure
        return self.invoke_response

    def set_pane_star(self, pane_id, starred):
        self.calls.append(("pane.star", {"pane_id": pane_id, "starred": starred}))
        return {"ok": True}

    def pi_command(self, pane_id, command, payload):
        self.calls.append((f"pi.{command}", {"pane_id": pane_id, **payload}))
        return {"ok": True}


class ControlResourceTests(unittest.TestCase):
    def setUp(self):
        self.store = ControlStore(":memory:")
        self.addCleanup(self.store.close)
        self.service = FakeResourceService()
        self.resources = ResourceActionService(self.service, self.store)
        self.target = {
            "kind": "pane",
            "serverId": self.store.server_id,
            "workspaceId": "w1",
            "tabId": "t1",
            "paneId": "p1",
            "terminalId": "terminal-1",
            "sessionId": "session-1",
        }

    def request(self, request_id="rename-1", target=None):
        return {
            "requestId": request_id,
            "action": "pane.rename",
            "target": target or self.target,
            "parameters": {"name": "Renamed"},
            "dryRun": False,
        }

    def test_registry_advertises_the_typed_minimum_actions(self):
        identifiers = {item["id"] for item in self.resources.actions()}
        self.assertTrue(
            {
                "workspace.create",
                "tab.create",
                "chat.create",
                "workspace.rename",
                "tab.rename",
                "pane.rename",
                "pane.star",
                "pane.split",
                "pane.close",
                "pane.retire",
                "pane.compact",
                "pane.interrupt",
                "pane.focus-terminal",
                "pane.zoom-terminal",
            }.issubset(identifiers)
        )
        self.assertTrue(
            all(item["parameters"].get("additionalProperties") is False for item in self.resources.actions())
        )

    def test_exact_resource_mutation_is_durable_and_deduped(self):
        first = self.resources.invoke(self.request())
        second = self.resources.invoke(self.request())
        self.assertEqual(first, second)
        self.assertEqual(first["status"], "completed")
        self.assertEqual(
            self.service.calls,
            [("pane.rename", {"pane_id": "p1", "label": "Renamed"})],
        )
        self.assertEqual(first["result"]["target"], self.target)

    def test_reused_pane_terminal_or_session_is_rejected_without_mutation(self):
        stale = {**self.target, "terminalId": "terminal-old"}
        operation = self.resources.invoke(self.request("stale-terminal", stale))
        self.assertEqual(operation["status"], "failed")
        self.assertEqual(operation["error"]["code"], "stale_target")
        self.assertEqual(self.service.calls, [])

        stale_session = {**self.target, "sessionId": "session-old"}
        operation = self.resources.invoke(self.request("stale-session", stale_session))
        self.assertEqual(operation["status"], "failed")
        self.assertEqual(operation["error"]["code"], "stale_target")
        self.assertEqual(self.service.calls, [])

    def test_uncertain_upstream_failure_is_not_retried(self):
        self.service.failure = HerdrClientError("timed out", code="herdr_timeout")
        first = self.resources.invoke(self.request("uncertain"))
        self.assertEqual(first["status"], "outcome_unknown")
        self.service.failure = None
        second = self.resources.invoke(self.request("uncertain"))
        self.assertEqual(second, first)
        self.assertEqual(len(self.service.calls), 1)

    def test_post_effect_malformed_response_is_unknown_and_retry_does_not_revalidate_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = {
                "requestId": "create-malformed",
                "action": "workspace.create",
                "parameters": {"name": "Created", "cwd": directory},
                "dryRun": False,
            }
            self.service.invoke_response = "malformed"
            first = self.resources.invoke(payload)
            self.assertEqual(first["status"], "outcome_unknown")
        self.service.invoke_response = {"ok": True, "result": {"workspace_id": "must-not-run"}}
        second = self.resources.invoke(payload)
        self.assertEqual(second, first)
        self.assertEqual(len(self.service.calls), 1)

    def test_creation_uses_only_rpc_identity_and_verifies_amid_concurrent_siblings(self):
        with tempfile.TemporaryDirectory() as directory:
            self.service.invoke_response = {
                "ok": True,
                "result": {"workspace_id": "w-exact"},
            }
            self.service.snapshot["workspaces"].extend(
                [
                    {"workspace_id": "w-exact", "label": "Exact"},
                    {"workspace_id": "w-unrelated", "label": "Concurrent"},
                ]
            )
            payload = {
                "requestId": "create-exact",
                "action": "workspace.create",
                "parameters": {"name": "Exact", "cwd": directory},
                "dryRun": False,
            }
            operation = self.resources.invoke(payload)
            self.assertEqual(operation["status"], "completed")
            self.assertEqual(operation["result"]["target"]["workspaceId"], "w-exact")

            missing = {**payload, "requestId": "create-missing"}
            self.service.invoke_response = {"ok": True, "result": {}}
            unresolved = self.resources.invoke(missing)
            self.assertEqual(unresolved["status"], "outcome_unknown")
            self.assertNotIn("target", unresolved.get("result", {}))

    def test_dry_run_validates_identity_without_mutation_or_receipt(self):
        payload = self.request("dry-run")
        payload["dryRun"] = True
        result = self.resources.invoke(payload)
        self.assertEqual(result["status"], "completed")
        self.assertTrue(result["result"]["dryRun"])
        self.assertEqual(self.service.calls, [])
        with self.assertRaises(ControlError):
            self.store.operation("dry-run")
