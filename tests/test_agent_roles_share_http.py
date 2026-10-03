import json
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.request

from herdr_harness.agent_roles import AgentRoles
from herdr_harness.server import make_server, api_description
from tests.test_herdr_http import FakeHTTPService
from tests.test_agent_roles_share import bundle, reviewer, worker


class AgentRolesShareHTTPTests(unittest.TestCase):
    def setUp(self):
        self.service = FakeHTTPService()
        self.service.agent_roles = AgentRoles(machine_id="synthetic", environ={})
        self.service.environ.update(HERDR_HARNESS_API_TOKEN="synthetic-main-token",
                                    HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN="synthetic-scoped-token")
        self.server = make_server(self.service, host="127.0.0.1", port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.cleanup)
        self.base = "http://127.0.0.1:" + str(self.server.server_address[1]) + "/api/v1/agent-roles"

    def cleanup(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.service.agent_roles.close()

    def request(self, path="", body=None, token="synthetic-main-token", raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(self.base + path, data=data,
                                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)

    def seed(self):
        skill = bundle()
        role, review = worker(skillIds=[skill["id"]]), reviewer()
        roles = self.service.agent_roles
        roles.mutate({"action": "save", "expectedRevision": 0, "role": role, "skillBundles": [skill]})
        roles.mutate({"action": "save", "expectedRevision": 1, "role": review})
        return role, review

    def test_capability_and_endpoints_are_advertised(self):
        description = api_description()
        self.assertIn("agent-roles-share-v1", description["capabilities"])
        self.assertEqual(description["endpoints"]["agentRolesExport"], "/api/v1/agent-roles/export")
        self.assertEqual(description["endpoints"]["agentRolesImport"], "/api/v1/agent-roles/import")
        self.assertIn("POST /api/v1/agent-roles/import", description["mutations"])
        self.assertIn("agent-roles-share-v1", self.request()["capabilities"])

    def test_full_authentication_is_required(self):
        for token in ("wrong", "synthetic-scoped-token"):
            for path, body in (("/export?preview=1", None), ("/export", None), ("/import", {"document": {}})):
                with self.subTest(token=token, path=path), self.assertRaises(urllib.error.HTTPError) as caught:
                    self.request(path, body, token=token)
                self.assertEqual(caught.exception.code, 401)

    def test_export_then_import_round_trip_publishes_once(self):
        role, review = self.seed()
        preview = self.request("/export?preview=1")
        self.assertIn(role["id"], {row["id"] for row in preview["roles"]})
        exported = self.request(f"/export?roleIds={role['id']},{review['id']}")
        document = exported["document"]
        self.assertEqual([item["id"] for item in document["roles"]], [role["id"], review["id"]])
        target = AgentRoles(machine_id="synthetic-target", environ={})
        self.addCleanup(target.close)
        self.service.agent_roles, original = target, self.service.agent_roles
        self.addCleanup(original.close)
        with mock.patch.object(self.service.broker, "publish", wraps=self.service.broker.publish) as publish:
            plan = self.request("/import", {"document": document, "dryRun": True})
            self.assertEqual(publish.call_count, 0)
            result = self.request("/import", {"document": document, "dryRun": False, "planDigest": plan["planDigest"],
                                              "expectedRevision": plan["revision"],
                                              "roleIds": [role["id"], review["id"]]})
            self.assertEqual(publish.call_count, 1)
            self.assertEqual(publish.call_args.args[0], "agent_roles.changed")
            again = self.request("/import", {"document": document, "dryRun": True})
            unchanged = self.request("/import", {"document": document, "dryRun": False,
                                                 "planDigest": again["planDigest"],
                                                 "expectedRevision": again["revision"], "roleIds": [role["id"]]})
            self.assertEqual(publish.call_count, 1)
        self.assertEqual(result["imported"], {"created": 2, "updated": 0, "unchanged": 0})
        self.assertEqual(unchanged["imported"], {"created": 0, "updated": 0, "unchanged": 1})
        self.assertIn(review["id"], {item["id"] for item in result["overview"]["roles"]})

    def test_errors_use_stable_codes(self):
        role, _ = self.seed()
        document = self.request(f"/export?roleIds={role['id']}")["document"]
        cases = [
            ("/export?roleIds=planner", None, 400, "invalid_agent_role"),
            ("/import", {"document": {**document, "format": "other"}, "dryRun": True}, 400, "invalid_agent_roles_document"),
            ("/import", {"document": document, "dryRun": False, "planDigest": "0" * 64, "expectedRevision": 99,
                         "roleIds": []}, 409, "agent_role_conflict"),
        ]
        for path, body, status, code in cases:
            with self.subTest(path=path, code=code), self.assertRaises(urllib.error.HTTPError) as caught:
                self.request(path, body)
            self.assertEqual(caught.exception.code, status)
            self.assertEqual(json.load(caught.exception)["error"]["code"], code)

    def test_import_accepts_large_documents_and_rejects_deep_nesting(self):
        role, _ = self.seed()
        document = self.request(f"/export?roleIds={role['id']}")["document"]
        padded = {"document": document, "dryRun": True, "padding": "x" * (2 * 1024 * 1024)}
        self.assertTrue(self.request("/import", padded)["ok"])
        deep = b'{"document":' + b"[" * 100000 + b"]" * 100000 + b"}"
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/import", raw=deep)
        self.assertEqual(caught.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
