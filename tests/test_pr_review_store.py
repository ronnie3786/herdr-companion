import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path
from herdr_harness.pr_review_store import PRReviewError, PRReviewStore

class PRReviewStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = PRReviewStore(Path(self.temp.name) / "pr-review.sqlite3")
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.close)

    def body(self, request_id='create'):
        return {'url':'https://github.com/example-owner/example-repo/pull/42','host':'github.com','owner':'example-owner','repo':'example-repo','number':42,'request_id':request_id}

    def test_receipt_and_archive_are_durable(self):
        review=self.store.create_review(self.body());self.assertEqual(review,self.store.create_review(self.body()))
        self.store.archive(review['id'],'archive');self.assertEqual(self.store.list_reviews(),[]);self.assertEqual(self.store.list_reviews('archived')[0]['id'],review['id'])
    def test_changed_receipt_conflicts(self):
        self.store.create_review(self.body())
        with self.assertRaises(PRReviewError) as raised:self.store.create_review(self.body('create')|{'number':43})
        self.assertEqual(raised.exception.code,'idempotency_conflict')

    def test_skill_state_obeys_newer_not_run_mark(self):
        review = self.store.create_review(self.body())
        self.store.update_review(review["id"], status="ready")
        run = self.store.create_run(review["id"], "ios-review-remote-pr", "run")
        self.store.update_run(review["id"], run["id"], state="finished", finished_at="2026-01-01T00:00:00Z")
        state = self.store.mark(review["id"], "ios-review-remote-pr", "not_run", "mark")
        self.assertEqual(state["state"], "not_run")
        self.assertTrue(state["mark"])

    def test_skill_state_is_ran_for_a_mark_without_finished_runs(self):
        review = self.store.create_review(self.body())
        state = self.store.mark(review["id"], "ios-review-remote-pr", "ran", "ran-mark")
        self.assertEqual(state["state"], "ran")
        self.assertEqual(state["run_count"], 0)

    def test_skill_state_prefers_a_newer_finished_run_over_an_old_not_run_mark(self):
        review = self.store.create_review(self.body())
        self.store.update_review(review["id"], status="ready")
        self.store.mark(review["id"], "ios-review-remote-pr", "not_run", "old-mark")
        self.store._db.execute("UPDATE prr_skill_marks SET marked_at=? WHERE review_id=?", ("2025-01-01T00:00:00Z", review["id"]))
        run = self.store.create_run(review["id"], "ios-review-remote-pr", "new-run")
        self.store.update_run(review["id"], run["id"], state="finished", finished_at="2026-01-01T00:00:00Z")
        state = next(item for item in self.store.skill_states(review["id"]) if item["id"] == "ios-review-remote-pr")
        self.assertEqual(state["state"], "ran")

    def test_rankings_and_viewed_validate_paths(self):
        review = self.store.create_review(self.body())
        self.store.upsert_files(review["id"], [{"path": "Sources/Garden.swift"}])
        files = self.store.set_rankings(review["id"], [{"path": "Sources/Garden.swift", "impact": "high", "reason": "Changes storage."}], "rank")
        self.assertEqual(files[0]["impact"], "high")
        viewed = self.store.set_viewed(review["id"], ["Sources/Garden.swift"], True, "viewed")
        self.assertTrue(viewed[0]["viewed"])
        with self.assertRaises(PRReviewError):
            self.store.set_rankings(review["id"], [{"path": "missing.swift", "impact": "low"}], "bad")

    def test_create_review_reuses_active_creates_after_archive_and_tracks_revision(self):
        first = self.store.create_review(self.body("first"))
        same = self.store.create_review(self.body("same-pr"))
        self.assertEqual(same["id"], first["id"])
        revision = self.store.get_review(first["id"], True)["revision"]
        changed = self.store.update_review(first["id"], title="Synthetic title")
        archived = self.store.archive(first["id"], "archive-again")
        self.assertEqual(changed["revision"], revision + 1)
        self.assertEqual(archived["revision"], revision + 2)
        second = self.store.create_review(self.body("new-after-archive"))
        self.assertNotEqual(second["id"], first["id"])
        self.assertEqual(set(self.store.snapshot(second["id"])), {"review", "files", "skills", "runs", "documents", "events"})

    def test_custom_skill_validation_and_disabling(self):
        with self.assertRaises(PRReviewError) as raised:
            self.store.disable_skill("ios-review-remote-pr", "disable-builtin")
        self.assertEqual(raised.exception.code, "invalid_request")
        for skill_id in ("ios-review-remote-pr", "Uppercase", "bad_symbol", ""):
            with self.subTest(skill_id=skill_id), self.assertRaises(PRReviewError) as raised:
                self.store.add_skill({"id": skill_id, "title": "Synthetic skill", "request_id": f"add-{skill_id}"})
            self.assertEqual(raised.exception.code, "invalid_request")
        skill = self.store.add_skill({"id": "synthetic-review", "title": "Synthetic skill", "request_id": "add-custom"})
        self.assertIn(skill["id"], [item["id"] for item in self.store.skills()])
        self.store.disable_skill(skill["id"], "disable-custom")
        self.assertNotIn(skill["id"], [item["id"] for item in self.store.skills()])
        restored = self.store.add_skill({"id": skill["id"], "title": "Restored synthetic skill", "kind": "review", "description": "", "command_template": "", "request_id": "restore-custom"})
        self.assertTrue(restored["enabled"])
        for key in ("kind", "description", "command_template"):
            with self.subTest(key=key), self.assertRaises(PRReviewError) as raised:
                self.store.add_skill({"id": "other-skill", "title": "Synthetic", key: 1, "request_id": "invalid-" + key})
            self.assertEqual(raised.exception.code, "invalid_request")

    def test_events_cursor_pagination_and_snapshot_event_tail(self):
        review = self.store.create_review(self.body())
        self.store.add_event(review["id"], "synthetic.first", "first")
        first = self.store.events(review["id"], after=0)
        self.assertEqual(first["cursor"], first["events"][-1]["sequence"])
        self.store.add_event(review["id"], "synthetic.later", "later")
        later = self.store.events(review["id"], after=first["cursor"])
        self.assertEqual([event["type"] for event in later["events"]], ["synthetic.later"])
        self.assertEqual(self.store.events(review["id"], after=later["cursor"])["events"], [])
        snapshot_events = self.store.snapshot(review["id"])["events"]
        self.assertLessEqual(len(snapshot_events), 100)
        self.assertEqual(snapshot_events[-1]["type"], "synthetic.later")

    def test_close_waits_for_the_shared_connection_lock(self):
        store = PRReviewStore(Path(self.temp.name) / 'closing.sqlite3')
        entered, release = threading.Event(), threading.Event()

        def hold_lock():
            with store._lock:
                entered.set()
                release.wait(timeout=5)

        holder = threading.Thread(target=hold_lock, name='store-lock-holder')
        holder.start()
        self.assertTrue(entered.wait(timeout=2), 'the lock holder did not acquire the connection lock')
        closer = threading.Thread(target=store.close, name='store-closer')
        closer.start()
        self.assertFalse(closer.join(timeout=0.5), 'close must wait for the shared connection lock')
        release.set()
        closer.join(timeout=2)
        holder.join(timeout=2)
        self.assertFalse(closer.is_alive(), 'close did not finish after the lock was released')
        try:
            store.close()
        except sqlite3.ProgrammingError:
            pass

if __name__ == '__main__': unittest.main()
