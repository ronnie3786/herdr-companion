"""The First Mate fleet summary, read markers, and presentation (first-mate-fleet-v1).

All features, messages, and links are synthetic.
"""
from __future__ import annotations

import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from herdr_harness import first_mate_fleet as fleet
from herdr_harness.first_mate_store import FirstMateError, FirstMateStore
from herdr_harness.server import make_handler

# Shared with the Swift client (FirstMateDefaultEmoji): feature_id, FNV-1a, index, emoji.
EMOJI_VECTORS = (
    ("fmf_00000000000000000000000000000001", 3332065392, 11, "🌱"),
    ("fmf_receipts", 779939090, 14, "🧰"),
    ("demo-session-continuity", 2487823904, 9, "🎨"),
    ("receipts", 4180312464, 10, "📚"),
    ("a", 3826002220, 0, "🧭"),
    ("", 2166136261, 9, "🎨"),
    ("fmf_9f8e7d6c5b4a39281706f5e4d3c2b1a0", 696065923, 14, "🧰"),
    ("fmf_ü✓", 1798211435, 5, "📋"),
)
ENTRY_FIELDS = {"feature_id", "title", "label", "emoji", "emoji_source", "status", "hud_status", "step_index",
                "step_fraction", "percent", "now", "latest_message", "latest_first_mate_message_id",
                "read_through_message_id", "unread", "working_on_reply", "activity_at", "updated_at", "archived_at"}
SKIM_KEY = {"format": "breath_tight", "prompt_version": "skim-v2", "segmenter_version": 1, "skim_version": 1,
            "model": "synthetic/skimmer", "thinking": "off", "reply_sha256": "0" * 64}
SKIM_DOCUMENT = {"version": 1, "format": "breath_tight", "status": "answer", "blocks": [
    {"kind": "say", "tokens": [{"t": "text", "v": "Checkout  "},
                               {"t": "anchor", "id": "a1", "label": [{"t": "text", "v": "holds stock"}], "refs": ["s1"]},
                               {"t": "text", "v": " after a declined card."}]},
    {"kind": "say", "tokens": [{"t": "text", "v": "A second sentence."}]},
    {"kind": "reply", "tokens": [{"t": "text", "v": "Write the rollback"}]},
]}


class StatusMappingTests(unittest.TestCase):
    def test_blocked_and_recovering(self):
        self.assertEqual(fleet.hud_status("blocked"), "blocked")
        self.assertEqual(fleet.hud_status("recovering", automatic_recovery=True), "working")
        self.assertEqual(fleet.hud_status("recovering", automatic_recovery=False), "blocked")

    def test_awaiting_direction_splits_ready_from_turn(self):
        stage_result = {"attention_type": "visit.awaiting_direction", "visit_status": "completed"}
        for step in (2, 4, 5):
            self.assertEqual(fleet.hud_status("awaiting_direction", step_index=step, **stage_result), "ready")
        for step in (None, 0, 1, 3):
            self.assertEqual(fleet.hud_status("awaiting_direction", step_index=step, **stage_result), "turn")
        # A human gate or a still-running visit is a question, not finished work.
        self.assertEqual(fleet.hud_status("awaiting_direction", step_index=2, attention_type="assignment.awaiting_human",
                                          visit_status="completed"), "turn")
        self.assertEqual(fleet.hud_status("awaiting_direction", step_index=4, attention_type="visit.awaiting_direction",
                                          visit_status="running"), "turn")
        self.assertEqual(fleet.hud_status("awaiting_direction"), "turn")
        # A visible pull request is finished work waiting at any step.
        self.assertEqual(fleet.hud_status("awaiting_direction", step_index=None, has_pull_request=True), "ready")
        self.assertTrue(fleet.awaiting_direction_is_ready(attention_type=None, visit_status=None, step_index=None,
                                                          has_pull_request=True))

    def test_awaiting_turn_and_the_quiet_statuses(self):
        for status in ("running", "coordinating"):
            self.assertEqual(fleet.hud_status(status, awaiting_turn=True), "turn")
            self.assertEqual(fleet.hud_status(status, awaiting_turn=False), "working")
        self.assertEqual(fleet.hud_status("ready"), "idle")
        self.assertEqual(fleet.hud_status("paused"), "idle")
        self.assertEqual(fleet.hud_status("completed"), "done")
        self.assertEqual(fleet.hud_status("cancelled"), "idle")
        self.assertEqual(fleet.hud_status("unverified"), "idle")
        self.assertEqual(fleet.hud_status(None), "idle")
        self.assertEqual(fleet.hud_status("paused", has_pull_request=True, awaiting_turn=True), "idle")


