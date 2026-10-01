import unittest

from herdr_harness.first_mate_runtime import COORDINATOR_PROMPT, LEAD_PROMPT, WORKER_PROMPT
from herdr_harness.workflow_policy import MARKER, POLICY_TEXT, append_workflow_policy


class WorkflowPolicyTests(unittest.TestCase):
    def test_every_dispatch_role_has_current_operating_policy(self):
        for charter in (LEAD_PROMPT, COORDINATOR_PROMPT, WORKER_PROMPT):
            self.assertIn(POLICY_TEXT, charter)
            self.assertEqual(charter.count(MARKER), 1)
            self.assertIn("gh pr create --draft", charter)

    def test_current_policy_is_independent_of_legacy_personality(self):
        prompt = "Legacy pinned personality snapshot"
        updated = append_workflow_policy(prompt)
        self.assertTrue(updated.startswith(prompt))
        self.assertIn(POLICY_TEXT, updated)
        self.assertEqual(append_workflow_policy(updated), updated)
