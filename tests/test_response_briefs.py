import copy
import json
import tempfile
import unittest
from pathlib import Path

from herdr_harness import assistant, hud_chats, response_briefs
from herdr_harness.agent_runs import AgentRunError, AgentRunManager
from herdr_harness.resources import pi_lineage_extension_path
from tests.test_agent_runs import wait_for_status, write_fake_pi


class ResponseBriefTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.capture = self.root / "capture.json"
        self.manager = AgentRunManager(
            environ={
                "HERDR_HARNESS_AGENT_PI_BIN": str(write_fake_pi(self.root)),
                "FAKE_AGENT_CAPTURE": str(self.capture),
            },
            runs_root=self.root / "runs",
            herdr_socket_path="/tmp/synthetic-herdr.sock",
            herdr_session="synthetic-machine",
        )
        self.request = {
            "prompt": "Create the response brief.",
            "profile": response_briefs.PROFILE,
            "mode": "ask",
            "clientRequestId": "brief-request-00000001",
            "parentSessionId": "source-session-0001",
            "model": "openai-codex/gpt-5.6-luna",
            "thinkingLevel": "low",
            "context": {
                "version": 1,
                "snapshotId": "brief-snapshot-1",
                "capturedAt": "2026-09-17T00:00:00Z",
                "source": {
                    "feature": "chat.response-brief",
                    "instanceId": "synthetic-response-1",
                },
                "items": [
                    {
                        "id": "response-part-1",
                        "kind": "text.v1",
                        "label": "Original response part 1 of 1 (concatenate verbatim in order)",
                        "priority": "required",
                        "text": "Sensitive source line one.\n\nSource line three.\r",
                    }
                ],
            },
        }

    def tearDown(self):
        self.manager.stop()
        self.temp.cleanup()

    def start(self, request=None):
        return response_briefs.start(
            self.manager,
            request=request or self.request,
            cwd=str(self.root),
            pane_id=None,
            workspace_id=None,
        )["run"]

    def test_capability_advertises_profile_and_bounds(self):
        capabilities = assistant.capabilities()
        self.assertIn(response_briefs.PROFILE, capabilities["profiles"])
        self.assertEqual(
            capabilities["responseBriefs"],
            {
                "version": 1,
                "tools": "none",
                "oneShot": True,
                "maxOutputBytes": response_briefs.MAX_OUTPUT_BYTES,
                "requiresParentSessionId": True,
            },
        )

    def test_run_is_isolated_uses_lineage_only_and_keeps_captured_data_on_stdin(self):
        run = self.start()
        finished = wait_for_status(self.manager, run["id"], {"completed"})["run"]
        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        argv = capture["argv"]

        self.assertEqual(finished["profile"], response_briefs.PROFILE)
        self.assertIn("--no-tools", argv)
        self.assertNotIn("--tools", argv)
        for flag in ("--no-context-files", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-approve"):
            self.assertIn(flag, argv)
        extension = argv[argv.index("--extension") + 1]
        self.assertTrue(extension.endswith("/extensions/response-brief-lineage.ts"))
        self.assertNotIn("pi-semantic-bridge.ts", extension)
        self.assertIsNone(capture["herdrPiSessionId"])
        self.assertEqual(capture["herdrPiParentSessionId"], self.request["parentSessionId"])
        self.assertEqual(argv.count("--herdr-parent-session-id"), 1)
        self.assertEqual(
            argv[argv.index("--herdr-parent-session-id") + 1],
            self.request["parentSessionId"],
        )
        self.assertIn(self.request["prompt"], capture["prompt"])
        self.assertIn("Sensitive source line one.", capture["prompt"])
        self.assertNotIn(self.request["prompt"], " ".join(argv))
        self.assertNotIn("Sensitive source line one.", " ".join(argv))
        charter = argv[argv.index("--append-system-prompt") + 1]
        self.assertIn(response_briefs.OUTPUT_SCHEMA, charter)
        self.assertIn(
            "Concatenate the required Original response parts literally in context order, "
            "inserting no separators",
            charter,
        )
        self.assertIn("splitting the result only on LF", charter)
        self.assertIn("at or below 140 words", charter)
        self.assertEqual(argv[argv.index("--name") + 1], "Response brief")

    def test_each_request_uses_a_distinct_fresh_child_with_the_same_source_parent(self):
        first = self.start()
        wait_for_status(self.manager, first["id"], {"completed"})
        second_request = copy.deepcopy(self.request)
        second_request["clientRequestId"] = "brief-request-00000002"
        second_request["context"]["source"]["instanceId"] = "synthetic-response-2"
        second = self.start(second_request)
        wait_for_status(self.manager, second["id"], {"completed"})
        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        argv = capture["argv"]

        self.assertNotEqual(first["sessionId"], second["sessionId"])
        self.assertNotEqual(first["sessionId"], self.request["parentSessionId"])
        self.assertNotEqual(second["sessionId"], self.request["parentSessionId"])
        self.assertEqual(argv[argv.index("--session-id") + 1], second["sessionId"])
        self.assertEqual(
            argv[argv.index("--herdr-parent-session-id") + 1],
            self.request["parentSessionId"],
        )

    def test_same_request_is_idempotent_and_changed_payload_conflicts(self):
        first = self.start()
        second = self.start()
        self.assertEqual(first["id"], second["id"])
        changed = copy.deepcopy(self.request)
        changed["prompt"] = "A different request."
        with self.assertRaises(AgentRunError) as error:
            self.start(changed)
        self.assertEqual(error.exception.code, "assistant_request_conflict")

    def test_profile_validation_precedes_durable_request_tombstone(self):
        invalid_requests = []
        for parent in (None, "", "../source", "--source", "source\n", 42, "x" * 257):
            request = copy.deepcopy(self.request)
            if parent is None:
                request.pop("parentSessionId")
            else:
                request["parentSessionId"] = parent
            invalid_requests.append(request)
        for field, value in (
            ("attachments", []),
            ("systemPrompt", "override"),
            ("continueFromRunId", "agr_0123456789ab"),
        ):
            request = copy.deepcopy(self.request)
            request[field] = value
            invalid_requests.append(request)
        wrong_source = copy.deepcopy(self.request)
        wrong_source["context"]["source"]["feature"] = "notes"
        invalid_requests.append(wrong_source)
        broken_parts = copy.deepcopy(self.request)
        broken_parts["context"]["items"][0]["label"] = "Original response (possibly truncated)"
        invalid_requests.append(broken_parts)
        oversized_part = copy.deepcopy(self.request)
        oversized_part["context"]["items"][0]["text"] = "é" * (assistant.MAX_ITEM_BYTES // 2 + 1)
        invalid_requests.append(oversized_part)
        action_mode = copy.deepcopy(self.request)
        action_mode["mode"] = "act"
        invalid_requests.append(action_mode)

        for request in invalid_requests:
            with self.subTest(request=request):
                with self.assertRaises(AgentRunError):
                    self.start(request)
                receipts = list((self.manager.runs_root / "requests").glob("*.json")) if (self.manager.runs_root / "requests").exists() else []
                self.assertEqual(receipts, [])
        self.assertEqual(list(self.manager.runs_root.glob("agr_*")), [])

    def test_continuation_is_blocked_in_every_direction_and_promotion_is_forbidden(self):
        brief = self.start()
        wait_for_status(self.manager, brief["id"], {"completed"})
        with self.assertRaises(AgentRunError) as error:
            self.manager.start(
                prompt="Continue generically",
                label="Generic",
                cwd=str(self.root),
                topology={},
                continue_from_run_id=brief["id"],
            )
        self.assertEqual(error.exception.code, "response_brief_continuation_forbidden")
        with self.assertRaises(AgentRunError):
            hud_chats.start(
                self.manager,
                prompt="Continue as HUD",
                label="HUD",
                cwd=str(self.root),
                topology={},
                mode="act",
                continue_from_run_id=brief["id"],
            )

        question = {
            "prompt": "Continue as a question",
            "profile": assistant.PROFILE,
            "clientRequestId": "question-request-0001",
            "continueFromRunId": brief["id"],
            "context": {
                "version": 1,
                "snapshotId": "question-snapshot",
                "capturedAt": "2026-09-17T00:00:00Z",
                "source": {"feature": "notes", "instanceId": "synthetic-note"},
                "items": [],
            },
        }
        with self.assertRaises(AgentRunError):
            assistant.start(
                self.manager,
                request=question,
                cwd=str(self.root),
                pane_id=None,
                workspace_id=None,
            )
        with self.assertRaises(AgentRunError) as error:
            self.manager.promotable(brief["id"])
        self.assertEqual(error.exception.code, "response_brief_promotion_forbidden")

    def test_response_brief_cannot_continue_a_generic_run(self):
        generic = self.manager.start(
            prompt="Synthetic source",
            label="Generic",
            cwd=str(self.root),
            topology={},
        )["run"]
        wait_for_status(self.manager, generic["id"], {"completed"})
        request = copy.deepcopy(self.request)
        request["clientRequestId"] = "brief-request-00000002"
        request["continueFromRunId"] = generic["id"]
        with self.assertRaises(AgentRunError) as error:
            self.start(request)
        self.assertEqual(error.exception.code, "response_brief_continuation_forbidden")

    def test_error_or_aborted_final_message_with_text_fails_the_brief(self):
        cases = (
            ("final-text-error", "provider failed after streaming text"),
            ("final-text-aborted", "model response was aborted"),
        )
        for index, (mode, expected_error) in enumerate(cases, start=1):
            with self.subTest(mode=mode):
                self.manager.environ["FAKE_AGENT_MODE"] = mode
                request = copy.deepcopy(self.request)
                request["clientRequestId"] = f"brief-failure-{index:08d}"
                request["context"]["source"]["instanceId"] = f"failed-response-{index}"
                run = self.start(request)
                failed = wait_for_status(self.manager, run["id"], {"failed"})["run"]
                self.assertEqual(failed["response"], "Partial response brief")
                self.assertEqual(failed["error"], expected_error)

    def test_oversized_provider_output_fails_instead_of_truncating(self):
        self.manager.environ["FAKE_AGENT_RESPONSE"] = "é" * (response_briefs.MAX_OUTPUT_BYTES // 2 + 1)
        run = self.start()
        failed = wait_for_status(self.manager, run["id"], {"failed"})["run"]
        self.assertIsNone(failed["response"])
        self.assertEqual(failed["error"], "Response brief output exceeded 32 KiB.")

    def test_lineage_extension_is_a_separate_bundled_resource(self):
        path = pi_lineage_extension_path({})
        self.assertIsNotNone(path)
        self.assertEqual(path.name, "response-brief-lineage.ts")
        source = path.read_text(encoding="utf-8")
        self.assertIn("registerSessionLineage", source)
        self.assertNotIn("registerTool", source)

    def test_parent_session_id_is_not_accepted_by_contextual_questions(self):
        request = copy.deepcopy(self.request)
        request["profile"] = assistant.PROFILE
        request["context"]["source"]["feature"] = "notes"
        with self.assertRaises(AgentRunError):
            assistant.start(
                self.manager,
                request=request,
                cwd=str(self.root),
                pane_id=None,
                workspace_id=None,
            )


if __name__ == "__main__":
    unittest.main()
