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

    @staticmethod
    def captured_charter(capture):
        return capture["argv"][capture["argv"].index("--append-system-prompt") + 1]

    @staticmethod
    def stored_run(manager, run_id):
        return json.loads((manager.runs_root / run_id / "run.json").read_text(encoding="utf-8"))

    def test_capability_advertises_profile_bounds_and_length_policy(self):
        capabilities = assistant.capabilities()
        self.assertIn(response_briefs.PROFILE, capabilities["profiles"])
        self.assertEqual(
            capabilities["responseBriefs"],
            {
                "version": 1,
                "lengthPolicyVersion": 2,
                "lengthOptions": ["minimal", "medium", "long"],
                "tools": "none",
                "oneShot": True,
                "maxOutputBytes": response_briefs.MAX_OUTPUT_BYTES,
                "requiresParentSessionId": True,
            },
        )
        self.assertEqual(response_briefs.LENGTH_POLICY_VERSION, 2)
        self.assertEqual(
            tuple(capabilities["responseBriefs"]["lengthOptions"]),
            response_briefs.LENGTH_OPTIONS,
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
        self.assertIn("splitting only on LF", charter)
        self.assertIn("points must contain zero or one object", charter)
        self.assertIn("details must contain zero to two objects", charter)
        self.assertIn("Never turn a table, list, code block, or status inventory into prose", charter)
        self.assertIn("Do not repeat or repackage the summary", charter)
        self.assertIn("at most 40 words", charter)
        self.assertIn("at most 9 non-whitespace Unicode scalars", charter)
        self.assertEqual(argv[argv.index("--name") + 1], "Response brief")

    def test_python_length_policy_matches_shared_swift_fixture_corpus(self):
        fixture_path = Path(__file__).parent / "fixtures" / "response_brief_lengths.json"
        fixtures = json.loads(fixture_path.read_text(encoding="utf-8"))

        self.assertEqual(
            {fixture["length"] for fixture in fixtures},
            set(response_briefs.LENGTH_OPTIONS),
        )
        for fixture in fixtures:
            with self.subTest(name=fixture["name"]):
                self.assertEqual(
                    response_briefs.length_policy(fixture["source"], fixture["length"]),
                    {
                        "length": fixture["length"],
                        "readableCharacters": fixture["readableCharacters"],
                        "sourceWords": fixture["sourceWords"],
                        "maximumVisibleCharacters": fixture["maximumVisibleCharacters"],
                        "maximumVisibleWords": fixture["maximumVisibleWords"],
                    },
                )

    def test_explicit_length_scales_character_and_word_ceilings(self):
        source = "a" * 200
        self.assertEqual(response_briefs.length_policy(source, "minimal")["maximumVisibleCharacters"], 50)
        self.assertEqual(response_briefs.length_policy(source, "medium")["maximumVisibleCharacters"], 100)
        self.assertEqual(response_briefs.length_policy(source, "long")["maximumVisibleCharacters"], 150)

        many_words = " ".join(["ab"] * 200)
        self.assertEqual(
            [
                response_briefs.length_policy(many_words, length)["maximumVisibleWords"]
                for length in response_briefs.LENGTH_OPTIONS
            ],
            [40, 80, 120],
        )
        self.assertEqual(
            [
                response_briefs.length_policy(" ".join(["ab"] * 40), length)["maximumVisibleWords"]
                for length in response_briefs.LENGTH_OPTIONS
            ],
            [10, 20, 30],
        )

    def test_explicit_minimal_preserves_legacy_ceilings_for_previously_eligible_sources(self):
        for source in ("a" * 161, "ab " * 200, "\u754c" * 500):
            with self.subTest(characters=len(source)):
                legacy = response_briefs.concision_policy(source)
                minimal = response_briefs.length_policy(source, "minimal")
                self.assertTrue(legacy["shouldGenerate"])
                self.assertEqual(
                    minimal["maximumVisibleCharacters"],
                    legacy["maximumVisibleCharacters"],
                )
                self.assertEqual(minimal["maximumVisibleWords"], legacy["maximumVisibleWords"])

    def test_explicit_length_gives_newly_eligible_short_sources_a_usable_ceiling(self):
        for source in ("a", "\U0001FABB" * 3, "a" * 160, "b" * 161):
            with self.subTest(characters=len(source)):
                for length, expected in (("minimal", 40), ("medium", 80), ("long", 120)):
                    with self.subTest(length=length):
                        policy = response_briefs.length_policy(source, length)
                        self.assertEqual(policy["maximumVisibleCharacters"], expected)
                        self.assertEqual(policy["maximumVisibleWords"], expected)
        legacy = response_briefs.concision_policy("a")
        self.assertEqual(legacy["maximumVisibleCharacters"], 0)
        self.assertEqual(legacy["maximumVisibleWords"], 40)

    def test_length_policy_rounds_quarters_and_keeps_absolute_caps(self):
        self.assertEqual(response_briefs.length_policy("c" * 163, "minimal")["maximumVisibleCharacters"], 40)
        self.assertEqual(response_briefs.length_policy("d" * 164, "medium")["maximumVisibleCharacters"], 82)
        self.assertEqual(response_briefs.length_policy("e" * 165, "long")["maximumVisibleCharacters"], 123)
        self.assertEqual(response_briefs.length_policy("z" * 10_000, "minimal")["maximumVisibleCharacters"], 240)
        self.assertEqual(response_briefs.length_policy("z" * 10_000, "medium")["maximumVisibleCharacters"], 480)
        self.assertEqual(response_briefs.length_policy("z" * 10_000, "long")["maximumVisibleCharacters"], 720)
        self.assertEqual(
            response_briefs.length_policy(" ".join(["ab"] * 10_000), "long")["maximumVisibleWords"],
            120,
        )

    def test_unknown_length_option_is_rejected(self):
        with self.assertRaises(AgentRunError) as error:
            response_briefs.length_policy("a" * 200, "compact")
        self.assertEqual(error.exception.code, "invalid_response_brief_length")
        with self.assertRaises(AgentRunError) as error:
            response_briefs.requested_length({"responseBriefLength": "compact"})
        self.assertEqual(error.exception.code, "invalid_response_brief_length")
        self.assertIsNone(response_briefs.requested_length({}))
        self.assertEqual(response_briefs.requested_length({"responseBriefLength": "medium"}), "medium")

    def test_explicit_length_charter_uses_required_source_only_and_allows_short_summaries(self):
        context = copy.deepcopy(self.request["context"])
        context["items"][0]["text"] = "a" * 4_000
        context["items"].append({
            "id": "optional-noise",
            "kind": "text.v1",
            "label": "Optional context",
            "priority": "optional",
            "text": "hidden " * 10_000,
        })

        charter = response_briefs.charter_for(context, "long")

        self.assertIn("The selected length option is long.", charter)
        self.assertIn("the source has 1 readable words", charter)
        self.assertIn("4000 readable letter/number scalars", charter)
        self.assertIn("at most 120 words", charter)
        self.assertIn("at most 720 non-whitespace Unicode scalars", charter)
        self.assertNotIn("hidden", charter)
        self.assertNotIn("12 to 20", charter)
        self.assertIn("no minimum", charter)
        self.assertIn(response_briefs.OUTPUT_SCHEMA, charter)

    def test_visible_output_policy_counts_total_punctuation_emoji_and_word_boundaries(self):
        source = "a" * 200

        self.assertTrue(response_briefs.visible_content_fits(source, ["b" * 50]))
        self.assertFalse(response_briefs.visible_content_fits(source, ["b" * 51]))
        self.assertEqual(response_briefs.word_count("--- 🪻 e\u0301 東京"), 2)
        self.assertEqual(response_briefs.non_whitespace_scalar_count("--- 🪻 e\u0301 東京"), 8)

    def test_absolute_word_cap_rejects_41_tiny_words_that_fit_character_budget(self):
        source = " ".join(["source"] * 200)
        policy = response_briefs.concision_policy(source)
        rejected = " ".join(["a"] * 41)

        self.assertEqual(policy["maximumVisibleWords"], 40)
        self.assertLess(response_briefs.non_whitespace_scalar_count(rejected), policy["maximumVisibleCharacters"])
        self.assertTrue(response_briefs.visible_content_fits(source, [" ".join(["a"] * 40)]))
        self.assertFalse(response_briefs.visible_content_fits(source, [rejected]))

    def test_trusted_budgets_use_required_source_only(self):
        context = copy.deepcopy(self.request["context"])
        context["items"].append({
            "id": "optional-noise",
            "kind": "text.v1",
            "label": "Optional context",
            "priority": "optional",
            "text": "hidden " * 1_000,
        })

        charter = response_briefs.charter_for(context)

        self.assertIn("the source has 7 readable words", charter)
        self.assertIn("37 readable letter/number scalars", charter)
        self.assertNotIn("1000", charter)

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

    def test_visible_content_fits_applies_the_selected_length_preset(self):
        source = "a" * 200

        self.assertTrue(response_briefs.visible_content_fits(source, ["b" * 50], "minimal"))
        self.assertFalse(response_briefs.visible_content_fits(source, ["b" * 51], "minimal"))
        self.assertTrue(response_briefs.visible_content_fits(source, ["b" * 100], "medium"))
        self.assertFalse(response_briefs.visible_content_fits(source, ["b" * 101], "medium"))
        self.assertTrue(response_briefs.visible_content_fits(source, ["b" * 150], "long"))
        self.assertFalse(response_briefs.visible_content_fits(source, ["b" * 151], "long"))
        self.assertFalse(response_briefs.visible_content_fits("a", ["b"]))
        self.assertTrue(response_briefs.visible_content_fits("a", ["b"], "minimal"))

    def test_omitted_length_keeps_legacy_budgets_and_unpinned_run_metadata(self):
        run = self.start()
        wait_for_status(self.manager, run["id"], {"completed"})
        self.assertNotIn("responseBriefLength", self.stored_run(self.manager, run["id"]))
        charter = self.captured_charter(json.loads(self.capture.read_text(encoding="utf-8")))
        self.assertIn("at most 40 words", charter)
        self.assertIn("at most 9 non-whitespace Unicode scalars", charter)
        self.assertNotIn("The selected length option is", charter)

    def test_explicit_length_is_persisted_and_drives_the_captured_charter(self):
        request = copy.deepcopy(self.request)
        request["context"]["items"][0]["text"] = "a" * 200
        request["responseBriefLength"] = "long"

        run = self.start(request)
        wait_for_status(self.manager, run["id"], {"completed"})

        self.assertEqual(self.stored_run(self.manager, run["id"])["responseBriefLength"], "long")
        charter = self.captured_charter(json.loads(self.capture.read_text(encoding="utf-8")))
        self.assertIn("The selected length option is long.", charter)
        self.assertIn("the source has 1 readable words", charter)
        self.assertIn("200 readable letter/number scalars", charter)
        self.assertIn("at most 120 words", charter)
        self.assertIn("at most 150 non-whitespace Unicode scalars", charter)

    def test_same_request_is_idempotent_and_changed_payload_conflicts(self):
        first = self.start()
        second = self.start()
        self.assertEqual(first["id"], second["id"])
        changed = copy.deepcopy(self.request)
        changed["prompt"] = "A different request."
        with self.assertRaises(AgentRunError) as error:
            self.start(changed)
        self.assertEqual(error.exception.code, "assistant_request_conflict")

    def test_same_request_id_with_a_changed_length_conflicts(self):
        request = copy.deepcopy(self.request)
        request["responseBriefLength"] = "minimal"
        first = self.start(request)
        repeated = self.start(copy.deepcopy(request))
        self.assertEqual(first["id"], repeated["id"])

        for changed in ("medium", "long", None):
            with self.subTest(changed=changed):
                conflicting = copy.deepcopy(self.request)
                if changed is not None:
                    conflicting["responseBriefLength"] = changed
                with self.assertRaises(AgentRunError) as error:
                    self.start(conflicting)
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
        for length in (None, "", "Minimal", "MEDIUM", "short", "longer", 2, ["minimal"], {"length": "long"}):
            bad_length = copy.deepcopy(self.request)
            bad_length["responseBriefLength"] = length
            invalid_requests.append(bad_length)

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
