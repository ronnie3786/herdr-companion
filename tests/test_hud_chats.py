import json
import tempfile
import unittest
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

from herdr_harness import hud_chats, assistant
from herdr_harness.agent_runs import AgentRunManager, AgentRunError
from tests.test_agent_runs import write_fake_pi, wait_for_status


class HudChatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.capture = self.root / "capture.json"
        self.environment = {"HERDR_HARNESS_AGENT_PI_BIN": str(write_fake_pi(self.root)),
                            "FAKE_AGENT_CAPTURE": str(self.capture)}
        self.manager = self.make_manager()

    def make_manager(self):
        return AgentRunManager(environ=self.environment, runs_root=self.root / "runs",
                               herdr_socket_path="/tmp/example.sock", herdr_session="example")

    def tearDown(self):
        self.manager.stop()
        self.temp.cleanup()

    def start(self, parent=None, prompt="Plan a herb garden"):
        return hud_chats.start(self.manager, prompt=prompt, label=prompt, cwd=str(self.root),
                               topology={}, mode="act", continue_from_run_id=parent)["run"]

    def complete(self, run):
        return wait_for_status(self.manager, run["id"], {"completed"})["run"]

    def test_full_pi_access_without_overriding_project_trust(self):
        run = self.complete(self.start())
        argv = json.loads(self.capture.read_text())["argv"]
        for flag in ("--tools", "--no-tools", "--no-skills", "--no-extensions", "--no-context-files",
                     "--no-prompt-templates", "--no-approve", "--approve"):
            self.assertNotIn(flag, argv)
        self.assertEqual(run["profile"], hud_chats.PROFILE)
        self.assertIn(hud_chats.PROFILE, assistant.capabilities()["profiles"])
        self.assertTrue(Path(run["sessionFile"]).is_file())

    def test_history_search_and_indefinite_retention_survive_restart(self):
        root = self.complete(self.start())
        reply = self.complete(self.start(root["id"], "Use terracotta pots"))
        self.assertEqual(root["sessionId"], reply["sessionId"])
        for run in (root, reply):
            self.manager._set(run["id"], finishedAt="2000-01-01T00:00:00Z")
        self.manager.prune()
        self.manager.stop()
        self.manager = self.make_manager()
        self.assertEqual(hud_chats.catalog(self.manager, "TERRACOTTA")["chats"][0]["id"], root["id"])
        self.assertEqual(len(hud_chats.catalog(self.manager, "not present")["chats"]), 0)
        turns = hud_chats.history(self.manager, root["id"])["turns"]
        self.assertEqual([r["id"] for r in turns], [root["id"], reply["id"]])
        self.assertTrue(Path(root["sessionFile"]).is_file())
        self.assertIsNotNone(self.complete(self.start(reply["id"]))["response"])

    def test_no_silent_fork_stale_append_or_profile_downgrade(self):
        root = self.complete(self.start())
        reply = self.complete(self.start(root["id"]))
        for parent in (root["id"], "agr_000000000000"):
            with self.assertRaises(AgentRunError):
                self.start(parent)
        with self.assertRaises(AgentRunError):
            self.manager.start(prompt="Hi", label="Hi", cwd=str(self.root), topology={}, continue_from_run_id=reply["id"])
        Path(reply["sessionFile"]).unlink()
        with self.assertRaises(AgentRunError):
            self.start(reply["id"])
        self.assertEqual(len(hud_chats.history(self.manager, root["id"])["turns"]), 2)

    def test_concurrent_appends_and_promotion_are_exclusive(self):
        root = self.complete(self.start())
        self.manager.environ["FAKE_AGENT_MODE"] = "hang"
        def attempt(_):
            try:
                return self.start(root["id"])
            except AgentRunError:
                return None
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, range(2)))
        accepted = [r for r in results if r]
        self.assertEqual(len(accepted), 1)
        with self.assertRaises(AgentRunError):
            self.manager.promotable(root["id"])
        with self.assertRaises(AgentRunError):
            self.manager.delete(root["id"])
        self.manager.cancel(accepted[0]["id"])

    def test_promotion_from_any_turn_hands_off_whole_session_once(self):
        root = self.complete(self.start())
        reply = self.complete(self.start(root["id"]))
        reserved, path = self.manager.promotable(root["id"])
        self.assertEqual(path, reply["sessionFile"])
        with self.assertRaises(AgentRunError):
            self.start(reply["id"])
        self.manager.mark_promoted(reserved["id"], workspace_id="example-workspace", pane_id="example-pane")
        already, second_path = self.manager.promotable(reply["id"])
        self.assertEqual(already["id"], root["id"])
        self.assertEqual(path, second_path)
        self.assertEqual(hud_chats.catalog(self.manager)["chats"][0]["promotedPaneId"], "example-pane")
        with self.assertRaises(AgentRunError):
            self.manager.delete(reply["id"])
        self.assertEqual(len(hud_chats.history(self.manager, root["id"])["turns"]), 2)

    def test_legacy_save_is_explicit_and_question_profiles_stay_restricted(self):
        legacy = self.manager.start(prompt="Save my idea", label="Idea", cwd=str(self.root), topology={}, mode="act")["run"]
        self.complete(legacy)
        self.assertEqual(hud_chats.catalog(self.manager)["chats"], [])
        hud_chats.retain_legacy(self.manager, legacy["id"])
        self.assertEqual(len(hud_chats.catalog(self.manager)["chats"]), 1)
        self.complete(self.start(legacy["id"]))
        question = self.manager.start(prompt="Question", label="Question", cwd=str(self.root), topology={})["run"]
        self.complete(question)
        with self.assertRaises(AgentRunError):
            hud_chats.retain_legacy(self.manager, question["id"])

    def test_catalog_and_turns_paginate_and_explicit_delete_removes_whole_thread(self):
        root = self.complete(self.start())
        original = self.manager._read(root["id"])
        for index in range(1, 52):
            run = dict(original, id=f"agr_{index:012x}", hudSequence=index, prompt=f"Turn {index}")
            self.manager._write(run)
        page = hud_chats.history(self.manager, root["id"])
        self.assertEqual(len(page["turns"]), 50)
        self.assertEqual(page["nextOffset"], 50)
        self.assertEqual(len(hud_chats.history(self.manager, root["id"], 50)["turns"]), 2)
        self.manager.delete("agr_000000000001")
        self.assertEqual(hud_chats.catalog(self.manager)["chats"], [])
        self.assertFalse(Path(root["sessionFile"]).exists())

    def test_upgrade_preserves_still_present_legacy_action_threads_before_pruning(self):
        legacy = self.manager.start(prompt="Keep this idea", label="Idea", cwd=str(self.root), topology={}, mode="act")["run"]
        self.complete(legacy)
        self.manager._set(legacy["id"], finishedAt="2000-01-01T00:00:00Z")
        self.manager.stop()
        self.manager = self.make_manager()
        self.assertEqual(hud_chats.catalog(self.manager, "idea")["chats"][0]["id"], legacy["id"])
        self.assertEqual(self.manager.get(legacy["id"])["run"]["profile"], hud_chats.PROFILE)
        self.complete(self.start(legacy["id"]))

    def test_old_non_hud_runs_still_expire(self):
        run = self.manager.start(prompt="Question", label="Question", cwd=str(self.root), topology={})["run"]
        self.complete(run)
        self.manager._set(run["id"], finishedAt="2000-01-01T00:00:00Z")
        self.manager.prune()
        with self.assertRaises(AgentRunError):
            self.manager.get(run["id"])
