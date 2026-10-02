import json
import threading
import unittest
import urllib.error
import urllib.request

from herdr_harness.agent_roles import AgentRoles
from herdr_harness.server import make_server, api_description
from tests.test_herdr_http import FakeHTTPService
from tests.test_agent_roles import custom_role, skill_bundle


class AgentRolesHTTPTests(unittest.TestCase):
    def setUp(self):
        self.service = FakeHTTPService()
        self.service.agent_roles = AgentRoles(machine_id="synthetic", environ={})
        self.service.environ.update(HERDR_HARNESS_API_TOKEN="synthetic-main-token",
                                    HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN="synthetic-scoped-token")
        self.server = make_server(self.service, host="127.0.0.1", port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.cleanup)
        self.url = "http://127.0.0.1:" + str(self.server.server_address[1]) + "/api/v1/agent-roles"

    def cleanup(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.service.agent_roles.close()

    def request(self, body=None, token="synthetic-main-token"):
        request = urllib.request.Request(self.url, data=json.dumps(body).encode() if body else None,
                                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=3) as response:
            return json.load(response)

    def test_full_authentication_is_required(self):
        for token in ("wrong", "synthetic-scoped-token"):
            for body in (None, {"action": "save", "role": custom_role(), "expectedRevision": 0}):
                with self.subTest(token=token, body=body), self.assertRaises(urllib.error.HTTPError) as caught:
                    self.request(body=body, token=token)
                self.assertEqual(caught.exception.code, 401)
        self.assertEqual(self.service.agent_roles.overview()["revision"], 0)

    def test_catalog_save_conflict_and_delete_round_trip(self):
        overview = self.request()
        self.assertEqual(overview["capability"], "agent-roles-v1")
        self.assertIn("agent-roles-v1", api_description()["capabilities"])
        bundle = skill_bundle()
        role = custom_role(skillIds=[bundle["id"]])
        saved = self.request({"action": "save", "role": role, "skillBundles": [bundle], "expectedRevision": 0})
        self.assertEqual(saved["revision"], 1)
        self.assertIn(role["id"], {r["id"] for r in saved["roles"]})
        self.assertEqual(saved["skills"][0]["id"], bundle["id"])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request({"action": "save", "role": {**role, "name": "Stale edit"}, "expectedRevision": 0})
        self.assertEqual(caught.exception.code, 409)
        self.assertEqual(json.load(caught.exception)["error"]["code"], "agent_role_conflict")
        result = self.request({"action": "delete", "roleId": role["id"], "expectedRevision": 1})
        self.assertEqual(result["revision"], 2)
        self.assertNotIn(role["id"], {r["id"] for r in result["roles"]})

    def test_skill_upload_exceeds_the_ordinary_json_body_limit(self):
        bundle = skill_bundle(text="---\nname: synthetic-large\ndescription: Synthetic fixture.\n---\n" + "x" * 800000)
        role = custom_role(skillIds=[bundle["id"]])
        result = self.request({"action": "save", "role": role, "skillBundles": [bundle], "expectedRevision": 0})
        self.assertEqual(result["revision"], 1)

    def test_bad_input_returns_safe_validation_error(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request({"action": "save", "role": custom_role(skillIds=["/private/path"]), "expectedRevision": 0})
        self.assertEqual(caught.exception.code, 400)
        self.assertNotIn("/private/path", caught.exception.read().decode())


if __name__ == "__main__":
    unittest.main()
