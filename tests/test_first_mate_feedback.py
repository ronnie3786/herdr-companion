"""Durable, private First Mate response feedback with exact provenance.

All fixtures are synthetic and use temporary on-disk databases so migration,
reopen, receipts, revisions, and provenance survive a real process boundary.
"""
from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from herdr_harness.first_mate_store import (
    FEEDBACK_CATEGORY_LIMIT,
    FirstMateError,
    FirstMateStore,
)

DEFAULT_IDS = ("too_long", "unnecessary_message", "incorrect_assumption")
DEFAULT_LABELS = (
    "Longer than it needed to be",
    "Unnecessary message",
    "Incorrect assumption",
)


class FirstMateFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "first-mate.sqlite3"
        self.store = FirstMateStore(self.path)
        self.addCleanup(lambda: self.store.close())
        self.feature = self.store.create_feature({
            "title": "Garden schedule",
            "goal": "Plan a garden watering feature",
            "cwd": "/tmp/synthetic-garden",
            "request_id": "feature-create",
        })
        self.other = self.store.create_feature({
            "title": "Garden lights",
            "goal": "Plan synthetic garden lighting",
            "cwd": "/tmp/synthetic-lights",
            "request_id": "feature-create-other",
        })

    def assert_code(self, code, callback):
        with self.assertRaises(FirstMateError) as error:
            callback()
        self.assertEqual(error.exception.code, code)
        return error.exception

    def body(self, rating="down", category_ids=None, comment="", expected_revision=0, request_id="rate-1"):
        return {
            "rating": rating,
            "category_ids": [] if category_ids is None else category_ids,
            "comment": comment,
            "expected_revision": expected_revision,
            "request_id": request_id,
        }

    def completed_reply(self, feature=None, *, owner="coordinator", session=None,
                        text="Synthetic completed response."):
        feature = feature or self.feature
        message = self.store.claim_message(feature["id"], owner)
        if session:
            self.store.bind_coordinator_session(
                feature["id"], owner, session, f"/tmp/synthetic-pi/{session}.jsonl")
        self.store.finish_message(message["id"], owner, reply=text, native_session_id=session)
        return next(
            item for item in self.store.snapshot(feature["id"])["messages"]
            if item["role"] == "assistant"
        )

    def completed_checkpoint(self, *, session="synthetic-coordinator", feature=None):
        feature = feature or self.feature
        message = self.store.claim_message(feature["id"], "coordinator")
        self.store.bind_coordinator_session(
            feature["id"], "coordinator", session, f"/tmp/synthetic-pi/{session}.jsonl")
        visit = self.store.start_visit(
            feature["id"], "plan", "Planning", "visit-1", 1, message["id"])
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Synthetic planner", "role": "planner",
            "prompt": "Plan the synthetic garden schedule", "request_id": "assignment-1",
        })
        claimed = self.store.claim_assignment(assignment["id"], "worker-owner")
        self.store.bind_session(
            assignment["id"], claimed["generation"], "worker-owner",
            "synthetic-worker-native", "/tmp/synthetic-pi/worker-native.jsonl", "run-1")
        self.store.record_outcome(
            assignment["id"], claimed["generation"], "synthetic-worker-native",
            claimed["input_revision"], "success", "Synthetic plan verified", "outcome-1")
        self.store.complete_visit(
            visit["id"], "The synthetic plan is complete", "Implement the plan", "complete-1",
            native_session_id=session)
        self.store.finish_message(message["id"], "coordinator")
        checkpoint = next(
            item for item in self.store.snapshot(feature["id"])["messages"]
            if item["role"] == "assistant" and item["metadata"].get("checkpoint")
        )
        return visit, checkpoint

    def test_default_categories_are_seeded_with_stable_ids_labels_and_reopen_cleanly(self):
        categories = self.store.list_feedback_categories()
        self.assertEqual([item["id"] for item in categories], list(DEFAULT_IDS))
        self.assertEqual([item["label"] for item in categories], list(DEFAULT_LABELS))
        self.store.close()
        reopened = FirstMateStore(self.path)
        self.addCleanup(reopened.close)
        self.assertEqual(
            [item["id"] for item in reopened.list_feedback_categories()], list(DEFAULT_IDS))
        self.assertEqual(
            [item["label"] for item in reopened.list_feedback_categories()], list(DEFAULT_LABELS))

    def test_existing_database_migrates_additively_without_rewriting_history(self):
        reply = self.completed_reply(text="Pre-migration synthetic response.")
        before = self.store.snapshot(self.feature["id"])
        # Simulate an older release that predates the feedback tables entirely.
        self.store._db.execute("DROP TABLE fm_feedback")
        self.store._db.execute("DROP TABLE fm_feedback_sources")
        self.store._db.execute("DROP TABLE fm_feedback_categories")
        self.store._db.execute("DELETE FROM fm_schema WHERE version=5")
        self.store.close()
        reopened = FirstMateStore(self.path)
        self.addCleanup(reopened.close)
        after = reopened.snapshot(self.feature["id"])
        self.assertEqual(after["feature"], before["feature"])
        self.assertEqual(after["messages"], before["messages"])
        self.assertEqual(
            [item["id"] for item in reopened.list_feedback_categories()], list(DEFAULT_IDS))
        record = reopened.rate_feedback(self.feature["id"], reply["id"], self.body(
            category_ids=["too_long"], comment="Legacy response", request_id="migrated-rate"))
        self.assertEqual(record["revision"], 1)
        self.assertEqual(record["provenance"]["source_kind"], "legacy")
        self.assertEqual(record["provenance"]["response_text"], "Pre-migration synthetic response.")
        self.assertEqual(record["provenance"]["session_provenance"], "unavailable")

    def test_custom_categories_are_reusable_deduplicated_and_persisted(self):
        created = self.store.create_feedback_category("  Too   verbose  ", "category-1")
        self.assertEqual(created["label"], "Too verbose")
        duplicate = self.store.create_feedback_category("too VERBOSE", "category-2")
        self.assertEqual(duplicate["id"], created["id"])
        replay = self.store.create_feedback_category("Too verbose", "category-1")
        self.assertEqual(replay, created)
        self.assert_code("idempotency_conflict", lambda: self.store.create_feedback_category(
            "Different label", "category-1"))
        self.store.close()
        reopened = FirstMateStore(self.path)
        self.addCleanup(reopened.close)
        categories = reopened.list_feedback_categories()
        self.assertEqual([item["id"] for item in categories][-1], created["id"])
        self.assertEqual(sum(1 for item in categories if item["label"] == "Too verbose"), 1)

    def test_category_labels_are_bounded_single_line_and_explicit(self):
        for invalid in ("", "   ", "line\nbreak", "carriage\rreturn", "x" * 81, 7, None):
            with self.subTest(label=invalid):
                self.assert_code("invalid_request", lambda value=invalid: self.store.create_feedback_category(
                    value, "category-invalid"))
        longest = self.store.create_feedback_category("y" * 80, "category-longest")
        self.assertEqual(longest["label"], "y" * 80)
        self.assert_code("invalid_request", lambda: self.store.create_feedback_category(
            "with\x00null", "category-null"))

    def test_category_limit_allows_existing_labels_but_rejects_new_ones(self):
        for index in range(FEEDBACK_CATEGORY_LIMIT - len(DEFAULT_IDS)):
            self.store.create_feedback_category(f"Synthetic reason {index}", f"category-{index}")
        self.assertEqual(len(self.store.list_feedback_categories()), FEEDBACK_CATEGORY_LIMIT)
        existing = self.store.create_feedback_category("Synthetic reason 0", "category-existing")
        self.assertEqual(existing["label"], "Synthetic reason 0")
        self.assert_code("feedback_category_limit", lambda: self.store.create_feedback_category(
            "One reason too many", "category-overflow"))

    def test_negative_feedback_round_trips_multiple_reasons_unicode_and_multiline(self):
        custom = self.store.create_feedback_category("Needs more evidence", "category-evidence")
        reply = self.completed_reply()
        comment = "Too long.\nSecond line — naïve ✨\n\n  trailing spaces preserved  "
        result = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            category_ids=["too_long", custom["id"]], comment=comment))
        self.assertEqual(result["rating"], "down")
        self.assertEqual(result["category_ids"], ["too_long", custom["id"]])
        self.assertEqual(result["comment"], comment)
        self.assertEqual(result["revision"], 1)
        self.assertEqual(result["provenance"]["response_text"], reply["text"])
        self.store.close()
        reopened = FirstMateStore(self.path)
        self.addCleanup(reopened.close)
        records = reopened.list_feedback(self.feature["id"])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["comment"], comment)
        self.assertEqual(records[0]["category_ids"], ["too_long", custom["id"]])
        self.assertEqual(records[0]["provenance"]["response_text"], reply["text"])

    def test_rating_receipts_revisions_clearing_and_delayed_edits(self):
        reply = self.completed_reply()
        first = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            category_ids=["unnecessary_message"], comment="Synthetic dislike", request_id="rate-edit"))
        self.assertEqual(first["revision"], 1)
        self.assertEqual(
            self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
                category_ids=["unnecessary_message"], comment="Synthetic dislike", request_id="rate-edit")),
            first,
        )
        self.assert_code("idempotency_conflict", lambda: self.store.rate_feedback(
            self.feature["id"], reply["id"], self.body(
                category_ids=["too_long"], comment="Changed", request_id="rate-edit")))
        edited = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            category_ids=["incorrect_assumption"], comment="Edited reason",
            expected_revision=1, request_id="rate-edit-2"))
        self.assertEqual(edited["revision"], 2)
        self.assert_code("stale_feedback_revision", lambda: self.store.rate_feedback(
            self.feature["id"], reply["id"], self.body(
                category_ids=["too_long"], comment="Delayed", expected_revision=1, request_id="delayed-1")))
        cleared = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating=None, expected_revision=2, request_id="clear-1"))
        self.assertIsNone(cleared["rating"])
        self.assertEqual(cleared["revision"], 3)
        self.assertEqual(cleared["category_ids"], [])
        self.assertEqual(cleared["comment"], "")
        # Clearing is a revisioned record, never a deletion or a historical erasure.
        self.assert_code("stale_feedback_revision", lambda: self.store.rate_feedback(
            self.feature["id"], reply["id"], self.body(
                category_ids=["too_long"], comment="Older delayed save",
                expected_revision=2, request_id="delayed-2")))
        positive = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="up", expected_revision=3, request_id="rate-up"))
        self.assertEqual(positive["rating"], "up")
        self.assertEqual(positive["revision"], 4)
        self.assert_code("invalid_request", lambda: self.store.rate_feedback(
            self.feature["id"], reply["id"], self.body(
                rating="up", category_ids=["too_long"], expected_revision=4, request_id="rate-bad-up")))
        self.assertEqual(len(self.store.list_feedback(self.feature["id"])), 1)

    def test_rating_validates_fields_bounds_and_category_existence(self):
        reply = self.completed_reply()
        invalid_bodies = [
            {"rating": "yes", "category_ids": [], "comment": "", "expected_revision": 0, "request_id": "bad-1"},
            {"rating": True, "category_ids": [], "comment": "", "expected_revision": 0, "request_id": "bad-2"},
            {"rating": "down", "category_ids": "too_long", "comment": "", "expected_revision": 0, "request_id": "bad-3"},
            {"rating": "down", "category_ids": ["too_long", "too_long"], "comment": "", "expected_revision": 0, "request_id": "bad-4"},
            {"rating": "down", "category_ids": [f"missing-{index}" for index in range(21)], "comment": "", "expected_revision": 0, "request_id": "bad-5"},
            {"rating": "down", "category_ids": ["missing"], "comment": "", "expected_revision": 0, "request_id": "bad-6"},
            {"rating": "down", "category_ids": [], "comment": "x" * 4001, "expected_revision": 0, "request_id": "bad-7"},
            {"rating": "down", "category_ids": [], "comment": "null\x00byte", "expected_revision": 0, "request_id": "bad-8"},
            {"rating": "down", "category_ids": [], "comment": "", "expected_revision": -1, "request_id": "bad-9"},
            {"rating": "down", "category_ids": [], "comment": "", "expected_revision": True, "request_id": "bad-10"},
            {"rating": "down", "category_ids": [], "comment": "", "expected_revision": 0},
            {"rating": "down", "category_ids": [], "comment": "", "expected_revision": 0, "request_id": "bad-11", "extra": 1},
        ]
        for payload in invalid_bodies:
            with self.subTest(payload=payload):
                self.assert_code("invalid_request", lambda value=payload: self.store.rate_feedback(
                    self.feature["id"], reply["id"], value))
        self.assert_code("invalid_request", lambda: self.store.rate_feedback(
            self.feature["id"], reply["id"], self.body(rating="up", category_ids=[], comment="not empty",
                                                       request_id="bad-up-comment")))
        self.assert_code("invalid_request", lambda: self.store.rate_feedback(
            self.feature["id"], reply["id"], self.body(rating=None, category_ids=["too_long"],
                                                       request_id="bad-clear")))
        self.assert_code("not_found", lambda: self.store.rate_feedback(
            self.feature["id"], "fmm_missing", self.body(request_id="missing-message")))

    def test_only_completed_assistant_responses_are_eligible_across_features(self):
        user = self.store.append_human_message(self.feature["id"], "Human direction", "human-1")
        system = self.store.queue_system_message(self.feature["id"], "Background update", "system-1")
        for message in (user, system):
            with self.subTest(role=message["role"]):
                self.assert_code("feedback_ineligible", lambda value=message: self.store.rate_feedback(
                    self.feature["id"], value["id"], self.body(request_id="ineligible-" + value["id"])))
        reply = self.completed_reply()
        other_reply = self.completed_reply(
            self.other, owner="other-coordinator", text=reply["text"])
        self.assertNotEqual(reply["id"], other_reply["id"])
        self.assert_code("feedback_scope_mismatch", lambda: self.store.rate_feedback(
            self.feature["id"], other_reply["id"], self.body(request_id="cross-feature")))
        self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="up", request_id="own-message"))
        self.store.rate_feedback(self.other["id"], other_reply["id"], self.body(
            rating="up", request_id="other-message"))
        # Identical response text in different features never merges provenance.
        self.assertEqual(
            [record["message_id"] for record in self.store.list_feedback(self.feature["id"])], [reply["id"]])
        self.assertEqual(
            [record["message_id"] for record in self.store.list_feedback(self.other["id"])], [other_reply["id"]])
        self.assertEqual(
            self.store.list_feedback(self.other["id"])[0]["provenance"]["response_text"], reply["text"])

    def test_reply_provenance_records_exact_source_and_survives_rotation(self):
        feature = self.feature
        message = self.store.claim_message(feature["id"], "coordinator")
        self.store.bind_coordinator_session(
            feature["id"], "coordinator", "synthetic-session-a", "/tmp/synthetic-pi/a.jsonl")
        self.store.finish_message(
            message["id"], "coordinator", reply="Synthetic reply from session A.",
            native_session_id="synthetic-session-a")
        reply = next(
            item for item in self.store.snapshot(feature["id"])["messages"]
            if item["role"] == "assistant")
        self.store.rotate_coordinator_session(
            feature["id"], "synthetic-session-a", "rotate-1", verified_stopped=True)
        # A rotated context attaches by claiming newly queued human direction; the
        # retired session must never lend its identity to the new coordinator.
        self.store.append_human_message(
            feature["id"], "Synthetic follow-up direction", "rotate-direction")
        successor = self.store.claim_message(feature["id"], "coordinator")
        self.assertIsNotNone(successor)
        self.store.bind_coordinator_session(
            feature["id"], "coordinator", "synthetic-session-b", "/tmp/synthetic-pi/b.jsonl")
        record = self.store.rate_feedback(feature["id"], reply["id"], self.body(request_id="rate-after-rotation"))
        provenance = record["provenance"]
        self.assertEqual(provenance["response_text"], "Synthetic reply from session A.")
        self.assertEqual(provenance["response_created_at"], reply["created_at"])
        self.assertEqual(provenance["source_kind"], "reply")
        self.assertEqual(provenance["in_reply_to"], message["id"])
        self.assertIsNone(provenance["visit_id"])
        self.assertEqual(provenance["feature_revision"], 1)
        self.assertEqual(provenance["coordinator_session_id"], "synthetic-session-a")
        self.assertEqual(provenance["session_provenance"], "verified")

    def test_checkpoint_provenance_records_visit_revision_and_verified_session(self):
        visit, checkpoint = self.completed_checkpoint()
        record = self.store.rate_feedback(
            self.feature["id"], checkpoint["id"], self.body(
                category_ids=["too_long"], comment="The checkpoint was too long",
                request_id="rate-checkpoint"))
        provenance = record["provenance"]
        self.assertEqual(provenance["source_kind"], "checkpoint")
        self.assertEqual(provenance["visit_id"], visit["id"])
        self.assertEqual(provenance["feature_revision"], visit["revision"])
        self.assertIsNone(provenance["in_reply_to"])
        self.assertEqual(provenance["coordinator_session_id"], "synthetic-coordinator")
        self.assertEqual(provenance["session_provenance"], "verified")
        self.assertEqual(provenance["response_text"], checkpoint["text"])

    def test_missing_or_foreign_session_identity_is_not_invented(self):
        reply = self.completed_reply(text="Response without runtime session identity.")
        record = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="up", request_id="unavailable-session"))
        self.assertIsNone(record["provenance"]["coordinator_session_id"])
        self.assertEqual(record["provenance"]["session_provenance"], "unavailable")
        self.store.append_human_message(
            self.feature["id"], "Synthetic follow-up direction", "follow-up-direction")
        message = self.store.claim_message(self.feature["id"], "coordinator")
        self.assertIsNotNone(message)
        self.assert_code("session_mismatch", lambda: self.store.finish_message(
            message["id"], "coordinator", reply="Invalid identity.", native_session_id="synthetic-unknown"))
        visit = self.store.start_visit(
            self.feature["id"], "plan", "Planning", "visit-foreign", 1, message["id"])
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Synthetic worker", "role": "planner", "prompt": "Plan",
            "request_id": "assignment-foreign",
        })
        claimed = self.store.claim_assignment(assignment["id"], "worker-owner")
        self.store.bind_session(
            assignment["id"], claimed["generation"], "worker-owner",
            "synthetic-worker-session", "/tmp/synthetic-pi/worker-foreign.jsonl", "run-foreign")
        # A worker session must never be presented as the coordinator source.
        self.assert_code("session_mismatch", lambda: self.store.finish_message(
            message["id"], "coordinator", reply="Worker identity cannot own a reply.",
            native_session_id="synthetic-worker-session"))
        self.assertEqual(
            [item for item in self.store.snapshot(self.feature["id"])["messages"]
             if item["role"] == "assistant" and item.get("metadata", {}).get("in_reply_to") == message["id"]],
            [])

    def test_legacy_messages_keep_explicit_unavailable_provenance(self):
        reply = self.completed_reply(text="Legacy synthetic response.")
        # Simulate a message stored before this release: no frozen source row.
        self.store._db.execute(
            "DELETE FROM fm_feedback_sources WHERE message_id=?", (reply["id"],))
        record = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="down", category_ids=["too_long"], comment="Legacy response",
            request_id="legacy-rate"))
        provenance = record["provenance"]
        self.assertEqual(provenance["source_kind"], "legacy")
        self.assertEqual(provenance["response_text"], "Legacy synthetic response.")
        self.assertEqual(provenance["response_created_at"], reply["created_at"])
        self.assertIsNone(provenance["coordinator_session_id"])
        self.assertEqual(provenance["session_provenance"], "unavailable")

    def test_archived_and_closed_features_remain_rateable(self):
        reply = self.completed_reply()
        self.store.set_archived(self.feature["id"], True, {"request_id": "archive", "reason": "duplicate"})
        archived = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="down", category_ids=["unnecessary_message"], request_id="rate-archived"))
        self.assertEqual(archived["rating"], "down")
        self.store.set_archived(self.feature["id"], False, {"request_id": "unarchive"})
        self.store.feature_action(self.feature["id"], "complete", "close")
        closed = self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="up", expected_revision=1, request_id="rate-closed"))
        self.assertEqual(closed["rating"], "up")
        self.assertEqual(self.store.get_feature(self.feature["id"])["status"], "completed")

    def test_recording_feedback_does_not_touch_messages_events_state_or_receipts(self):
        reply = self.completed_reply()
        before = self.store.snapshot(self.feature["id"])
        pending = self.store.pending_messages(self.feature["id"])
        self.store.rate_feedback(self.feature["id"], reply["id"], self.body(
            rating="down", category_ids=["incorrect_assumption"], comment="Synthetic",
            request_id="no-side-effect"))
        after = self.store.snapshot(self.feature["id"])
        self.assertEqual(after["feature"], before["feature"])
        self.assertEqual(after["messages"], before["messages"])
        self.assertEqual(after["events"], before["events"])
        self.assertEqual(after["visits"], before["visits"])
        self.assertEqual(after["assignments"], before["assignments"])
        self.assertEqual(self.store.pending_messages(self.feature["id"]), pending)
        receipts = self.store._db.execute(
            "SELECT COUNT(*) FROM fm_receipts WHERE scope LIKE 'feedback:%'").fetchone()[0]
        self.assertEqual(receipts, 1)

    def test_feedback_uses_private_database_files(self):
        reply = self.completed_reply()
        self.store.rate_feedback(self.feature["id"], reply["id"], self.body(request_id="private"))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        connection = sqlite3.connect(self.path)
        try:
            rows = connection.execute("SELECT rating,category_ids_json,comment FROM fm_feedback").fetchall()
        finally:
            connection.close()
        self.assertEqual(rows, [("down", "[]", "")])


if __name__ == "__main__":
    unittest.main()
