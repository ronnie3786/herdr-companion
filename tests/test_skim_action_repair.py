"""Synthetic coverage for bounded option repair; no tests call a live model."""
import concurrent.futures
import copy
import json
import threading
import unittest
from unittest.mock import patch

from herdr_harness import skim
from herdr_harness.agent_runs import AgentRunError, SKIM_PROFILE
from herdr_harness.skim_service import SkimService, SkimSettings


OFFER = "I can add the rollback and a regression test if you want."
OTHER_OFFER = "Want me to explain the cleanup instead?"
REPLY = "The declined charge leaves the reservation held.\n\n" + OFFER + "\n\n" + OTHER_OFFER
SUMMARY = ("status: answer\nsay: [The declined charge](s1) leaves the reservation held.\n"
           "heads_up: The reservation remains held until cleanup.\n"
           "ask: I can [add the rollback and a regression test](s2) if you want.\n")
GOOD_ACTION = "action: Add the rollback | Ask the agent to add the rollback and a regression test. | s2"
BAD_ACTION = "action: Add the rollback | Ask the agent to add the rollback and a regression test. | s1"
REPAIR = "ask: " + OFFER + "\n" + GOOD_ACTION


class ScriptedManager:
    """Exercise the real service orchestration without subprocesses or network."""
    def __init__(self, *outputs):
        self.outputs = list(outputs)
        self.calls = []
        self.runs = {}
        self.deleted = []
        self.cancelled = []
        self._lock = threading.RLock()
        self._threads = {}
        self.on_start = None

    def start(self, **arguments):
        self.calls.append(arguments)
        output = self.outputs.pop(0)
        if isinstance(output, Exception):
            raise output
        run_id = f"synthetic-{len(self.calls)}"
        self.runs[run_id] = ({"id": run_id, "status": "completed", "response": output}
                             if isinstance(output, str) else {"id": run_id, **output})
        if self.on_start:
            self.on_start(len(self.calls))
        return {"run": {"id": run_id}}

    def _read(self, run_id):
        return self.runs[run_id]

    def cancel(self, run_id):
        self.cancelled.append(run_id)
        self.runs[run_id]["status"] = "cancelled"

    def delete(self, run_id):
        self.deleted.append(run_id)
        del self.runs[run_id]


class ActionRepairValidationTests(unittest.TestCase):
    def normalized(self, action=BAD_ACTION, *, output=None, reply=REPLY):
        return skim.skim_from_output(reply=reply, output=output if output is not None else SUMMARY + action)

    def test_rejection_diagnostics_are_fixed_and_actions_are_a_known_key(self):
        cases = (
            ("action: Add the rollback", "action_shape"),
            ("action: Add the rollback and regression test | Add it. | s2", "action_label"),
            ("action: `Rollback` | Add it. | s2", "action_label"),
            ("action: Rollback | | s2", "action_explanation"),
            ("action: Rollback | " + "x" * 241 + " | s2", "action_explanation"),
            (BAD_ACTION, "action_refs"),
            (GOOD_ACTION.replace("s2", "s1-s2"), "action_refs"),
            (GOOD_ACTION.replace("s2", "s99"), "action_refs"),
        )
        for action, code in cases:
            with self.subTest(code=code, action=action):
                source, result, _ = self.normalized(action)
                self.assertFalse(result.get("actions"))
                self.assertIn(code, [w["code"] for w in result["warnings"]])
                self.assertNotIn("unknown_keys", [w["code"] for w in result["warnings"]])
                self.assertEqual(skim.action_repair_asks(result, source), [{"text": OFFER, "refs": ["s2"]}])
                self.assertNotIn(OFFER, json.dumps(result["warnings"]))
                self.assertNotIn("rollback", json.dumps(result["warnings"]))

    def test_omitted_empty_and_partly_valid_actions_do_not_request_repair(self):
        for action in ("", GOOD_ACTION, BAD_ACTION + "\n" + GOOD_ACTION):
            source, result, _ = self.normalized(action)
            self.assertEqual(skim.action_repair_asks(result, source), [])
        parsed, _, _ = skim.read_model_output(SUMMARY)
        for empty in ([], None, "", {}):
            with self.subTest(empty=empty):
                parsed["actions"] = empty
                source = skim.segment(REPLY)
                result = skim.normalize(parsed, source)
                self.assertEqual(skim.action_repair_asks(result, source), [])

    def test_unsupported_or_quoted_ask_never_requests_repair(self):
        for reply in ("The rollback is complete.", "> " + OFFER, "```text\n" + OFFER + "\n```"):
            source, result, _ = self.normalized(reply=reply)
            self.assertEqual(skim.action_repair_asks(result, source), [])

    def test_repair_accepts_only_the_original_ask_and_its_source_blocks(self):
        source, original, _ = self.normalized()
        unchanged = copy.deepcopy(original)
        self.assertEqual([a["label"] for a in skim.repaired_actions(REPAIR, source, original)], ["Add the rollback"])
        invalid = (
            "ask: " + OTHER_OFFER + "\n" + GOOD_ACTION.replace("s2", "s3"),
            REPAIR.replace("| s2", "| s3"),
            REPAIR.replace("| s2", "| s1-s2"),
            REPAIR.replace(OFFER, "I can add the rollback and deploy it if you want."),
            REPAIR + "\nsay: The work is already done.",
            "headline: A changed summary\n" + REPAIR,
            REPAIR + "\nask: " + OTHER_OFFER,
            "action: Add the rollback | Ask the agent to add it. | s2",
        )
        for output in invalid:
            with self.subTest(output=output):
                try:
                    actions = skim.repaired_actions(output, source, original)
                except skim.SkimRejected:
                    actions = []
                self.assertEqual(actions, [])
        self.assertEqual(original, unchanged)

    def test_options_for_a_different_ask_cannot_survive_among_matching_options(self):
        source, original, _ = self.normalized()
        repair = "ask: " + OFFER + "\n" + GOOD_ACTION.replace("| s2", "| s3") + "\n"
        repair += "action: Add a regression test | Ask the agent to add the offered test. | s2"
        self.assertEqual(skim.repaired_actions(repair, source, original), [{
            "id": "r1", "label": "Add a regression test", "explanation": "Ask the agent to add the offered test.",
            "refs": ["s2"]}])

    def test_v5_prompt_is_stable_and_v6_has_plain_labels_and_declarative_example(self):
        previous = skim.prompt_for(None, REPLY, version="skim-v5")
        current = skim.prompt_for(None, REPLY)
        self.assertNotIn("Count label words", previous.system)
        self.assertIn("Count label words", current.system)
        self.assertIn("## Example with a declarative offer", current.system)
        self.assertIn("Never invent follow-up work", current.system)


