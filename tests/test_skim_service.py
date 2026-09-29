"""The skim hook: selection, idempotency, the Pi profile, storage, and serving.

The model is always the fake Pi binary from test_agent_runs; no test calls a
live model. All replies are synthetic.
"""
from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from herdr_harness import skim
from herdr_harness.agent_runs import SKIM_PROFILE, AgentRunError, AgentRunManager
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.server import api_description
from herdr_harness.skim_service import CAPABILITY, SkimService, SkimSettings, public_run_skim
from tests.test_agent_runs import wait_for_status, write_fake_pi

REPLY = "\n\n".join([
    "Checkout reserves stock before it charges the card, and nothing releases that reservation "
    "when the charge fails, so a declined card keeps the SKU held until the nightly cleanup runs.",
    "- `reserve()` in `cart.js` holds the SKU for fifteen minutes and records the hold in the ledger table",
    "- `charge()` throws on a decline, which skips the release step at the end of `checkout()` entirely",
    "A rollback wrapper around reserve and charge would release the hold whenever the charge throws, "
    "and it keeps the happy path unchanged for every successful order.",
    "```js\ntry {\n  await charge(order);\n} catch (error) {\n  await release(order);\n  throw error;\n}\n```",
    "Want me to add the rollback and a test that declines a card?",
])
OUTPUT = "\n".join([
    "status: answer",
    "say: Checkout [reserves stock first](s1), so a [declined card](s3) keeps the [SKU held](s2) until cleanup.",
    "ask: Want me to [add the rollback and a test](s6) that declines a card?",
])
QUESTION = "Why do declined cards keep stock reserved?"


