"""What reaches the human's First Mate chat, and what stays in the journal."""
from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from herdr_harness.first_mate_store import (SCHEMA, FirstMateError, FirstMateStore, _now,
                                            system_message_attention)


class QuietChatStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = FirstMateStore(Path(self.temp.name) / "first-mate.sqlite3")
        self.addCleanup(lambda: self.store.close())
        self.feature = self.store.create_feature({"title": "Garden schedule", "goal": "Plan a garden watering feature",
                                                  "cwd": "/tmp/synthetic-garden", "request_id": "feature-create"})
        self.fid = self.feature["id"]

    def stage(self):
        message = self.store.claim_message(self.fid, "coordinator")
        visit = self.store.start_visit(self.fid, "plan", "Planning", "visit-1", 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Planning is running.")
        return visit

    def running(self, visit, suffix):
        assignment = self.store.create_assignment(visit["id"], {"title": "Lane " + suffix, "role": "reviewer",
                                                                "prompt": "Review the synthetic design.",
                                                                "request_id": "assignment-" + suffix})
        claimed = self.store.claim_assignment(assignment["id"], "worker-" + suffix)
        return self.store.bind_session(assignment["id"], claimed["generation"], "worker-" + suffix, "native-" + suffix,
                                       "/tmp/synthetic-pi/session-" + suffix + ".jsonl", "run-" + suffix)

    def outcome(self, assignment, verdict="success", summary="Review completed with evidence.", **extra):
        return self.store.record_outcome(assignment["id"], assignment["generation"], assignment["native_session_id"],
                                         assignment["input_revision"], verdict, summary, "outcome-" + assignment["id"], **extra)

    def turn(self):
        return self.store.claim_message(self.fid, "coordinator")

    def chat(self):
        return [m for m in self.store.snapshot(self.fid)["messages"]
                if m["role"] != "system" and m["visibility"] == "conversation"]

    def notes(self):
        return [e for e in self.store.snapshot(self.fid)["events"] if e["type"] == "coordinator.note"]

    def assert_code(self, code, callback):
        with self.assertRaises(FirstMateError) as error:
            callback()
        self.assertEqual(error.exception.code, code)

    def test_outcome_update_points_at_the_evidence_instead_of_copying_it(self):
        visit = self.stage()
        lane = self.running(visit, "1")
        summary = "Reviewed every module and recorded the findings. " * 60
        self.outcome(lane, summary=summary, documents=[{"title": "Review", "content": "# Evidence"}])
        snapshot = self.store.snapshot(self.fid)
        notice = [m for m in snapshot["messages"] if m["role"] == "system"][-1]
        self.assertEqual(notice["visibility"], "background")
        self.assertEqual(notice["metadata"]["attention"], "background")
        self.assertTrue(notice["text"].startswith("Lane 1 reported success: Reviewed every module"))
        self.assertLess(len(notice["text"]), 700)
        self.assertIn("router state for assignment " + lane["id"], notice["text"])
        self.assertIn(snapshot["documents"][0]["id"], notice["text"])
        # The coordinator still has the whole report where it routes from.
        self.assertEqual(self.store.get_assignment(lane["id"])["summary"], summary)

    def test_background_reply_is_a_private_note_while_work_continues(self):
        visit = self.stage()
        first, _second = self.running(visit, "1"), self.running(visit, "2")
        self.outcome(first)
        before = self.chat()
        turn = self.turn()
        self.assertEqual(turn["role"], "system")
        self.store.finish_message(turn["id"], "coordinator", "Lane 1 is done; waiting on lane 2.")
        self.assertEqual(self.chat(), before)
        note = self.notes()[-1]
        self.assertEqual(note["summary"], "Lane 1 is done; waiting on lane 2.")
        self.assertEqual(note["payload"]["reason"], "background_update")
        self.assertEqual(note["payload"]["message_id"], turn["id"])
        self.assertEqual(self.store.snapshot(self.fid)["messages"][-1]["status"], "done")
        self.assertIsNone(self.store.get_feature(self.fid)["coordinator_owner"])

    def test_stage_checkpoint_is_the_only_report_for_its_turn(self):
        visit = self.stage()
        self.outcome(self.running(visit, "1"))
        turn = self.turn()
        self.store.complete_visit(visit["id"], "Plan reviewed; see the review Document.", "Start implementation",
                                  "complete-1", turn_id=turn["id"])
        self.store.finish_message(turn["id"], "coordinator", "Stage closed. Awaiting your direction.")
        chat = self.chat()
        self.assertTrue(chat[-1]["metadata"]["checkpoint"])
        self.assertEqual(chat[-1]["metadata"]["turn_id"], turn["id"])
        self.assertNotIn("Stage closed. Awaiting your direction.", [m["text"] for m in chat])
        self.assertEqual(self.notes()[-1]["payload"]["reason"], "reported_this_turn")

    def test_a_stranded_stage_reaches_the_human_once_per_state(self):
        visit = self.stage()
        self.outcome(self.running(visit, "1"), verdict="blocked", summary="Cannot compile: the SDK is missing.")
        turn = self.turn()
        question = "The build lane is blocked on a missing SDK. Should I install it or skip that target?"
        self.store.finish_message(turn["id"], "coordinator", question)
        report = self.chat()[-1]
        self.assertEqual(report["text"], question)
        self.assertEqual(report["metadata"]["origin"], "background")
        self.assertEqual(report["metadata"]["in_reply_to"], turn["id"])
        self.assertTrue(report["metadata"]["state_fingerprint"])

        # A stability kick in the same state repeats nothing.
        self.store.queue_system_message(self.fid, "Stability sweep found the current authorized stage idle.", "kick-1",
                                        attention="background")
        kick = self.turn()
        self.store.finish_message(kick["id"], "coordinator", "Same blocker as last turn.")
        self.assertEqual(self.chat()[-1]["id"], report["id"])
        self.assertEqual(self.notes()[-1]["payload"]["reason"], "unchanged_state")

        # Once the human speaks, the unresolved state may be raised again.
        human = self.store.append_human_message(self.fid, "Hold on while I check.", "human-2")
        reply_turn = self.turn()
        self.assertEqual(reply_turn["id"], human["id"])
        self.store.finish_message(reply_turn["id"], "coordinator", "Understood; the lane stays blocked meanwhile.")
        self.store.queue_system_message(self.fid, "Stability sweep found the current authorized stage idle.", "kick-2",
                                        attention="background")
        kick = self.turn()
        self.store.finish_message(kick["id"], "coordinator", "Still blocked until you choose install or skip.")
        self.assertEqual(self.chat()[-1]["text"], "Still blocked until you choose install or skip.")

    def test_updates_that_need_the_human_are_delivered_while_work_runs(self):
        visit = self.stage()
        first, _second = self.running(visit, "1"), self.running(visit, "2")
        self.store.request_human_gate(first["id"], first["generation"], first["native_session_id"],
                                      "Choose SQLite or Core Data for the cache.", "gate-1")
        turn = self.turn()
        self.assertEqual(turn["metadata"]["attention"], "human")
        self.store.finish_message(turn["id"], "coordinator", "Lane 1 needs your call: SQLite or Core Data?")
        self.assertEqual(self.chat()[-1]["text"], "Lane 1 needs your call: SQLite or Core Data?")

    def test_a_failed_background_turn_reaches_the_human_only_when_nothing_is_running(self):
        visit = self.stage()
        first, second = self.running(visit, "1"), self.running(visit, "2")
        failure = "First Mate stopped while handling a background update. Its evidence is retained; send a message to continue."
        self.outcome(first)
        turn = self.turn()
        before = self.chat()
        self.store.finish_message(turn["id"], "coordinator", failure)
        self.assertEqual(self.chat(), before)
        self.assertEqual(self.notes()[-1]["payload"]["reason"], "background_update")
        # Every lane settled but the stage never closed: only the human can continue.
        self.outcome(second)
        turn = self.turn()
        self.store.finish_message(turn["id"], "coordinator", failure)
        self.assertEqual(self.chat()[-1]["text"], failure)

    def test_a_stalled_authorized_follow_up_is_reported(self):
        message = self.store.claim_message(self.fid, "coordinator")
        visit = self.store.start_visit(self.fid, "plan", "Planning", "visit-1", 1, message["id"],
                                       followup_stages=["build"])
        self.store.finish_message(message["id"], "coordinator", "Planning first, then the build.")
        self.outcome(self.running(visit, "1"))
        turn = self.turn()
        self.store.complete_visit(visit["id"], "Plan ready.", "Build it", "complete-1", turn_id=turn["id"])
        self.store.finish_message(turn["id"], "coordinator", "Continuing to the build.")
        follow_up = self.turn()
        self.assertEqual(follow_up["metadata"]["attention"], "background")
        self.assertEqual(self.store.get_feature(self.fid)["status"], "coordinating")
        stalled = "First Mate stopped while handling a background update. Its evidence is retained; send a message to continue."
        self.store.finish_message(follow_up["id"], "coordinator", stalled)
        self.assertEqual(self.chat()[-1]["text"], stalled)

    def test_each_decision_in_a_burst_reaches_the_human(self):
        visit = self.stage()
        first, second = self.running(visit, "1"), self.running(visit, "2")
        self.store.request_human_gate(first["id"], first["generation"], first["native_session_id"],
                                      "Choose SQLite or Core Data for the cache.", "gate-1")
        self.store.request_human_gate(second["id"], second["generation"], second["native_session_id"],
                                      "Keep or drop the legacy endpoint?", "gate-2")
        for question in ("Lane 1 needs your call: SQLite or Core Data?", "Lane 2 needs your call: keep or drop the legacy endpoint?"):
            turn = self.turn()
            self.assertEqual(turn["metadata"]["attention"], "human")
            self.store.finish_message(turn["id"], "coordinator", question)
            self.assertEqual(self.chat()[-1]["text"], question)

    def test_a_reclaimed_background_update_can_report_after_the_human_speaks(self):
        visit = self.stage()
        first, _second = self.running(visit, "1"), self.running(visit, "2")
        self.outcome(first)
        turn = self.turn()
        self.store.notify_human(self.fid, turn["id"], "coordinator", "Draft PR #7 is ready for your review.", "notice-1")
        human = self.store.append_human_message(self.fid, "Looking now.", "human-2")
        self.store.release_message(turn["id"], "coordinator", "Background update deferred for a human message",
                                   verified_stopped=True)
        self.assertEqual(self.turn()["id"], human["id"])
        self.store.finish_message(human["id"], "coordinator", "Thanks, I will hold merge prep.")
        again = self.turn()
        self.assertEqual(again["id"], turn["id"])
        notice = self.store.notify_human(self.fid, again["id"], "coordinator",
                                         "Lane 2 found a regression in PR #7; merge prep stays paused.", "notice-2")
        self.assertEqual(self.chat()[-1]["id"], notice["id"])

    def test_an_unknown_dispatch_under_automatic_recovery_stays_background(self):
        visit = self.stage()
        lane, _other = self.running(visit, "1"), self.running(visit, "2")
        self.store.mark_dispatch_unknown(lane["id"], lane["generation"], "Supervisor disappeared.", "unknown-1",
                                         attention="background")
        turn = self.turn()
        self.assertEqual(turn["metadata"]["attention"], "background")
        self.store.finish_message(turn["id"], "coordinator", "Automatic recovery is assessing lane 1.")
        self.assertEqual(self.notes()[-1]["payload"]["reason"], "background_update")
        self.assertEqual(system_message_attention({"metadata": {}, "text": "Supervisor disappeared. Work and saved sessions are retained."}), "human")

    def test_system_updates_default_to_needing_the_human(self):
        update = self.store.queue_system_message(self.fid, "Something new needs a look.", "update-1")
        self.assertEqual(update["metadata"]["attention"], "human")

    def test_notice_is_one_brief_background_report(self):
        visit = self.stage()
        first, _second = self.running(visit, "1"), self.running(visit, "2")
        self.outcome(first)
        turn = self.turn()
        text = "Draft PR #7 is ready for your review; lane 2 is still testing."
        notice = self.store.notify_human(self.fid, turn["id"], "coordinator", text, "notice-1")
        self.assertEqual(notice["visibility"], "conversation")
        self.assertTrue(notice["metadata"]["notice"])
        self.assertEqual(notice["metadata"]["turn_id"], turn["id"])
        self.assertEqual(self.store.notify_human(self.fid, turn["id"], "coordinator", text, "notice-1")["id"], notice["id"])
        self.assert_code("notice_already_sent", lambda: self.store.notify_human(
            self.fid, turn["id"], "coordinator", "Another update", "notice-2"))
        self.store.finish_message(turn["id"], "coordinator", "Told the human about the PR.")
        self.assertEqual(self.chat()[-1]["id"], notice["id"])
        self.assertEqual(self.notes()[-1]["payload"]["reason"], "reported_this_turn")

        self.store.queue_system_message(self.fid, "Stability sweep found the current authorized stage idle.", "kick-1",
                                        attention="background")
        kick = self.turn()
        self.assert_code("notice_unchanged", lambda: self.store.notify_human(
            self.fid, kick["id"], "coordinator", "Reminder: PR #7 awaits review.", "notice-3"))
        self.store.finish_message(kick["id"], "coordinator", "Nothing new.")

        self.store.append_human_message(self.fid, "Thanks.", "human-thanks")
        human = self.turn()
        self.assert_code("notice_not_needed", lambda: self.store.notify_human(
            self.fid, human["id"], "coordinator", "Hello", "notice-4"))
        self.assert_code("stale_owner", lambda: self.store.notify_human(
            self.fid, human["id"], "another-owner", "Hello", "notice-5"))
        rated = self.store.rate_feedback(self.fid, notice["id"], {
            "rating": "up", "category_ids": [], "comment": "", "expected_revision": 0, "request_id": "rate-notice"})
        self.assertEqual(rated["provenance"]["source_kind"], "notice")

    def test_board_and_dashboard_summary_read_only_the_conversation(self):
        self.stage()
        self.store._db.execute(
            "INSERT INTO fm_messages(id,feature_id,role,text,status,metadata_json,created_at,updated_at,visibility) "
            "VALUES('fmm_background',?,'assistant','Background chatter','done','{}',?,?,'background')",
            (self.fid, _now(), _now()))
        board = self.store.board(self.fid)
        self.assertNotIn("Background chatter", [m["text"] for m in board["messages"]])
        self.assertEqual(board["messages_total"], len(board["messages"]))
        self.assertEqual(board["feature"]["dashboard_summary"]["latest_message"], "Planning is running.")
        row = next(m for m in self.store.snapshot(self.fid)["messages"] if m["id"] == "fmm_background")
        self.assertEqual(row["visibility"], "background")

    def test_system_update_attention_defaults_to_the_human_for_unrecognized_history(self):
        self.assertEqual(system_message_attention({"metadata": {"attention": "human"}, "text": "x"}), "human")
        self.assertEqual(system_message_attention({"metadata": {"verdict": "success"}, "text": "Lane: ok"}), "background")
        self.assertEqual(system_message_attention({"metadata": {}, "text": "The Planning stage finished with evidence. The original human direction authorized implementation next."}), "background")
        self.assertEqual(system_message_attention({"metadata": {}, "text": "Stability sweep found the current authorized stage idle."}), "background")
        self.assertEqual(system_message_attention({"metadata": {"human_gate": {}}, "text": "Human checkpoint: pick one"}), "human")
        self.assertEqual(system_message_attention({"metadata": {}, "text": "Something new"}), "human")


class QuietChatMigrationTests(unittest.TestCase):
    """An existing ledger is labeled once; text is never rewritten."""

    def test_existing_history_is_classified_once(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "legacy.sqlite3"
            legacy = sqlite3.connect(path)
            legacy.executescript(SCHEMA)
            legacy.execute("INSERT INTO fm_features(id,title,goal,cwd,status,revision,created_at,updated_at) "
                           "VALUES('fmf_legacy','Legacy','Plan it','/tmp/synthetic','running',1,'2026-09-01T00:00:00Z','2026-09-01T00:00:00Z')")
            outcome = {"verdict": "success", "assignment_id": "a"}
            follow_up = "The Planning stage finished with evidence. The original human direction authorized implementation next."
            sweep = "Stability sweep found the current authorized stage marked running."
            history = [
                (0, "u1", "user", "Plan it", {}),
                (1, "s1", "system", "Planner: done", outcome),
                (3, "c1", "assistant", "Plan ready. Awaiting your direction.", {"checkpoint": True}),
                (4, "a1", "assistant", "Planning closed out clean.", {"in_reply_to": "s1"}),  # its turn already reported
                (5, "u2", "user", "Go ahead.", {}),
                (6, "s2", "system", follow_up, {}),
                (8, "a2", "assistant", "Starting implementation now.", {"in_reply_to": "s2"}),  # superseded by c2
                (9, "c2", "assistant", "Implementation done. Awaiting your direction.", {"checkpoint": True}),
                (10, "s5", "system", "Build: blocked", {"verdict": "blocked", "assignment_id": "b"}),
                (12, "a5", "assistant", "Install the SDK or skip that target?", {"in_reply_to": "s5"}),  # answered run
                (13, "s4", "system", sweep, {}),
                (15, "a4", "assistant", "Same blocker as last turn.", {"in_reply_to": "s4"}),  # answered run
                (16, "u3", "user", "Skip it.", {}),
                (17, "s3", "system", "Automatic recovery needs direction: two kickstarts did not settle.", {}),
                (19, "a3", "assistant", "Every automatic path is refused; I need your direction.", {"in_reply_to": "s3"}),
                (20, "s6", "system", sweep, {}),
                (22, "a6", "assistant", "Same state.", {"in_reply_to": "s6"}),  # trailing, unanswered
            ]
            claims = {"s1": 2, "s2": 7, "s5": 11, "s4": 14, "s3": 18, "s6": 21}
            for second, identity, role, text, metadata in history:
                stamp = f"2026-09-01T00:00:{second:02d}Z"
                legacy.execute("INSERT INTO fm_messages(id,feature_id,role,text,status,metadata_json,created_at,updated_at) "
                               "VALUES(?,'fmf_legacy',?,?,'done',?,?,?)", (identity, role, text, json.dumps(metadata), stamp, stamp))
            for identity, second in claims.items():
                legacy.execute("INSERT INTO fm_events(id,feature_id,type,summary,created_at,payload_json) "
                               "VALUES(?,'fmf_legacy','message.claimed','First Mate is processing an update',?,?)",
                               ("claim-" + identity, f"2026-09-01T00:00:{second:02d}Z", json.dumps({"message_id": identity})))
            legacy.commit()
            legacy.close()

            store = FirstMateStore(path)
            try:
                messages = store.snapshot("fmf_legacy")["messages"]
                chat = [m["id"] for m in messages if m["visibility"] == "conversation"]
                self.assertEqual(chat, ["u1", "c1", "u2", "c2", "a5", "a4", "u3", "a3"])
                self.assertTrue(all(m["visibility"] == "background" for m in messages if m["role"] == "system"))
                self.assertEqual(next(m["text"] for m in messages if m["id"] == "a6"), "Same state.")
                self.assertIsNotNone(store._db.execute("SELECT 1 FROM fm_schema WHERE version=13").fetchone())
                store._db.execute("UPDATE fm_messages SET visibility='conversation' WHERE id='a6'")
            finally:
                store.close()
            reopened = FirstMateStore(path)
            try:
                row = next(m for m in reopened.snapshot("fmf_legacy")["messages"] if m["id"] == "a6")
                self.assertEqual(row["visibility"], "conversation")
            finally:
                reopened.close()


if __name__ == "__main__":
    unittest.main()
