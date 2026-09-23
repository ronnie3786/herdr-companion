import copy
import json
import tempfile
import unittest
from pathlib import Path

from herdr_harness import assistant
from herdr_harness.agent_runs import AgentRunError, AgentRunManager
from tests.test_agent_runs import wait_for_status, write_fake_pi


class PRReviewQuestionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.capture = self.root / "capture.json"
        self.manager = AgentRunManager(
            environ={
                "HERDR_HARNESS_AGENT_PI_BIN": str(write_fake_pi(self.root)),
                "FAKE_AGENT_CAPTURE": str(self.capture),
            },
            runs_root=self.root / "runs",
            herdr_socket_path="/tmp/synthetic-question.sock",
            herdr_session="synthetic-question",
        )
        self.request = {
            "prompt": "Explain the changed garden code",
            "profile": "pr-review-question-v1",
            "clientRequestId": "11111111-1111-1111-1111-111111111111",
            "scope": {"reviewId": "prr_0123456789ab", "expectedRootPath": str(self.checkout)},
            "context": {
                "version": 1,
                "snapshotId": "synthetic-snapshot",
                "capturedAt": "2026-09-21T00:00:00Z",
                "source": {"feature": "pr-review", "instanceId": "synthetic-instance"},
                "items": [],
            },
        }

    def tearDown(self):
        self.manager.stop()
        self.temp.cleanup()

    def start(self, request):
        return assistant.start(self.manager, request=request, cwd=str(self.checkout), pane_id=None, workspace_id=None)["run"]

    def test_review_questions_use_read_only_tools_and_scope_is_strict(self):
        root = self.start(self.request)
        wait_for_status(self.manager, root["id"], {"completed"})
        capture = json.loads(self.capture.read_text())
        self.assertIn("--tools", capture["argv"])
        self.assertEqual(capture["argv"][capture["argv"].index("--tools") + 1], "read,grep,find,ls")
        self.assertNotIn("--no-tools", capture["argv"])
        self.assertNotIn("--extension", capture["argv"])
        self.assertIn("--no-approve", capture["argv"])
        self.assertEqual(capture["cwd"], str(self.checkout.resolve()))
        charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
        self.assertIn("Always give me the ‘short version’ unless I ask for the long version or for more details.", charter)
        self.assertIn("reference only", charter)
        self.assertNotIn("herdr-companion-awareness", charter)
        self.assertEqual(capture["herdrAgentRunProfile"], "pr-review-question-v1")

        follow = copy.deepcopy(self.request)
        follow.update({
            "profile": "contextual-question-v1",
            "clientRequestId": "22222222-2222-2222-2222-222222222222",
            "continueFromRunId": root["id"],
        })
        follow.pop("scope")
        with self.assertRaises(AgentRunError) as error:
            self.start(follow)
        self.assertEqual(error.exception.code, "assistant_scope_changed")


if __name__ == "__main__":
    unittest.main()