class StepMappingTests(unittest.TestCase):
    def test_contract_examples(self):
        for key, expected in (("code-review-pre-pr", 4), ("proof", 3), ("improve-copy", None), ("planning", 0),
                              ("implementation", 1)):
            self.assertEqual(fleet.step_index(key), expected, key)

    def test_prefix_matching_precedence_and_edges(self):
        for key, expected in (
            ("plan", 0), ("PLAN", 0), ("start-ticket", None), ("implement", 1), ("build", 1), ("building", 1),
            ("rebuild", None), ("architect-code-review", 2), ("reviews", 2), ("qa", 3), ("qa-signoff", 3),
            ("quality", None), ("testing", 3), ("contest", None), ("pr", 4), ("pr-triage", 4), ("Code_Review Pre PR", 4),
            ("prepare", None), ("preflight", None), ("prototype", None), ("merge", 5), ("merged-review", 5),
            ("review-then-merge", 5), ("plan_and_build", 1), ("", None), ("--", None), (None, None), (7, None),
        ):
            self.assertEqual(fleet.step_index(key), expected, key)

    def test_fraction_and_percent_follow_the_visit(self):
        self.assertEqual(fleet.step_progress("plan", "running"), (0, 0.0, 0))
        self.assertEqual(fleet.step_progress("plan", "completed"), (0, 1.0, 17))
        self.assertEqual(fleet.step_progress("proof", "completed"), (3, 1.0, 67))
        self.assertEqual(fleet.step_progress("proof", "cancelled"), (3, 0.0, 50))
        self.assertEqual(fleet.step_progress("merge", "completed"), (5, 1.0, 100))
        self.assertEqual(fleet.step_progress("improve-copy", "completed"), (None, None, None))
        self.assertEqual(fleet.step_progress(None, None), (None, None, None))


