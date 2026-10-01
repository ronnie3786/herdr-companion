"""Synthetic evidence and guide contract tests, without a UI or remote provider."""
import copy
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.pr_review_diff import parse_unified_diff
from herdr_harness.pr_review_guide import ReviewContextService, report_sections, mentioned_paths, validate_explanation
from herdr_harness.pr_review_runtime import PRReviewRuntime
from herdr_harness.pr_review_store import PRReviewStore, PRReviewError
from tests.test_pr_review_runtime import FakeService, FakeRunner

PATCH = """diff --git a/Sources/Catalog/Cache.swift b/Sources/Catalog/Cache.swift
--- a/Sources/Catalog/Cache.swift
+++ b/Sources/Catalog/Cache.swift
@@ -1,2 +1,3 @@
 keep
-old
+guard
+finish
"""


class GuideEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = PRReviewStore(self.root / "state.db")
        self.runtime = PRReviewRuntime(FakeService(), self.store, environ={}, runtime_root=self.root / "runtime", runner=FakeRunner())
        review = self.store.create_review({"request_id": "create", "url": "https://github.com/example/garden/pull/1", "host": "github.com", "owner": "example", "repo": "garden", "number": 1})
        self.review_id = review["id"]
        self.store.update_review(self.review_id, status="ready", title="Cache garden", body="Keep cancelled updates from publishing.", base_sha="a" * 40, head_sha="b" * 40, merge_base_sha="a" * 40, checkout_path=str(self.root))
        self.files = [{"path": "Sources/Catalog/Cache.swift", "status": "modified"}, {"path": "Sources/Admin/Cache.swift", "status": "modified"}]
        self.store.upsert_files(self.review_id, self.files)
        revision = self.runtime._revision_directory(self.review_id, "a" * 40, "b" * 40, "a" * 40)
        revision.mkdir(parents=True)
        (revision / "diff.json").write_text(json.dumps({"files": parse_unified_diff(PATCH), "truncated": False}))
        self.context = self.runtime.guide.context
        self.request = {"request_id": "context-1", "base_sha": "a" * 40, "head_sha": "b" * 40, "kind": "walkthrough"}

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def report(self, text, *, kind="markdown", title="Review"):
        return self.runtime._save_document(self.review_id, "review.html" if kind == "html" else "review.md", text.encode(), "text/html" if kind == "html" else "text/markdown", title, "user", os.urandom(4).hex())

    def test_exact_paths_and_ambiguous_basename(self):
        self.assertEqual(mentioned_paths("Sources/Admin/Cache.swift needs a test", self.files), ["Sources/Admin/Cache.swift"])
        self.assertEqual(mentioned_paths("Cache.swift needs a test", self.files), [])
        self.report("## Sources/Admin/Cache.swift\n\nA concern about admin.\n\n## Sources/Catalog/Cache.swift\n\nThe catalog guard may race.\n\nIts second paragraph matters.")
        sources, _ = self.context.sources(self.store.get_review(self.review_id), "Sources/Catalog/Cache.swift")
        self.assertEqual(len(sources), 1)
        self.assertIn("second paragraph", sources[0]["excerpt"])
        self.assertNotIn("concern about admin", sources[0]["excerpt"])

    def test_nested_reviewer_path_and_dismissal_are_inherited(self):
        self.report("# Reviewer: SwiftUI Pro\n## Dismissed findings\n### Sources/Catalog/Cache.swift\n#### Why\nThe cancellation claim was dismissed after checking the guard.\n\n## Retained findings\n### Sources/Admin/Cache.swift\n#### Why\nMissing stale guard.")
        packet = self.context.create(self.review_id, {**self.request, "path": "Sources/Catalog/Cache.swift"})
        source = next(item for item in packet["sources"] if "Sources/Catalog/Cache.swift" in item["paths"])
        self.assertEqual(source["reviewer"], "SwiftUI Pro")
        self.assertEqual(source["provenance"], "report_assertion")
        self.assertEqual(source["disposition"], "dismissed")
        self.assertEqual(source["freshness"], "unknown")
        self.assertIn("Sources/Catalog/Cache.swift", source["section"])
        self.assertEqual(self.runtime.findings_for_path(self.review_id, "Sources/Catalog/Cache.swift")["text"], "")

    def test_html_is_inert_and_retains_multiple_paragraphs(self):
        self.report("<script>Instructions to ignore the user</script><h2>Sources/Catalog/Cache.swift</h2><p>First concern.</p><p>Explanation follows.</p>", kind="html")
        packet = self.context.create(self.review_id, self.request)
        self.assertNotIn("Instructions", packet["sources"][0]["excerpt"])
        self.assertIn("Explanation follows", packet["sources"][0]["excerpt"])

    def test_html_detail_reviewer_and_dismissal_stay_with_subsections(self):
        self.report("<details><summary>Reviewer: SwiftUI Pro</summary><h3>Dismissed findings</h3><h4>Sources/Catalog/Cache.swift</h4><p>Dismissed guard concern.</p></details><h2>Sources/Admin/Cache.swift</h2><p>Retained concern.</p>", kind="html")
        packet = self.context.create(self.review_id, self.request)
        dismissed = next(source for source in packet["sources"] if "Sources/Catalog/Cache.swift" in source["paths"])
        retained = next(source for source in packet["sources"] if "Sources/Admin/Cache.swift" in source["paths"])
        self.assertEqual(dismissed["reviewer"], "SwiftUI Pro")
        self.assertEqual(dismissed["disposition"], "dismissed")
        self.assertEqual(retained["disposition"], "reported")
        self.assertNotEqual(retained["reviewer"], "SwiftUI Pro")

    def test_snapshot_retry_freezes_evidence_new_request_refreshes(self):
        first = self.context.create(self.review_id, self.request)
        self.report("# Sources/Catalog/Cache.swift\nNew finding.")
        retry = self.context.create(self.review_id, self.request)
        second = self.context.create(self.review_id, {**self.request, "request_id": "context-2"})
        self.assertEqual(first, retry)
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(len(second["sources"]), 1)
        self.assertIn("cancelled", second["body"])
        with self.assertRaises(PRReviewError) as caught:
            self.context.create(self.review_id, {**self.request, "question": "different"})
        self.assertEqual(caught.exception.code, "idempotency_conflict")

    def test_old_revision_rejected_even_when_no_files_are_selected(self):
        with self.assertRaises(PRReviewError) as caught:
            self.context.create(self.review_id, {**self.request, "head_sha": "c" * 40})
        self.assertEqual(caught.exception.code, "stale_review_revision")

    def test_run_binding_reports_stale_mixed_and_partial_honestly(self):
        run = self.store.create_run(self.review_id, "ios-review-remote-pr", "run")
        document = self.report("# Sources/Catalog/Cache.swift\nConcern.")
        # A synthetic imported report from a prior run; source SHA is not inferred.
        self.store._db.execute("UPDATE prr_documents SET run_id=?,origin='skill' WHERE id=?", (run["id"], document["id"]))
        self.store.associate_document(self.review_id, document["id"], run["id"])
        partial = self.context.create(self.review_id, self.request)
        self.assertEqual(partial["sources"], [])
        self.assertEqual(partial["coverage"]["partial_documents"], 1)
        self.store.update_run(self.review_id, run["id"], state="finished")
        self.store.record_run_revision(run["id"], base_sha="a" * 40, head_sha="c" * 40, start_head="c" * 40, finish_head="c" * 40)
        stale = self.context.create(self.review_id, {**self.request, "request_id": "stale"})
        self.assertEqual(stale["sources"][0]["freshness"], "stale")
        self.assertEqual(stale["sources"][0]["reviewer"], "Consolidated review")
        self.store.record_run_revision(run["id"], finish_head="d" * 40)
        mixed = self.context.create(self.review_id, {**self.request, "request_id": "mixed"})
        self.assertEqual(mixed["sources"][0]["freshness"], "mixed")

    def test_packet_budget_preserves_exact_selection_and_question(self):
        files = [{"path": f"Source/File{i}.swift", "status": "modified"} for i in range(100)]
        self.store.upsert_files(self.review_id, files)
        for i in range(20): self.report(f"# Reviewer: Agent{i}\n## Source/File{i}.swift\n" + "é" * 2000)
        request = {**self.request, "question": "q" * 6000, "selection": {"text": "é" * 6000, "spans": []}}
        packet = self.context.create(self.review_id, request)
        self.assertEqual(packet["selection"]["text"], request["selection"]["text"])
        self.assertEqual(packet["question"], request["question"])
        self.assertLess(len(json.dumps(packet, ensure_ascii=False).encode()), 64 * 1024)
        self.assertGreater(packet["coverage"]["omitted_files"], 0)
        self.assertGreater(packet["coverage"]["omitted_sources"], 0)

    def test_output_validation_drops_invented_locations_sources_and_repeated_phrases(self):
        self.report("# Sources/Catalog/Cache.swift\nReal finding.")
        snapshot = self.context.load(self.review_id, self.context.create(self.review_id, self.request)["id"])
        source_id = snapshot["sources"][0]["id"]
        drawing = {"shape": "circle", "targets": [{"path": self.files[0]["path"], "side": "after", "startLine": 2, "endLine": 3}], "onPhrase": "this guard", "drawSeconds": 0.7}
        value = {"chapters": [{"title": "Guard", "segments": [{"path": self.files[0]["path"], "side": "after", "start_line": 2, "end_line": 3, "spoken_text": "Look at this guard before publishing.", "source_refs": [source_id, "invented"], "drawings": [drawing]}]}], "assessments": [{"source_id": source_id, "status": "reproduced_by_recorded_test", "explanation": "I did not actually run it"}]}
        normalized = validate_explanation(value, snapshot, "answer")
        segment = normalized["chapters"][0]["segments"][0]
        self.assertEqual(segment["source_refs"], [source_id])
        self.assertEqual(len(segment["drawings"]), 1)
        self.assertEqual(normalized["assessments"], [])
        value["chapters"][0]["segments"][0]["spoken_text"] = "this guard and this guard"
        self.assertEqual(validate_explanation(value, snapshot, "answer")["chapters"][0]["segments"][0]["drawings"], [])
        value["chapters"][0]["segments"][0]["start_line"] = 99
        self.assertNotIn("path", validate_explanation(value, snapshot, "answer")["chapters"][0]["segments"][0])

    def test_multiple_document_associations_survive_same_content(self):
        doc = self.report("# Sources/Catalog/Cache.swift\nShared concern.")
        first = self.store.create_run(self.review_id, "ios-review-remote-pr", "first")
        second = self.store.create_run(self.review_id, "comprehensive-pr-review", "second")
        self.store.associate_document(self.review_id, doc["id"], first["id"])
        self.store.associate_document(self.review_id, doc["id"], second["id"])
        self.assertEqual(len(self.store.document_sources(self.review_id, doc["id"])), 2)

    def test_walkthrough_and_broad_answers_include_other_files(self):
        self.report("# Reviewer: Synthetic\n## Sources/Catalog/Cache.swift\nCatalog concern.\n## Sources/Admin/Cache.swift\nAdmin concern.")
        for kind in ("walkthrough", "answer"):
            packet = self.context.create(self.review_id, {**self.request, "request_id": kind, "kind": kind, "path": "Sources/Catalog/Cache.swift", "question": "What should I worry about in this PR?"})
            self.assertEqual({path for source in packet["sources"] for path in source["paths"]}, {item["path"] for item in self.files})

    def test_partial_scan_cannot_become_final_just_because_run_finishes(self):
        doc = self.report("# Sources/Catalog/Cache.swift\nHalf-written report.")
        run = self.store.create_run(self.review_id, "ios-review-remote-pr", "partial-run")
        self.store._db.execute("UPDATE prr_documents SET run_id=?,origin='skill' WHERE id=?", (run["id"], doc["id"]))
        self.store.associate_document(self.review_id, doc["id"], run["id"], "partial_shared_output_scan")
        self.store.update_run(self.review_id, run["id"], state="finished")
        self.assertEqual(self.context.create(self.review_id, self.request)["sources"], [])
        self.store.associate_document(self.review_id, doc["id"], run["id"], "shared_output_scan")
        self.assertEqual(len(self.context.create(self.review_id, {**self.request, "request_id": "final"})["sources"]), 1)

    def test_failed_first_import_does_not_hide_identical_successful_rerun(self):
        doc = self.report("# Sources/Catalog/Cache.swift\nConcern carried to the final report.")
        first = self.store.create_run(self.review_id, "ios-review-remote-pr", "failed-first")
        second = self.store.create_run(self.review_id, "ios-review-remote-pr", "successful-second")
        self.store._db.execute("UPDATE prr_documents SET run_id=?,origin='skill' WHERE id=?", (first["id"], doc["id"]))
        self.store.associate_document(self.review_id, doc["id"], first["id"], "partial_shared_output_scan")
        self.store.associate_document(self.review_id, doc["id"], second["id"], "shared_output_scan")
        self.store.update_run(self.review_id, first["id"], state="failed")
        self.store.update_run(self.review_id, second["id"], state="finished")
        self.store.record_run_revision(second["id"], base_sha="a" * 40, head_sha="b" * 40, start_head="b" * 40, finish_head="b" * 40, start_clean=True, finish_clean=True)
        packet = self.context.create(self.review_id, self.request)
        self.assertEqual(len(packet["sources"]), 1)
        source = packet["sources"][0]
        self.assertEqual(source["run_id"], second["id"])
        self.assertEqual(source["freshness"], "current")
        self.assertEqual({item["state"] for item in source["source_associations"]}, {"failed", "finished"})

    def test_identical_report_keeps_old_revision_and_uses_current_finalized_association(self):
        doc = self.report("# Sources/Catalog/Cache.swift\nThe same report at two revisions.")
        old = self.store.create_run(self.review_id, "ios-review-remote-pr", "old-run")
        current = self.store.create_run(self.review_id, "ios-review-remote-pr", "current-run")
        self.store._db.execute("UPDATE prr_documents SET run_id=?,origin='skill' WHERE id=?", (old["id"], doc["id"]))
        for run, sha in ((old, "c" * 40), (current, "b" * 40)):
            self.store.update_run(self.review_id, run["id"], state="finished")
            self.store.associate_document(self.review_id, doc["id"], run["id"], "shared_output_scan")
            self.store.record_run_revision(run["id"], base_sha="a" * 40, head_sha=sha, start_head=sha, finish_head=sha, start_clean=True, finish_clean=True)
        source = self.context.create(self.review_id, self.request)["sources"][0]
        self.assertEqual(source["run_id"], current["id"])
        self.assertEqual(source["head_sha"], "b" * 40)
        self.assertEqual(source["freshness"], "current")
        self.assertEqual({item["freshness"] for item in source["source_associations"]}, {"current", "stale"})

    def test_live_job_contract_and_retry_use_one_existing_agent_run(self):
        response = {"chapters": [{"title": "Inspect the guard", "segments": [{"spoken_text": "Read the guard before the mutation.", "path": self.files[0]["path"], "side": "after", "start_line": 2, "end_line": 3}]}]}
        class Manager:
            calls = []
            def start(inner, **kwargs):
                inner.calls.append(kwargs)
                return {"run": {"id": "agr_123456789abc"}}
            def get(inner, run_id):
                return {"run": {"id": run_id, "status": "completed", "response": json.dumps(response)}}
        manager = Manager()
        self.runtime.service.agent_runs = manager
        self.context.read_view = lambda review: self.root
        guide = self.runtime.guide.start(self.review_id, self.request)
        for _ in range(100):
            guide = self.runtime.guide.get(self.review_id, guide["id"])
            if guide["state"] != "running": break
            time.sleep(.01)
        self.assertEqual(guide["state"], "finished")
        self.assertEqual(len(guide["chapters"]), 1)
        self.assertEqual(self.runtime.guide.start(self.review_id, self.request), guide)
        self.assertEqual(len(manager.calls), 1)
        self.assertEqual(manager.calls[0]["_assistant"]["profile"], "pr-review-guide-v1")
        self.assertIn("untrusted", manager.calls[0]["prompt"].lower())
        self.assertEqual(manager.calls[0]["cwd"], str(self.root))

    def background_manager(self, status="running"):
        response = {"chapters": [{"title": "Inspect the guard", "segments": [{"spoken_text": "Read the guard before the mutation.", "path": self.files[0]["path"], "side": "after", "start_line": 2, "end_line": 3}]}]}
        class Manager:
            def __init__(inner):
                inner.status = status
                inner.cancelled = []
            def start(inner, **kwargs):
                return {"run": {"id": "agr_123456789abc"}}
            def get(inner, run_id):
                return {"run": {"id": run_id, "status": inner.status, "response": json.dumps(response)}}
            def cancel(inner, run_id):
                inner.cancelled.append(run_id)
                inner.status = "cancelled"
        manager = Manager()
        self.runtime.service.agent_runs = manager
        self.runtime.service.walkthrough_events = []
        self.runtime.service.pr_review_walkthrough_changed = self.runtime.service.walkthrough_events.append
        self.context.read_view = lambda review: self.root
        return manager

    def launched(self, guide):
        for _ in range(200):
            record = json.loads(self.runtime.guide._path(self.review_id, guide["id"]).read_text())
            if record.get("run_id") or record["state"] != "running": return record
            time.sleep(.01)
        self.fail("The walkthrough did not launch")

    def test_walkthrough_finishes_without_a_watching_client_and_alerts_once(self):
        manager = self.background_manager()
        guide = self.runtime.guide.start(self.review_id, self.request)
        self.launched(guide)
        self.assertEqual(self.store.get_review(self.review_id)["walkthrough"]["state"], "running")
        self.assertFalse(self.store.get_review(self.review_id)["walkthrough"]["needs_attention"])
        self.runtime.guide.reconcile()
        self.assertEqual(self.runtime.service.walkthrough_events, [])
        manager.status = "completed"
        self.runtime.guide.reconcile()
        self.runtime.guide.reconcile()
        summary = self.store.get_review(self.review_id)["walkthrough"]
        self.assertEqual((summary["id"], summary["state"], summary["chapter_count"]), (guide["id"], "finished", 1))
        self.assertTrue(summary["needs_attention"])
        self.assertIsNotNone(summary["finished_at"])
        events = self.runtime.service.walkthrough_events
        self.assertEqual([(event["guide_id"], event["state"], event["title"], event["number"]) for event in events], [(guide["id"], "finished", "Cache garden", 1)])
        # A late client poll returns the saved result without alerting again.
        self.assertEqual(self.runtime.guide.get(self.review_id, guide["id"])["state"], "finished")
        self.assertEqual(len(events), 1)
        self.assertFalse(self.runtime.guide.mark_seen(self.review_id, guide["id"])["needs_attention"])
        self.assertFalse(self.store.get_review(self.review_id)["walkthrough"]["needs_attention"])
        self.assertIn(self.review_id, self.runtime.service.changed)

    def test_failed_walkthrough_alerts_and_answers_are_not_saved_walkthroughs(self):
        manager = self.background_manager(status="failed")
        answer = self.runtime.guide.start(self.review_id, {**self.request, "request_id": "answer", "kind": "answer", "question": "Why?"})
        self.launched(answer)
        self.assertEqual(self.runtime.guide.get(self.review_id, answer["id"])["state"], "failed")
        self.assertEqual(self.store.walkthroughs(self.review_id), [])
        self.assertIsNone(self.store.get_review(self.review_id)["walkthrough"])
        guide = self.runtime.guide.start(self.review_id, self.request)
        self.launched(guide)
        self.runtime.guide.reconcile()
        self.assertEqual(self.store.get_review(self.review_id)["walkthrough"]["state"], "failed")
        self.assertTrue(self.store.get_review(self.review_id)["walkthrough"]["needs_attention"])
        self.assertEqual([event["state"] for event in self.runtime.service.walkthrough_events], ["failed"])
        self.assertEqual(manager.cancelled, [])

    def test_missing_walkthrough_record_cannot_spin_forever(self):
        self.background_manager()
        guide = self.runtime.guide.start(self.review_id, self.request)
        self.launched(guide)
        self.runtime.guide._path(self.review_id, guide["id"]).unlink()
        self.runtime.guide.reconcile()
        self.assertEqual(self.store.walkthroughs(self.review_id)[0]["state"], "failed")

    def test_archiving_discards_walkthroughs_and_cancels_running_work(self):
        manager = self.background_manager()
        finished = self.runtime.guide.start(self.review_id, self.request)
        self.launched(finished)
        manager.status = "completed"
        self.runtime.guide.reconcile()
        manager.status = "running"
        running = self.runtime.guide.start(self.review_id, {**self.request, "request_id": "second"})
        self.launched(running)
        review = self.runtime.archive(self.review_id, "archive")
        self.assertIsNotNone(review["archived_at"])
        self.assertIsNone(review["walkthrough"])
        self.assertEqual(manager.cancelled, ["agr_123456789abc"])
        self.assertEqual(self.store.walkthroughs(self.review_id), [])
        directory = self.runtime._review_dir(self.review_id)
        self.assertFalse((directory / "guides").exists())
        self.assertFalse((directory / "guide-contexts").exists())
        with self.assertRaises(PRReviewError) as caught:
            self.runtime.guide.get(self.review_id, finished["id"])
        self.assertEqual(caught.exception.code, "not_found")
        self.runtime.guide.reconcile()
        self.assertEqual(self.store.walkthroughs(self.review_id), [])
        self.runtime.archive(self.review_id, "unarchive", False)
        self.assertIsNone(self.store.get_review(self.review_id)["walkthrough"])

    def test_pinned_source_uses_commit_excludes_symlinks_and_survives_checkout_changes(self):
        repo = self.root / "git-source"
        repo.mkdir()
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()
        git("init")
        git("config", "user.email", "synthetic@example.invalid")
        git("config", "user.name", "Synthetic")
        (repo / "readme.txt").write_text("committed")
        (repo / "outside").symlink_to("/tmp")
        git("add", ".")
        git("commit", "-m", "Synthetic base")
        sha = git("rev-parse", "HEAD")
        (repo / "readme.txt").write_text("uncommitted")
        self.runtime.runner = subprocess.run
        review = self.store.update_review(self.review_id, head_sha=sha, checkout_path=str(repo))
        pinned = self.context.read_view(review)
        self.assertEqual((pinned / "readme.txt").read_text(), "committed")
        self.assertFalse((pinned / "outside").exists())
        git("add", "readme.txt")
        git("commit", "-m", "New revision")
        self.assertEqual(self.context.read_view(review), pinned)
        self.assertEqual((pinned / "readme.txt").read_text(), "committed")


if __name__ == "__main__":
    unittest.main()
