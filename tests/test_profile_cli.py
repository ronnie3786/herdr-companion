import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

from herdr_harness.profile_cli import main


class Client:
    token = "synthetic-profile-token"
    def __init__(self):
        self.requests = []
    def request(self, method, path, payload=None, **kwargs):
        self.requests.append((method, path, payload))
        return {"ok": True, "machineId": "desktop", "binding": {}, "profiles": [], "effective": {"prompt": ""}}


class ProfileCLITests(unittest.TestCase):
    def test_list_and_effective_are_read_only_and_metadata_bounded(self):
        client = Client()
        with patch("herdr_harness.profile_cli.ControlCLI.client", return_value=client):
            output = io.StringIO()
            self.assertEqual(main(["--machine", "desktop", "list"], environ={}, stdout=output), 0)
            self.assertNotIn("effective", json.loads(output.getvalue()))
            self.assertEqual(client.requests[0][0], "GET")

    def test_proposal_requires_explicit_revision_and_id_and_never_approves(self):
        client = Client()
        with tempfile.TemporaryDirectory() as root, patch("herdr_harness.profile_cli.ControlCLI.client", return_value=client):
            path = Path(root) / "draft.md"
            path.write_text("Prefer direct answers")
            pid, rid = str(uuid.uuid4()), str(uuid.uuid4())
            args = ["--machine", "desktop", "propose", pid, "--expected-revision", "2", "--soul-file", str(path),
                    "--user-file", str(path), "--reason", "Requested", "--request-id", rid]
            self.assertEqual(main(args, environ={}, stdout=io.StringIO()), 0)
            method, _, body = client.requests[0]
            self.assertEqual(method, "POST")
            self.assertEqual(body["action"], "propose")
            self.assertEqual(body["requestId"], rid)
            for env in [{"HERDR_AGENT_RUN_MODE": "ask"}, {"HERDR_FIRST_MATE_MANAGED_ROLE": "coordinator"},
                        {"HERDR_FIRST_MATE_MANAGED_ROLE": "advisor"},
                        {"HERDR_FIRST_MATE_MANAGED_ROLE": "worker", "HERDR_FIRST_MATE_WORKSPACE_MODE": "read_only"}]:
                self.assertEqual(main(args, environ=env, stderr=io.StringIO()), 2)
            self.assertEqual(len(client.requests), 1)
            self.assertEqual(main(args, environ={"HERDR_FIRST_MATE_MANAGED_ROLE": "worker", "HERDR_FIRST_MATE_WORKSPACE_MODE": "isolated"}, stdout=io.StringIO()), 0)
            self.assertEqual(client.requests[-1][2]["action"], "propose")


if __name__ == "__main__":
    unittest.main()