class PresentationRuleTests(unittest.TestCase):
    def test_default_emoji_matches_the_shared_vectors(self):
        self.assertEqual(len(fleet.EMOJI_PALETTE), 16)
        self.assertTrue(all(len(emoji) == 1 for emoji in fleet.EMOJI_PALETTE))
        for feature_id, hashed, index, emoji in EMOJI_VECTORS:
            self.assertEqual(fleet.fnv1a32(feature_id), hashed, feature_id)
            self.assertEqual(fleet.EMOJI_PALETTE[index], emoji, feature_id)
            self.assertEqual(fleet.default_emoji(feature_id), emoji, feature_id)

    def test_label_validation_counts_code_points_after_trim(self):
        self.assertEqual(fleet.normalize_label("  Receipt export  "), "Receipt export")
        self.assertEqual(fleet.normalize_label("x" * 24), "x" * 24)
        self.assertEqual(fleet.normalize_label(" " + "é" * 24 + " "), "é" * 24)
        for reset in (None, "", "   "):
            self.assertIsNone(fleet.normalize_label(reset))
        for invalid in ("x" * 25, "Two\nlines", "Tab\there", "Line\u2028break", "Para\u2029break", 12,
                        ["Receipt"]):
            with self.assertRaises(fleet.PresentationError):
                fleet.normalize_label(invalid)

    def test_emoji_validation_is_a_bound_not_a_grapheme_check(self):
        self.assertEqual(fleet.normalize_emoji("🧾"), "🧾")
        self.assertEqual(fleet.normalize_emoji(" 👩‍👩‍👧‍👦 "), "👩‍👩‍👧‍👦")
        self.assertEqual(fleet.normalize_emoji("🇸🇪"), "🇸🇪")
        self.assertEqual(fleet.normalize_emoji("🧑🏽‍🚀"), "🧑🏽‍🚀")
        for reset in (None, "", "  "):
            self.assertIsNone(fleet.normalize_emoji(reset))
        for invalid in ("🧾" * 17, "🧾 🚀", "🧾 🚀", "🧾\x01", 5):
            with self.assertRaises(fleet.PresentationError):
                fleet.normalize_emoji(invalid)

    def test_default_label_is_the_title_on_one_line(self):
        self.assertEqual(fleet.default_label("  Receipt   export "), "Receipt export")
        label = fleet.default_label("Receipt export for every storefront region")
        self.assertEqual(label, "Receipt export for…")
        self.assertLessEqual(len(label), 24)

    def test_clip_cuts_at_a_word_boundary_with_an_ellipsis(self):
        exact = "a" * 120
        self.assertEqual(fleet.clip(exact, 120), exact)
        self.assertEqual(fleet.clip("  QA failed\n\ttwice.  ", 120), "QA failed twice.")
        long = ("The export sheet never appears on iPad, " * 5).strip()
        cut = fleet.clip(long, 120)
        self.assertLessEqual(len(cut), 120)
        self.assertTrue(cut.endswith("…"))
        self.assertTrue(long.startswith(cut[:-1]))
        self.assertIn(long[len(cut) - 1], " ,")  # the cut ends on a word boundary
        self.assertFalse(cut[:-1].endswith((",", " ")))
        self.assertEqual(fleet.clip("x" * 130, 120), "x" * 119 + "…")
        self.assertEqual(fleet.clip("one two three", 9), "one two…")
        self.assertEqual(fleet.clip("one two three", 8), "one two…")
        self.assertIsNone(fleet.clip("   ", 120))
        self.assertIsNone(fleet.clip(None, 120))

    def test_now_line_prefers_the_reason_for_each_status(self):
        sources = {"needs_user_prompt": "Approve the iPad fix?", "progress_summary": "Running the export suite.",
                   "skim_say_text": "Export works on iPhone.", "first_mate_text": "Long reply text."}
        for hud in ("blocked", "turn", "ready"):
            self.assertEqual(fleet.now_line(hud, **sources), "Approve the iPad fix?")
        self.assertEqual(fleet.now_line("working", **sources), "Running the export suite.")
        self.assertEqual(fleet.now_line("working", **{**sources, "progress_summary": None}), "Export works on iPhone.")
        self.assertEqual(fleet.now_line("idle", **sources), "Export works on iPhone.")
        self.assertEqual(fleet.now_line("done", **{**sources, "skim_say_text": None}), "Long reply text.")
        self.assertIsNone(fleet.now_line("idle", needs_user_prompt=None, progress_summary=None,
                                         skim_say_text=None, first_mate_text=None))
        self.assertEqual(len(fleet.now_line("working", **{**sources, "progress_summary": "word " * 60})), 120)

    def test_skim_say_flattens_tokens(self):
        self.assertEqual(fleet.skim_say(SKIM_DOCUMENT["blocks"][0]["tokens"]),
                         "Checkout holds stock after a declined card.")
        self.assertIsNone(fleet.skim_say(None))
        self.assertIsNone(fleet.skim_say([{"no": "type"}]))
        self.assertIsNone(fleet.skim_say([{"t": "text", "v": "  "}]))

    def test_read_marker_order_uses_created_at_then_id(self):
        self.assertTrue(fleet.is_after("2026-09-01T00:00:01Z", "fmm_a", None, None))
        self.assertTrue(fleet.is_after("2026-09-01T00:00:02Z", "fmm_a", "2026-09-01T00:00:01Z", "fmm_z"))
        self.assertTrue(fleet.is_after("2026-09-01T00:00:01Z", "fmm_b", "2026-09-01T00:00:01Z", "fmm_a"))
        self.assertFalse(fleet.is_after("2026-09-01T00:00:01Z", "fmm_a", "2026-09-01T00:00:01Z", "fmm_a"))
        self.assertFalse(fleet.is_after("2026-09-01T00:00:00Z", "fmm_z", "2026-09-01T00:00:01Z", "fmm_a"))
        self.assertFalse(fleet.is_after(None, None, None, None))


class FleetStoreFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "first-mate.sqlite3"
        self.store = FirstMateStore(self.path)
        self.addCleanup(lambda: self.store.close())
        self.feature = self.create("Receipt export", "create-receipts")
        self.id = self.feature["id"]

    def create(self, title, request_id):
        return self.store.create_feature({"title": title, "goal": "Export synthetic receipts.",
                                          "cwd": "/tmp/synthetic-shop", "request_id": request_id})

    def entries(self, view="active", **options):
        return [fleet.entry(row, **options) for row in self.store.fleet_rows(view)]

    def entry(self, feature_id=None, **options):
        return fleet.entry(self.store.fleet_row(feature_id or self.id), **options)

    def reply(self, text="Synthetic reply.", feature_id=None):
        feature_id = feature_id or self.id
        message = self.store.claim_message(feature_id, "coordinator")
        self.store.finish_message(message["id"], "coordinator", reply=text)
        return self.latest_assistant(feature_id)

    def latest_assistant(self, feature_id=None):
        return [m for m in self.store.snapshot(feature_id or self.id)["messages"] if m["role"] == "assistant"][-1]

    def stage(self, key="plan", feature_id=None):
        feature_id = feature_id or self.id
        message = self.store.claim_message(feature_id, "coordinator")
        visit = self.store.start_visit(feature_id, key, "Stage " + key, "visit-" + key, 1, message["id"])
        self.store.finish_message(message["id"], "coordinator", "Stage started.")
        return visit

    def running_assignment(self, visit):
        assignment = self.store.create_assignment(visit["id"], {"title": "Export worker", "role": "implementer",
                                                                "prompt": "Build the synthetic export.",
                                                                "request_id": "assignment-" + visit["id"]})
        claimed = self.store.claim_assignment(assignment["id"], "worker")
        return self.store.bind_session(assignment["id"], claimed["generation"], "worker", "native-worker",
                                       "/tmp/synthetic-pi/worker.jsonl", "run-worker")

    def finished_stage(self, key):
        visit = self.stage(key)
        assignment = self.running_assignment(visit)
        self.store.record_outcome(assignment["id"], assignment["generation"], assignment["native_session_id"],
                                  assignment["input_revision"], "success", "Stage verified.", "outcome")
        self.store.complete_visit(visit["id"], "Stage verified", "Open the pull request next", "complete")
        return visit

    def ready_skim(self, message_id, document=SKIM_DOCUMENT):
        self.store.queue_skim(message_id, SKIM_KEY)
        self.assertIsNotNone(self.store.begin_skim(message_id))
        self.store.finish_skim(message_id, "ready", output="say: synthetic", document=document, segments=[])

    def unchanged_state(self, feature_id=None):
        feature_id = feature_id or self.id
        feature = self.store.get_feature(feature_id)
        return (self.store.board(feature_id)["version"], feature["updated_at"], feature["revision"], feature["status"],
                self.store.get_events(feature_id)["cursor"], self.store.fleet_row(feature_id)["activity_at"])