class ActionRepairPipelineTests(unittest.TestCase):
    def service(self, *outputs):
        manager = ScriptedManager(*outputs)
        service = SkimService(SkimSettings(min_words=1), agent_runs=lambda: manager)
        self.addCleanup(service._chats._db.close)
        return service, manager

    def infer(self, service, version=skim.PROMPT_VERSION):
        key = service.settings.key(REPLY)
        key["prompt_version"] = version
        return service._infer("Why is the reservation held?", REPLY, key)

    def test_one_fresh_repair_adds_only_actions_and_cleans_up_both_runs(self):
        first = SUMMARY + BAD_ACTION
        service, manager = self.service(first, REPAIR)
        result = self.infer(service)
        original = skim.skim_from_output(reply=REPLY, output=first)[1]
        self.assertEqual(result["status"], "ready")
        self.assertEqual([a["label"] for a in result["document"]["actions"]], ["Add the rollback"])
        self.assertEqual({k: v for k, v in result["document"].items() if k != "actions"},
                         {k: v for k, v in original.items() if k != "actions"})
        self.assertEqual(result["output"], first)
        self.assertEqual(len(manager.calls), 2)
        self.assertEqual(manager.deleted, ["synthetic-1", "synthetic-2"])
        self.assertFalse(manager.runs)
        for call in manager.calls:
            self.assertEqual(call["_assistant"]["profile"], SKIM_PROFILE)
            self.assertEqual(call["mode"], "ask")
            self.assertNotIn("continue_from_run_id", call)
            self.assertEqual(call["topology"], {})
        self.assertIn("RETAINED ASKS", manager.calls[1]["prompt"])
        self.assertNotIn(BAD_ACTION, manager.calls[1]["prompt"])

    def test_no_repair_for_omitted_empty_mixed_valid_or_old_version(self):
        parsed, _, _ = skim.read_model_output(SUMMARY)
        parsed["actions"] = []
        cases = ((SUMMARY, skim.PROMPT_VERSION),
                 (json.dumps(parsed), skim.PROMPT_VERSION),
                 (SUMMARY + GOOD_ACTION, skim.PROMPT_VERSION),
                 (SUMMARY + BAD_ACTION + "\n" + GOOD_ACTION, skim.PROMPT_VERSION),
                 (SUMMARY + BAD_ACTION, "skim-v5"))
        for first, version in cases:
            with self.subTest(first=first, version=version):
                service, manager = self.service(first)
                self.assertEqual(self.infer(service, version)["status"], "ready")
                self.assertEqual(len(manager.calls), 1)

    def test_failed_invalid_and_still_empty_repair_preserve_ready_original(self):
        first = SUMMARY + BAD_ACTION
        expected = skim.skim_from_output(reply=REPLY, output=first)[1]
        repairs = (
            {"status": "failed", "error": "synthetic failure"},
            {"status": "cancelled"},
            AgentRunError("synthetic start failure", code="unavailable", status=503),
            RuntimeError("synthetic unexpected failure"),
            "ask: " + OFFER,
            "ask: " + OFFER + "\n" + BAD_ACTION,
            "not a useful repair",
            "status: done\nsay: " + "filler " * 400,
        )
        for repair in repairs:
            with self.subTest(repair=repair):
                service, manager = self.service(first, repair)
                result = self.infer(service)
                self.assertEqual(result["status"], "ready")
                self.assertEqual(result["document"], expected)
                self.assertEqual(len(manager.calls), 2)
                self.assertFalse(manager.runs)

    def test_shutdown_after_first_success_does_not_start_a_repair(self):
        service, manager = self.service(SUMMARY + BAD_ACTION)
        manager.on_start = lambda _: service._stop.set()
        result = self.infer(service)
        self.assertEqual(result["status"], "ready")
        self.assertEqual(len(manager.calls), 1)
        self.assertFalse(manager.runs)

    def test_shutdown_during_repair_preserves_first_success(self):
        service, manager = self.service(SUMMARY + BAD_ACTION, {"status": "running"})
        manager.on_start = lambda count: service._stop.set() if count == 2 else None
        result = self.infer(service)
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["document"]["actions"], [])
        self.assertEqual(len(manager.calls), 2)
        self.assertIn("synthetic-2", manager.cancelled)
        self.assertFalse(manager.runs)

    def test_both_calls_share_one_deadline_and_timeout_preserves_success(self):
        service, manager = self.service(SUMMARY + BAD_ACTION, {"status": "running"})
        deadlines = []
        original_wait = service._wait
        def wait(*args, **kwargs):
            deadlines.append(kwargs["deadline"])
            return original_wait(*args, **kwargs)
        service._wait = wait
        clock = [100.0]
        def advance_on_repair(count):
            if count == 2:
                clock[0] = 101.0
        manager.on_start = advance_on_repair
        with patch("herdr_harness.skim_service.INFERENCE_DEADLINE_SECONDS", 0.03), \
                patch("herdr_harness.skim_service.time.monotonic", side_effect=lambda: clock[0]):
            result = self.infer(service)
        self.assertEqual(result["status"], "ready")
        self.assertEqual(deadlines[0], deadlines[1])
        self.assertEqual(len(manager.calls), 2)
        self.assertIn("synthetic-2", manager.cancelled)
        self.assertFalse(manager.runs)

    def test_repair_that_exceeds_input_bound_is_skipped(self):
        service, manager = self.service(SUMMARY + BAD_ACTION)
        prompt = skim.prompt_for("Why is the reservation held?", REPLY)
        with patch("herdr_harness.skim_service.MAX_USER_MESSAGE_CHARS", len(prompt.user)):
            self.assertEqual(self.infer(service)["status"], "ready")
        self.assertEqual(len(manager.calls), 1)

    def test_concurrent_requests_and_recovery_share_the_inflight_repair(self):
        service, manager = self.service(SUMMARY + BAD_ACTION, REPAIR)
        repair_started = threading.Event()
        release_repair = threading.Event()
        finished = threading.Event()
        self.addCleanup(service.stop)
        self.addCleanup(release_repair.set)
        def hold_repair(count):
            if count == 2:
                repair_started.set()
                release_repair.wait(timeout=10)
        manager.on_start = hold_repair
        original_finish = service._chats.finish
        def finish(*args, **kwargs):
            original_finish(*args, **kwargs)
            finished.set()
        service._chats.finish = finish

        initial = service.request_chat(reply=REPLY)
        self.assertTrue(repair_started.wait(timeout=10))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            requests = list(pool.map(lambda _: service.request_chat(reply=REPLY), range(8)))
        service._recover()
        service.sweep()
        self.assertEqual({request["id"] for request in requests}, {initial["id"]})
        self.assertTrue(all(request["skim"]["status"] == "pending" for request in requests))
        self.assertEqual(len(manager.calls), 2)
        self.assertEqual(service._chats.get(initial["id"])["attempts"], 1)
        self.assertEqual(service._queue.qsize(), 0)

        release_repair.set()
        self.assertTrue(finished.wait(timeout=10))
        settled = service.request_chat(reply=REPLY)
        self.assertEqual(settled["skim"]["status"], "ready")
        self.assertEqual([action["label"] for action in settled["skim"]["document"]["actions"]],
                         ["Add the rollback"])
        self.assertEqual(len(manager.calls), 2)
        self.assertEqual(manager.deleted, ["synthetic-1", "synthetic-2"])

    def test_repeated_invalid_repair_is_cached_without_another_attempt(self):
        service, manager = self.service(SUMMARY + BAD_ACTION, "ask: " + OFFER + "\n" + BAD_ACTION)
        service.start = lambda: None
        initial = service.request_chat(reply=REPLY)
        service._skim_chat(initial["id"])
        settled = service.request_chat(reply=REPLY)
        self.assertEqual(settled["skim"]["status"], "ready")
        self.assertEqual(settled["skim"]["document"]["actions"], [])
        service._skim_chat(initial["id"])
        self.assertEqual(len(manager.calls), 2)
        self.assertEqual(service._chats.get(initial["id"])["attempts"], 1)
        self.assertEqual(service._chats.pending(), [])
        state = service._chats.get(initial["id"])
        self.assertNotIn("output", state)
        self.assertIsNone(service._chats._db.execute("SELECT source FROM chat_skims").fetchone()[0])