def wait_until(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("condition was not met in time")


class SkimFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.store = FirstMateStore(self.directory / "first-mate.sqlite3")
        self.addCleanup(self.store.close)
        self.feature = self.store.create_feature({"title": "Checkout holds", "goal": QUESTION,
                                                  "cwd": "/tmp/synthetic-shop", "request_id": "create"})
        self.feature_id = self.feature["id"]
        self.published: list[tuple[str, dict]] = []

    def manager(self, **environment) -> AgentRunManager:
        home = self.directory / "home"
        home.mkdir(exist_ok=True)
        manager = AgentRunManager(
            environ={"HOME": str(home), "HERDR_HARNESS_AGENT_RUNS_ROOT": str(self.directory / "runs"),
                     "HERDR_HARNESS_AGENT_PI_BIN": str(write_fake_pi(self.directory)),
                     "FAKE_AGENT_CAPTURE": str(self.directory / "capture.json"),
                     "FAKE_AGENT_RESPONSE": OUTPUT, **environment},
            herdr_socket_path="/private/tmp/fake-herdr.sock", herdr_session="test-machine",
        )
        self.addCleanup(manager.stop)
        return manager

    def service(self, manager: AgentRunManager, **settings) -> SkimService:
        service = SkimService(SkimSettings(**{"model": "synthetic-provider/fast-model", **settings}),
                              agent_runs=lambda: manager,
                              publish=lambda event, data: self.published.append((event, data)))
        service.attach_store(self.store)
        service.attach_agent_runs(manager)
        self.addCleanup(service.stop)
        return service

    def reply(self, text: str = REPLY, request: str = "reply") -> dict:
        claim = self.store.claim_message(self.feature_id, "coordinator")
        self.store.finish_message(claim["id"], "coordinator", text)
        return next(m for m in reversed(self.store.snapshot(self.feature_id)["messages"]) if m["role"] == "assistant")

    def skim_row(self, message_id: str) -> dict | None:
        return self.store.get_skim(message_id)


class HookSelectionTests(SkimFixture, unittest.TestCase):
    def test_only_long_finished_conversation_replies_get_a_pending_skim(self):
        self.service(self.manager())  # Attaches the policy; workers stay stopped.
        long_reply = self.reply()
        self.store.append_human_message(self.feature_id, "And the short answer?", "follow-up")
        short_reply = self.reply("Yes, that works.")
        self.assertEqual(self.skim_row(long_reply["id"])["status"], "pending")
        self.assertEqual(self.skim_row(long_reply["id"])["attempts"], 0)
        self.assertIsNone(self.skim_row(short_reply["id"]))
        human = next(m for m in self.store.snapshot(self.feature_id)["messages"] if m["role"] == "user")
        self.assertIsNone(self.skim_row(human["id"]))
        key = self.skim_row(long_reply["id"])
        self.assertEqual((key["format"], key["prompt_version"], key["segmenter_version"], key["skim_version"],
                          key["model"], key["thinking"]),
                         ("breath_tight", "skim-v3", 1, 1, "synthetic-provider/fast-model", "low"))

    def test_background_turns_and_disabled_skims_record_nothing(self):
        self.service(self.manager(), enabled=False)
        reply = self.reply()
        self.assertIsNone(self.skim_row(reply["id"]))
        self.assertIsNone(self.store.skim_policy)

    def test_pending_skim_is_idempotent_and_attempts_are_bounded(self):
        self.service(self.manager())
        reply = self.reply()
        key = self.skim_row(reply["id"])
        self.assertFalse(self.store.queue_skim(reply["id"], key))
        self.assertIsNotNone(self.store.begin_skim(reply["id"]))
        self.assertIsNotNone(self.store.begin_skim(reply["id"]))  # Resumed once after a restart.
        self.assertIsNone(self.store.begin_skim(reply["id"]))
        self.assertEqual(self.skim_row(reply["id"])["status"], "failed")
        self.assertEqual(self.skim_row(reply["id"])["error"], "interrupted")

    def test_reply_listeners_run_after_commit_only_for_pending_skims(self):
        seen = []
        self.store.reply_listeners.append(lambda feature_id, message_id: seen.append(
            (feature_id, self.store.get_skim(message_id) is not None)))
        self.service(self.manager())
        self.reply()
        self.store.append_human_message(self.feature_id, "And briefly?", "brief")
        self.reply("Short answer.", request="brief")
        self.assertEqual(seen, [(self.feature_id, True)])


class ProjectionTests(SkimFixture, unittest.TestCase):
    def test_board_and_snapshot_carry_the_skim_and_the_version_moves_when_it_lands(self):
        self.service(self.manager())
        reply = self.reply()
        board = self.store.board(self.feature_id)
        message = next(m for m in board["messages"] if m["id"] == reply["id"])
        self.assertEqual(message["skim"], {"status": "pending", "format": "breath_tight", "prompt_version": "skim-v3",
                                           "segmenter_version": 1, "skim_version": 1})
        pending_version = board["version"]
        self.assertTrue(self.store.board(self.feature_id, if_version=pending_version)["unchanged"])

        document, normalized, _ = skim.skim_from_output(reply=REPLY, output=OUTPUT)
        self.assertIsNotNone(self.store.begin_skim(reply["id"]))
        self.store.finish_skim(reply["id"], "ready", output=OUTPUT, document=normalized,
                               segments=skim.segment_table(document), warnings=normalized["warnings"], duration_ms=12)
        ready = self.store.board(self.feature_id, if_version=pending_version)
        self.assertFalse(ready["unchanged"])
        served = next(m for m in ready["messages"] if m["id"] == reply["id"])["skim"]
        self.assertEqual(served["status"], "ready")
        self.assertEqual(served["document"], json.loads(json.dumps(normalized)))
        self.assertEqual(served["segments"], skim.segment_table(document))
        self.assertTrue(all("text" not in segment for segment in served["segments"]))
        self.assertEqual(len(served["reply_sha256"]), 64)
        self.assertNotIn("output", served)
        snapshot_message = next(m for m in self.store.snapshot(self.feature_id)["messages"] if m["id"] == reply["id"])
        self.assertEqual(snapshot_message["skim"], served)
        # A changed row is served fresh, not from the parsed-document cache.
        with self.store._transaction():
            self.store._db.execute("UPDATE fm_message_skims SET document_json='{\"version\":1,\"changed\":true}',"
                                   "updated_at='2099-01-01T00:00:00Z' WHERE message_id=?", (reply["id"],))
        changed = next(m for m in self.store.board(self.feature_id)["messages"] if m["id"] == reply["id"])["skim"]
        self.assertEqual(changed["document"], {"version": 1, "changed": True})
        self.assertEqual(snapshot_message["text"], REPLY)  # Message text is never changed.

    def test_failed_and_stale_skims_serve_only_their_status(self):
        self.service(self.manager())
        reply = self.reply()
        self.store.begin_skim(reply["id"])
        self.store.finish_skim(reply["id"], "failed", error="timeout")
        served = next(m for m in self.store.board(self.feature_id)["messages"] if m["id"] == reply["id"])["skim"]
        self.assertEqual(served["status"], "failed")
        self.assertNotIn("document", served)

        self.store.append_human_message(self.feature_id, "Another question", "second")
        second = self.reply(request="second")
        with self.store._transaction():
            self.store._db.execute("UPDATE fm_message_skims SET updated_at='2020-01-01T00:00:00Z' WHERE message_id=?",
                                   (second["id"],))
        stale = next(m for m in self.store.board(self.feature_id)["messages"] if m["id"] == second["id"])["skim"]
        self.assertEqual(stale["status"], "failed")

    def test_capability_is_advertised(self):
        self.assertIn(CAPABILITY, api_description()["capabilities"])


class PipelineTests(SkimFixture, unittest.TestCase):
    def test_a_reply_is_skimmed_by_a_tool_free_neutral_run_and_the_copy_is_dropped(self):
        manager = self.manager()
        service = self.service(manager)
        self.store.append_human_message(self.feature_id, QUESTION + "\nAttachment: `/tmp/synthetic/note.txt`", "ask")
        service.start()
        reply = self.reply()
        row = wait_until(lambda: (lambda value: value if value and value["status"] != "pending" else None)(
            self.skim_row(reply["id"])))
        self.assertEqual(row["status"], "ready", row.get("error"))
        self.assertEqual(row["output"], OUTPUT)
        self.assertEqual(row["document"]["format"], "breath_tight")
        self.assertEqual([block["kind"] for block in row["document"]["blocks"]], ["say", "ask"])
        self.assertEqual(row["attempts"], 1)
        self.assertIsNotNone(row["duration_ms"])
        self.assertIn(("first_mate.updated", self.feature_id), [(e, d["feature_id"]) for e, d in self.published])

        capture = json.loads((self.directory / "capture.json").read_text(encoding="utf-8"))
        argv = capture["argv"]
        self.assertIn("--no-tools", argv)
        self.assertNotIn("--tools", argv)
        self.assertNotIn("--extension", argv)
        self.assertEqual(argv[argv.index("--model") + 1], "synthetic-provider/fast-model")
        self.assertEqual(argv[argv.index("--thinking") + 1], "low")
        system = argv[argv.index("--system-prompt") + 1]
        self.assertIn("## Shape: one tight breath", system)
        self.assertNotIn("{{", system)
        self.assertNotIn("herdr-companion-awareness", system)
        self.assertEqual(argv[argv.index("--append-system-prompt") + 1], "")
        self.assertIn("--approve", argv)
        self.assertEqual(capture["herdrAgentRunProfile"], SKIM_PROFILE)
        workspace = Path(capture["cwd"]).resolve()
        self.assertEqual(workspace.parent, Path(tempfile.gettempdir()).resolve())
        self.assertTrue(workspace.name.startswith("herdr-skim-"))
        self.assertFalse(workspace.exists())
        self.assertEqual(capture["effectiveSettings"]["retry"]["enabled"], False)
        self.assertEqual(capture["effectiveSettings"]["compaction"]["enabled"], False)
        # The reply and the human question travel on stdin, never in argv.
        self.assertTrue(capture["prompt"].startswith("QUESTION (what the user asked the agent):\n" + QUESTION + "\n\n"))
        self.assertNotIn("Attachment:", capture["prompt"])
        self.assertIn("[s1 para]\nCheckout reserves stock", capture["prompt"])
        self.assertNotIn("Checkout reserves stock", " ".join(argv))
        # The temporary agent run (and its session copy of the reply) is gone.
        self.assertEqual([path.name for path in (self.directory / "runs").glob("agr_*")], [])

    def test_failures_timeouts_and_runaways_leave_the_full_reply(self):
        for mode, environment, expected in (
            ("failure", {"FAKE_AGENT_MODE": "failure"}, ("failed", "model:")),
            ("timeout", {"FAKE_AGENT_MODE": "hang", "HERDR_HARNESS_AGENT_TIMEOUT_SECONDS": "1"}, ("failed", "timeout")),
            ("runaway", {"FAKE_AGENT_RESPONSE": "status: done\nsay: " + " ".join(["filler"] * 300)}, ("rejected", "ran away")),
            ("no lines", {"FAKE_AGENT_RESPONSE": "   \n  "}, ("failed", "")),
        ):
            with self.subTest(mode=mode):
                self.setUp()
                manager = self.manager(**environment)
                self.service(manager).start()
                reply = self.reply()
                row = wait_until(lambda: (lambda value: value if value and value["status"] != "pending" else None)(
                    self.skim_row(reply["id"])), timeout=20)
                self.assertEqual(row["status"], expected[0])
                self.assertIn(expected[1], row["error"])
                served = next(m for m in self.store.board(self.feature_id)["messages"] if m["id"] == reply["id"])["skim"]
                self.assertNotIn("document", served)

    def test_restart_resumes_an_interrupted_pending_skim_once(self):
        manager = self.manager()
        first = self.service(manager)
        reply = self.reply()
        self.assertIsNotNone(self.store.begin_skim(reply["id"]))  # A run that a restart cut short.
        first.stop()
        second = self.service(manager)
        second._recover()
        second.start()
        row = wait_until(lambda: (lambda value: value if value and value["status"] != "pending" else None)(
            self.skim_row(reply["id"])))
        self.assertEqual(row["status"], "ready")
        self.assertEqual(row["attempts"], 2)

    def test_a_skim_cut_short_by_shutdown_stays_pending_for_one_resume(self):
        manager = self.manager(FAKE_AGENT_MODE="hang")
        service = self.service(manager)
        service.start()
        reply = self.reply()
        wait_until(lambda: self.skim_row(reply["id"])["attempts"] == 1 and manager._processes)
        service.stop()
        manager.stop()  # Cancels the in-flight run, as a companion shutdown does.
        time.sleep(1)
        row = self.skim_row(reply["id"])
        self.assertEqual((row["status"], row["attempts"]), ("pending", 1))

    def test_recovery_never_starts_a_second_inference_for_a_running_skim(self):
        manager = self.manager(FAKE_AGENT_MODE="hang")
        service = self.service(manager)
        service.start()
        reply = self.reply()
        wait_until(lambda: self.skim_row(reply["id"])["attempts"] == 1 and manager._processes)
        service._recover()  # A restart-recovery pass while the job is running.
        service.sweep()
        self.assertEqual(service._queue.qsize(), 0)
        self.assertEqual(self.skim_row(reply["id"])["attempts"], 1)

    def test_an_unexpected_error_settles_the_skim_as_failed(self):
        manager = self.manager()
        service = self.service(manager)

        def broken(*_arguments):
            raise RuntimeError("synthetic failure")

        service._infer = broken
        service.start()
        reply = self.reply()
        row = wait_until(lambda: (lambda value: value if value and value["status"] != "pending" else None)(
            self.skim_row(reply["id"])))
        self.assertEqual((row["status"], row["error"]), ("failed", "internal"))

    def test_a_skim_with_nothing_to_show_is_rejected(self):
        manager = self.manager(FAKE_AGENT_RESPONSE="status: done\nask:")
        self.service(manager).start()
        reply = self.reply()
        row = wait_until(lambda: (lambda value: value if value and value["status"] != "pending" else None)(
            self.skim_row(reply["id"])))
        self.assertEqual(row["status"], "rejected")
        self.assertIn("no sentence or next step", row["error"])

    def test_skim_runs_skip_the_start_time_prune(self):
        manager = self.manager()
        calls = []
        original = manager.prune
        manager.prune = lambda: (calls.append(1), original())[1]
        service = self.service(manager)
        service.start()
        reply = self.reply()
        wait_until(lambda: self.skim_row(reply["id"])["status"] == "ready")
        self.assertEqual(calls, [])

    def test_backfill_queues_recent_unskimmed_replies_once(self):
        reply = self.reply()  # Posted before skims were attached.
        manager = self.manager()
        service = self.service(manager)
        self.assertIsNone(self.skim_row(reply["id"]))
        service.sweep()
        self.assertEqual(self.skim_row(reply["id"])["status"], "pending")
        service.sweep()
        self.assertEqual(service._queue.qsize(), 1)

    def test_backfill_pages_past_replies_too_short_to_skim(self):
        long_reply = self.reply()
        medium = " ".join(["Synthetic medium reply with plenty of characters but few words."] * 3)
        for index in range(45):
            self.store.append_human_message(self.feature_id, f"Question {index}", f"q-{index}")
            self.reply(medium, request=f"r-{index}")
        service = self.service(self.manager())
        service.sweep()
        self.assertEqual(self.skim_row(long_reply["id"])["status"], "pending")

    def test_turning_skims_off_fails_pending_rows(self):
        self.service(self.manager())
        reply = self.reply()
        disabled = SkimService(SkimSettings(enabled=False), agent_runs=lambda: None,
                               publish=lambda event, data: self.published.append((event, data)))
        disabled.attach_store(self.store)
        disabled.start()
        self.assertEqual(self.skim_row(reply["id"])["status"], "failed")
        self.assertIn(("first_mate.updated", self.feature_id), [(e, d["feature_id"]) for e, d in self.published])


class HudChatTests(SkimFixture, unittest.TestCase):
    def start_turn(self, manager: AgentRunManager) -> str:
        from herdr_harness.hud_chats import start
        envelope = start(manager, prompt=QUESTION, label="HUD chat", cwd=str(self.directory / "home"),
                         topology={}, mode="act", _cwd_explicit=True)
        return envelope["run"]["id"]

    def test_a_completed_hud_turn_is_skimmed_and_served_with_the_run(self):
        manager = self.manager(FAKE_AGENT_RESPONSE=REPLY)
        service = self.service(manager)
        # The HUD turn answers with REPLY; the skim run must answer with OUTPUT.
        original_start = manager.start

        def start(**arguments):
            if (arguments.get("_assistant") or {}).get("profile") == SKIM_PROFILE:
                manager.environ["FAKE_AGENT_RESPONSE"] = OUTPUT
            return original_start(**arguments)

        manager.start = start
        service.start()
        run_id = self.start_turn(manager)
        wait_for_status(manager, run_id, {"completed"}, timeout=10)
        served = wait_until(lambda: (lambda value: value if value and value["status"] == "ready" else None)(
            manager.get(run_id)["run"].get("skim")))
        self.assertEqual(served["document"]["format"], "breath_tight")
        self.assertEqual(served["segments"][0]["kind"], "paragraph")
        from herdr_harness.hud_chats import history
        turn = history(manager, run_id)["turns"][0]
        self.assertEqual(turn["skim"]["status"], "ready")
        self.assertEqual(turn["response"], REPLY)
        state = json.loads((manager._run_dir(run_id) / "skim.json").read_text(encoding="utf-8"))
        self.assertEqual(state["output"], OUTPUT)
        self.assertEqual(os.stat(manager._run_dir(run_id) / "skim.json").st_mode & 0o777, 0o600)

    def test_short_hud_turns_have_no_skim(self):
        manager = self.manager(FAKE_AGENT_RESPONSE="Opened it.")
        self.service(manager).start()
        run_id = self.start_turn(manager)
        wait_for_status(manager, run_id, {"completed"}, timeout=10)
        self.assertNotIn("skim", manager.get(run_id)["run"])
        self.assertIsNone(public_run_skim(manager._run_dir(run_id)))

    def test_skim_runs_cannot_be_continued_or_promoted(self):
        manager = self.manager()
        started = manager.start(prompt="QUESTION:\n(not provided)", label="Skim", cwd=str(self.directory / "home"),
                                topology={}, _assistant={"profile": SKIM_PROFILE, "skimSystem": "Rewrite."})
        wait_for_status(manager, started["run"]["id"], {"completed"}, timeout=10)
        with self.assertRaises(AgentRunError) as promotion:
            manager.promotable(started["run"]["id"])
        self.assertEqual(promotion.exception.code, "skim_promotion_forbidden")
        with self.assertRaises(AgentRunError) as continuation:
            manager.start(prompt="More", label="Skim", cwd=str(self.directory / "home"), topology={},
                          continue_from_run_id=started["run"]["id"])
        self.assertEqual(continuation.exception.code, "skim_continuation_forbidden")
        for arguments in ({"mode": "act"}, {"system_prompt": "Override"}, {"_assistant": {"profile": SKIM_PROFILE}}):
            with self.subTest(arguments=arguments):
                with self.assertRaises(AgentRunError) as invalid:
                    manager.start(**{"prompt": "x", "label": "Skim", "cwd": str(self.directory / "home"),
                                     "topology": {}, "_assistant": {"profile": SKIM_PROFILE, "skimSystem": "Rewrite."},
                                     **arguments})
                self.assertEqual(invalid.exception.code, "invalid_skim")


class SettingsTests(unittest.TestCase):
    def test_settings_come_from_the_first_mate_environment(self):
        settings = SkimSettings.from_environ({
            "HERDR_FIRST_MATE_SKIM": "true", "HERDR_FIRST_MATE_SKIM_MODEL": "synthetic-provider/fast-model",
            "HERDR_FIRST_MATE_SKIM_THINKING": "LOW", "HERDR_FIRST_MATE_SKIM_MIN_WORDS": "120",
            "HERDR_FIRST_MATE_SKIM_HUD_CHATS": "false", "HERDR_FIRST_MATE_SKIM_BACKFILL_HOURS": "0",
        })
        self.assertEqual((settings.enabled, settings.model, settings.thinking, settings.min_words,
                          settings.hud_chats, settings.backfill_hours),
                         (True, "synthetic-provider/fast-model", "low", 120, False, 0))
        self.assertTrue(SkimSettings.from_environ({}).enabled)
        self.assertFalse(SkimSettings.from_environ({"HERDR_FIRST_MATE_SKIM": "false"}).enabled)
        self.assertFalse(SkimSettings.from_environ({"HERDR_FIRST_MATE_SKIM_MODEL": "bad model; rm"}).enabled)
        self.assertEqual(SkimSettings.from_environ({"HERDR_FIRST_MATE_SKIM_THINKING": "sideways"}).thinking, "low")

    def test_key_requires_the_minimum_words(self):
        settings = SkimSettings(min_words=5)
        self.assertIsNone(settings.key("Too short here."))
        key = settings.key("One two three four five six.\r\n")
        self.assertEqual(key["reply_sha256"], __import__("hashlib").sha256(b"One two three four five six.\n").hexdigest())


if __name__ == "__main__":
    unittest.main()