class FleetStoreTests(FleetStoreFixture, unittest.TestCase):
    def test_migration_adds_the_presentation_table_to_an_existing_store(self):
        self.store.close()
        with sqlite3.connect(self.path) as raw:
            raw.execute("DROP TABLE fm_feature_presentation")
            raw.execute("DELETE FROM fm_schema WHERE version=15")
        first = FirstMateStore(self.path)
        second = FirstMateStore(self.path)  # A second process opening the same store is harmless.
        try:
            for store in (first, second):
                self.assertIsNotNone(store._db.execute("SELECT 1 FROM fm_schema WHERE version=15").fetchone())
                self.assertIsNotNone(store._db.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fm_feature_presentation'").fetchone())
            self.assertEqual(first.get_feature(self.id)["title"], "Receipt export")
            self.assertEqual(first.set_presentation(self.id, {"label": "Receipts"})["label"], "Receipts")
            self.assertEqual(second.fleet_row(self.id)["label"], "Receipts")
        finally:
            first.close()
            second.close()
        self.store = FirstMateStore(self.path)

    def test_entry_shape_and_defaults(self):
        (entry,) = self.entries()
        self.assertEqual(set(entry), ENTRY_FIELDS)
        self.assertEqual(entry["feature_id"], self.id)
        self.assertEqual(entry["label"], "Receipt export")
        self.assertEqual(entry["emoji"], fleet.default_emoji(self.id))
        self.assertEqual(entry["emoji_source"], "default")
        self.assertEqual((entry["status"], entry["hud_status"]), ("ready", "idle"))
        self.assertEqual((entry["step_index"], entry["step_fraction"], entry["percent"]), (None, None, None))
        # The creation goal is a queued human message: First Mate owes a reply.
        self.assertEqual(entry["latest_message"]["role"], "user")
        self.assertEqual(entry["latest_message"]["text"], "Export synthetic receipts.")
        self.assertNotIn("skim_say", entry["latest_message"])
        self.assertTrue(entry["working_on_reply"])
        self.assertIsNone(entry["latest_first_mate_message_id"])
        self.assertIsNone(entry["read_through_message_id"])
        self.assertFalse(entry["unread"])
        self.assertIsNone(entry["now"])
        self.assertIsNone(entry["archived_at"])
        json.dumps(entry, ensure_ascii=False, allow_nan=False)

    def test_latest_message_text_is_one_line_cut_to_200(self):
        reply = self.reply("Line one.\n\n" + "export " * 60)
        entry = self.entry()
        self.assertEqual(entry["latest_message"]["id"], reply["id"])
        self.assertEqual(entry["latest_message"]["role"], "assistant")
        self.assertLessEqual(len(entry["latest_message"]["text"]), 200)
        self.assertTrue(entry["latest_message"]["text"].startswith("Line one. export export"))
        self.assertTrue(entry["latest_message"]["text"].endswith("…"))
        self.assertEqual(entry["latest_first_mate_message_id"], reply["id"])
        self.assertFalse(entry["working_on_reply"])

    def test_unread_follows_the_latest_first_mate_message_and_the_marker(self):
        first = self.reply("First answer.")
        self.assertTrue(self.entry()["unread"])
        self.assertEqual(self.store.mark_read(self.id, first["id"]),
                         {"feature_id": self.id, "read_through_message_id": first["id"], "unread": False})
        self.assertFalse(self.entry()["unread"])
        self.assertEqual(self.entry()["read_through_message_id"], first["id"])
        self.store.append_human_message(self.id, "And the totals?", "totals")
        # The human's own message never makes the feature unread.
        self.assertFalse(self.entry()["unread"])
        self.assertTrue(self.entry()["working_on_reply"])
        second = self.reply("Totals are included.")
        entry = self.entry()
        self.assertTrue(entry["unread"])
        self.assertEqual(entry["latest_first_mate_message_id"], second["id"])
        self.assertEqual(entry["read_through_message_id"], first["id"])

    def test_read_markers_are_monotonic_and_idempotent(self):
        first = self.reply("First answer.")
        user = self.store.append_human_message(self.id, "More?", "more")
        second = self.reply("Second answer.")
        self.assertEqual(self.store.mark_read(self.id, second["id"])["read_through_message_id"], second["id"])
        # An older marker from a racing window never moves it back.
        for older in (first["id"], user["id"], second["id"]):
            result = self.store.mark_read(self.id, older)
            self.assertEqual(result, {"feature_id": self.id, "read_through_message_id": second["id"], "unread": False})
        # Reading through a newer human message covers the First Mate message before it.
        self.store.append_human_message(self.id, "Thanks", "thanks")
        latest_user = [m for m in self.store.snapshot(self.id)["messages"] if m["role"] == "user"][-1]
        result = self.store.mark_read(self.id, latest_user["id"])
        self.assertEqual(result["read_through_message_id"], latest_user["id"])
        self.assertFalse(result["unread"])

    def test_read_marker_errors(self):
        other = self.create("Search filters", "create-search")
        mine = self.reply("Mine.")
        theirs = self.reply("Theirs.", feature_id=other["id"])
        with self.assertRaises(FirstMateError) as missing:
            self.store.mark_read(self.id, "fmm_missing")
        self.assertEqual((missing.exception.status, missing.exception.code), (404, "not_found"))
        with self.assertRaises(FirstMateError) as foreign:
            self.store.mark_read(self.id, theirs["id"])
        self.assertEqual(foreign.exception.status, 409)
        with self.assertRaises(FirstMateError) as no_feature:
            self.store.mark_read("fmf_missing", mine["id"])
        self.assertEqual(no_feature.exception.status, 404)
        self.assertIsNone(self.entry()["read_through_message_id"])
        self.assertIsNone(self.entry(other["id"])["read_through_message_id"])

    def test_presentation_writes_never_touch_the_feature_or_the_board(self):
        reply = self.reply("First answer.")
        before = self.unchanged_state()
        self.store.mark_read(self.id, reply["id"])
        self.store.set_presentation(self.id, {"label": "Receipts", "emoji": "🧾"})
        self.store.set_presentation(self.id, {"label": None})
        self.assertEqual(self.unchanged_state(), before)
        self.assertTrue(self.store.board(self.id, if_version=before[0])["unchanged"])

    def test_set_presentation_sets_and_resets(self):
        row = self.store.set_presentation(self.id, {"label": "  Receipts  ", "emoji": "🧾"})
        entry = fleet.entry(row)
        self.assertEqual((entry["label"], entry["emoji"], entry["emoji_source"]), ("Receipts", "🧾", "user"))
        entry = fleet.entry(self.store.set_presentation(self.id, {"emoji": ""}))
        self.assertEqual((entry["label"], entry["emoji"], entry["emoji_source"]),
                         ("Receipts", fleet.default_emoji(self.id), "default"))
        entry = fleet.entry(self.store.set_presentation(self.id, {"label": None}))
        self.assertEqual(entry["label"], "Receipt export")
        for invalid in ({}, {"title": "x"}, {"label": "x" * 25}, {"emoji": "a b"}, {"label": 3}):
            with self.assertRaises(FirstMateError) as error:
                self.store.set_presentation(self.id, invalid)
            self.assertEqual(error.exception.status, 400, invalid)
        with self.assertRaises(FirstMateError) as missing:
            self.store.set_presentation("fmf_missing", {"label": "Ghost"})
        self.assertEqual(missing.exception.status, 404)

    def test_fleet_is_ordered_by_activity_and_filtered_by_archive_view(self):
        second = self.create("Search filters", "create-search")
        third = self.create("Release notes", "create-release")
        self.assertEqual([e["feature_id"] for e in self.entries()], [third["id"], second["id"], self.id])
        self.reply("Receipts moved.")
        self.assertEqual([e["feature_id"] for e in self.entries()], [self.id, third["id"], second["id"]])
        # Presentation never reorders the list.
        self.store.set_presentation(second["id"], {"label": "Search"})
        self.assertEqual([e["feature_id"] for e in self.entries()], [self.id, third["id"], second["id"]])
        self.store.set_archived(third["id"], True, {"request_id": "archive-release", "reason": "duplicate"})
        self.assertEqual([e["feature_id"] for e in self.entries("active")], [self.id, second["id"]])
        archived = self.entries("archived")
        self.assertEqual([e["feature_id"] for e in archived], [third["id"]])
        self.assertIsNotNone(archived[0]["archived_at"])
        self.assertEqual({e["feature_id"] for e in self.entries("all")}, {self.id, second["id"], third["id"]})
        with self.assertRaises(FirstMateError):
            self.store.fleet_rows("closed")

    def test_working_feature_uses_the_running_progress_summary(self):
        visit = self.stage("implement")
        assignment = self.running_assignment(visit)
        self.store.record_progress(assignment["id"], assignment["generation"], assignment["native_session_id"],
                                   "Wiring the  receipt\nexporter.", "Run the export suite", "Two files changed.", 0,
                                   "progress-1")
        entry = self.entry()
        self.assertEqual((entry["status"], entry["hud_status"]), ("running", "working"))
        self.assertEqual((entry["step_index"], entry["step_fraction"], entry["percent"]), (1, 0.0, 17))
        self.assertEqual(entry["now"], "Wiring the receipt exporter.")

    def test_stage_result_at_review_is_ready_and_elsewhere_is_turn(self):
        self.finished_stage("code-review")
        entry = self.entry()
        self.assertEqual((entry["status"], entry["hud_status"]), ("awaiting_direction", "ready"))
        self.assertEqual((entry["step_index"], entry["step_fraction"], entry["percent"]), (2, 1.0, 50))
        self.assertEqual(entry["now"], "Open the pull request next")
        self.assertTrue(entry["unread"])  # the checkpoint is a First Mate message

    def test_stage_result_at_qa_is_turn_until_a_pull_request_is_visible(self):
        self.finished_stage("proof")
        self.assertEqual(self.entry()["hud_status"], "turn")
        link = self.store.save_link(self.id, {"url": "https://github.com/synthetic/shop/pull/7", "request_id": "pr"})
        self.assertEqual(self.entry()["hud_status"], "ready")
        self.store.set_link_visibility(self.id, link["id"], {"hidden": True, "request_id": "hide-pr"})
        self.assertEqual(self.entry()["hud_status"], "turn")

    def test_parked_turn_and_recovery_modes(self):
        self.stage("plan")
        entry = self.entry()
        self.assertEqual((entry["status"], entry["hud_status"]), ("running", "turn"))
        self.assertEqual(entry["now"], "Stage started.")
        self.store._db.execute("UPDATE fm_features SET status='recovering' WHERE id=?", (self.id,))
        self.assertEqual(self.entry(automatic_recovery=True)["hud_status"], "working")
        blocked = self.entry(automatic_recovery=False)
        self.assertEqual(blocked["hud_status"], "blocked")
        self.assertEqual(blocked["now"], "Recovery needs your direction")

    def test_ready_skim_say_is_the_preview_and_the_now_line(self):
        reply = self.reply("A long synthetic reply about checkout holds.")
        self.assertNotIn("skim_say", self.entry()["latest_message"])
        self.ready_skim(reply["id"])
        entry = self.entry()
        self.assertEqual(entry["latest_message"]["skim_say"], "Checkout holds stock after a declined card.")
        self.assertEqual(entry["now"], "Checkout holds stock after a declined card.")
        # A newer human message leads the preview; the skim stays on the now line only.
        self.store.append_human_message(self.id, "Ship it?", "ship")
        entry = self.entry()
        self.assertEqual(entry["latest_message"]["role"], "user")
        self.assertNotIn("skim_say", entry["latest_message"])
        self.assertEqual(entry["now"], "Checkout holds stock after a declined card.")

    def test_malformed_skim_blocks_do_not_break_the_fleet(self):
        first = self.reply("Reply with a stray string block.")
        self.ready_skim(first["id"], {"version": 1, "blocks": ["stray", {"kind": "say", "tokens": [{"t": "text", "v": "Kept."}]}]})
        self.assertEqual(self.entry()["latest_message"]["skim_say"], "Kept.")
        self.store.append_human_message(self.id, "And the string case?", "string-case")
        second = self.reply("Reply whose blocks are a string.")
        self.ready_skim(second["id"], {"version": 1, "blocks": "stray"})
        entry = self.entry()
        self.assertNotIn("skim_say", entry["latest_message"])
        self.assertEqual(entry["now"], "Reply whose blocks are a string.")

    def test_skim_without_a_say_block_falls_back_to_the_message(self):
        reply = self.reply("Plain fallback reply.")
        self.ready_skim(reply["id"], {"version": 1, "blocks": [{"kind": "ask", "tokens": [{"t": "text", "v": "Go?"}]}]})
        entry = self.entry()
        self.assertNotIn("skim_say", entry["latest_message"])
        self.assertEqual(entry["now"], "Plain fallback reply.")


class FleetHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = FirstMateStore(Path(self.temp.name) / "work.sqlite3")
        self.wakes = []
        runtime = SimpleNamespace(capabilities=lambda: {"available": True}, health=lambda: {"status": "ok"})
        self.service = SimpleNamespace(
            environ={"HERDR_HARNESS_API_TOKEN": "synthetic-main-token"},
            first_mate_store=self.store, first_mate=runtime, first_mate_changed=self.wakes.append,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.store.close()
        self.temp.cleanup()

    def request(self, path, body=None, token="synthetic-main-token"):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(self.origin + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers)
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def create(self, title="Receipt export", request_id="create-receipts"):
        code, data = self.request("/api/v1/first-mate/features", {"title": title, "goal": "Export synthetic receipts.",
                                                                  "cwd": self.temp.name, "request_id": request_id})
        self.assertEqual(code, 201)
        return data["feature"]["id"]

    def reply(self, feature_id, text="Synthetic reply."):
        message = self.store.claim_message(feature_id, "coordinator")
        self.store.finish_message(message["id"], "coordinator", reply=text)
        return [m for m in self.store.snapshot(feature_id)["messages"] if m["role"] == "assistant"][-1]

    def test_capability_is_advertised_at_both_levels(self):
        code, top = self.request("/api/v1")
        self.assertEqual(code, 200)
        self.assertIn("first-mate-fleet-v1", top["capabilities"])
        self.assertEqual(top["endpoints"]["firstMateFleet"], "/api/v1/first-mate/fleet")
        self.assertIn("POST /api/v1/first-mate/features/{featureId}/read|hud", top["mutations"])
        code, first_mate = self.request("/api/v1/first-mate/capabilities")
        self.assertEqual(code, 200)
        self.assertIn("first-mate-fleet-v1", first_mate["capabilities"])

    def test_fleet_shape_views_and_auth(self):
        feature_id = self.create()
        wakes = list(self.wakes)
        code, data = self.request("/api/v1/first-mate/fleet")
        self.assertEqual(code, 200)
        self.assertEqual(set(data), {"ok", "generated_at", "features"})
        self.assertTrue(data["generated_at"].endswith("Z"))
        (entry,) = data["features"]
        self.assertEqual(set(entry), ENTRY_FIELDS)
        self.assertEqual(entry["feature_id"], feature_id)
        self.assertEqual(entry["emoji"], fleet.default_emoji(feature_id))
        self.assertEqual(self.request("/api/v1/first-mate/fleet?view=archived")[1]["features"], [])
        self.assertEqual(len(self.request("/api/v1/first-mate/fleet?view=all")[1]["features"]), 1)
        for bad in ("?view=closed", "?view=active&view=all", "?limit=3"):
            code, error = self.request("/api/v1/first-mate/fleet" + bad)
            self.assertEqual(code, 400, bad)
            self.assertFalse(error["ok"])
        self.assertEqual(self.request("/api/v1/first-mate/fleet", token=None)[0], 401)
        self.assertEqual(self.wakes, wakes)

    def test_fleet_honors_the_runtime_recovery_setting(self):
        feature_id = self.create()
        self.store._db.execute("UPDATE fm_features SET status='recovering' WHERE id=?", (feature_id,))
        self.assertEqual(self.request("/api/v1/first-mate/fleet")[1]["features"][0]["hud_status"], "working")
        self.service.first_mate.reliability = SimpleNamespace(enabled=False)
        self.assertEqual(self.request("/api/v1/first-mate/fleet")[1]["features"][0]["hud_status"], "blocked")

    def test_read_marks_without_waking_or_changing_the_board(self):
        feature_id = self.create()
        other_id = self.create("Search filters", "create-search")
        reply = self.reply(feature_id)
        foreign = self.reply(other_id)
        path = f"/api/v1/first-mate/features/{feature_id}/read"
        version = self.store.board(feature_id)["version"]
        wakes = list(self.wakes)
        code, data = self.request(path, {"through_message_id": reply["id"]})
        self.assertEqual(code, 200)
        self.assertEqual(data, {"ok": True, "feature_id": feature_id, "read_through_message_id": reply["id"],
                                "unread": False})
        self.assertEqual(self.request(path, {"through_message_id": reply["id"]}), (200, data))
        entry = next(e for e in self.request("/api/v1/first-mate/fleet")[1]["features"] if e["feature_id"] == feature_id)
        self.assertFalse(entry["unread"])
        self.assertEqual(self.request(path, {"through_message_id": "fmm_missing"})[0], 404)
        code, error = self.request(path, {"through_message_id": foreign["id"]})
        self.assertEqual(code, 409)
        self.assertFalse(error["ok"])
        for bad in ({}, {"through_message_id": reply["id"], "request_id": "read-1"}, {"through_message_id": 7},
                    {"through_message_id": ""}):
            self.assertEqual(self.request(path, bad)[0], 400, bad)
        self.assertEqual(self.request(path + "?force=1", {"through_message_id": reply["id"]})[0], 400)
        self.assertEqual(self.request("/api/v1/first-mate/features/fmf_missing/read",
                                      {"through_message_id": reply["id"]})[0], 404)
        self.assertEqual(self.wakes, wakes)
        self.assertTrue(self.store.board(feature_id, if_version=version)["unchanged"])

    def test_hud_sets_label_and_emoji_without_waking(self):
        feature_id = self.create()
        path = f"/api/v1/first-mate/features/{feature_id}/hud"
        version = self.store.board(feature_id)["version"]
        wakes = list(self.wakes)
        code, data = self.request(path, {"label": "Receipts", "emoji": "🧾"})
        self.assertEqual(code, 200)
        self.assertEqual(set(data), {"ok", "feature"})
        self.assertEqual(set(data["feature"]), ENTRY_FIELDS)
        self.assertEqual((data["feature"]["label"], data["feature"]["emoji"], data["feature"]["emoji_source"]),
                         ("Receipts", "🧾", "user"))
        code, data = self.request(path, {"emoji": None})
        self.assertEqual(code, 200)
        self.assertEqual((data["feature"]["label"], data["feature"]["emoji_source"]), ("Receipts", "default"))
        code, data = self.request(path, {"label": ""})
        self.assertEqual(data["feature"]["label"], "Receipt export")
        for bad in ({}, {"title": "Receipts"}, {"label": "Receipts", "request_id": "hud-1"}, {"label": 5},
                    {"label": "x" * 25}, {"emoji": "🧾" * 17}, {"emoji": "🧾 🚀"}):
            code, error = self.request(path, bad)
            self.assertEqual(code, 400, bad)
            self.assertFalse(error["ok"])
        self.assertEqual(self.request("/api/v1/first-mate/features/fmf_missing/hud", {"label": "Ghost"})[0], 404)
        self.assertEqual(self.wakes, wakes)
        self.assertTrue(self.store.board(feature_id, if_version=version)["unchanged"])


if __name__ == "__main__":
    unittest.main()
