"""Deterministic tests for bounded PR discovery over managed First Mate evidence."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_link_discovery import (
    MAX_RECORD_BYTES,
    TEXT_CHUNK_CHARS,
    FirstMateLinkDiscovery,
    github_pull_requests,
    message_texts,
)
from herdr_harness.first_mate_store import FirstMateStore


import herdr_harness.first_mate_link_discovery as link_discovery_module


def session_rows(native_id, messages):
    rows = [{"type": "session", "id": native_id, "version": 3,
             "cwd": "/synthetic/project", "timestamp": "2026-09-22T00:00:00Z"}]
    for role, content in messages:
        items = [{"type": "text", "text": content}] if isinstance(content, str) else list(content)
        rows.append({"type": "message", "id": f"record-{len(rows)}",
                     "message": {"role": role, "content": items}})
    return rows


def write_session(path: Path, native_id: str, messages, *, trailing_newline: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = "".join(json.dumps(row) + "\n" for row in session_rows(native_id, messages))
    if not trailing_newline:
        payload = payload.rstrip("\n")
    path.write_text(payload, encoding="utf-8")


class FirstMateLinkDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "runtime"
        self.store = FirstMateStore(self.base / "store.sqlite3")
        self.feature = self.store.create_feature({
            "title": "Synthetic feature", "goal": "Plan the synthetic feature",
            "cwd": str(self.base.resolve()), "request_id": "create",
        })
        self.discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0.0)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def visit(self):
        human = self.store.claim_message(self.feature["id"], "owner-stage")
        return self.store.start_visit(self.feature["id"], "planning", "Planning",
                                      "stage-" + human["id"], 1, human["id"])

    def add_session(self, native_id, messages, *, visit=None, filename=None,
                    trailing_newline=True):
        visit = visit or self.visit()
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Evidence", "role": "reviewer", "prompt": "Inspect",
            "request_id": "assignment-" + native_id, "input_revision": 1,
        })
        claim = self.store.claim_assignment(assignment["id"], "worker-" + native_id)
        path = self.root / "sessions" / (filename or native_id) / "session.jsonl"
        write_session(path, native_id, messages, trailing_newline=trailing_newline)
        self.store.bind_session(assignment["id"], claim["generation"], "worker-" + native_id,
                                native_id, str(path))
        return {"assignment": assignment, "claim": claim, "path": path, "visit": visit}

    def add_job(self, native_id, messages, *, feature_id=None, finalized=True,
                session_file=None, header_id=None, job_id=None):
        feature_id = feature_id or self.feature["id"]
        job_id = job_id or "fmj_" + hashlib.sha256(native_id.encode()).hexdigest()[:32]
        directory = self.root / "jobs" / job_id
        directory.mkdir(parents=True, exist_ok=True)
        path = Path(session_file) if session_file else self.root / "sessions" / job_id / "session.jsonl"
        write_session(path, header_id or native_id, messages)
        job = {"id": job_id, "kind": "worker", "feature_id": feature_id,
               "session_file": str(path), "native_session_id": native_id,
               "claim": {}, "owner": "synthetic-owner"}
        (directory / "job.json").write_text(json.dumps(job), encoding="utf-8")
        if finalized:
            (directory / "finalized.json").write_text(json.dumps({"at": "2026-09-22T00:00:00Z"}), encoding="utf-8")
        return path

    def urls(self):
        return {link["url"]: link for link in self.store.list_links(self.feature["id"])}

    def test_message_text_helper_ignores_thinking_and_other_roles(self):
        record = {"type": "message", "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "https://github.com/synthetic-owner/synthetic-repo/pull/99"},
            {"type": "text", "text": "https://github.com/synthetic-owner/synthetic-repo/pull/1"},
            {"type": "toolCall", "name": "bash", "arguments": {"command": "true"}},
        ]}}
        self.assertEqual(message_texts(record),
                         ["https://github.com/synthetic-owner/synthetic-repo/pull/1"])
        self.assertEqual(message_texts({"type": "message", "message": {"role": "system", "content": "x"}}), [])
        self.assertEqual(message_texts({"type": "message", "message": {"role": "toolResult", "content": "gh output"}}),
                         ["gh output"])
        self.assertEqual(message_texts({"type": "session"}), [])

    def test_pull_request_recognition_uses_url_only_not_wording(self):
        text = ("draft: https://github.com/synthetic-owner/synthetic-repo/pull/2/files, "
                "ready: [review](https://github.com/synthetic-owner/synthetic-repo/pull/2) "
                "<https://github.com/synthetic-owner/synthetic-repo/pull/3> "
                "closed https://github.com/synthetic-owner/synthetic-repo/pull/2. "
                "other https://github.example.test/o/r/pull/4 "
                "issue https://github.com/synthetic-owner/synthetic-repo/issues/5 "
                "share http://share.example.test:8443/private/report?token=synthetic#s")
        self.assertEqual(github_pull_requests(text), [
            "https://github.com/synthetic-owner/synthetic-repo/pull/2",
            "https://github.com/synthetic-owner/synthetic-repo/pull/3",
        ])

    def test_discovers_messages_tool_results_outcomes_and_documents(self):
        visit = self.visit()
        self.add_session("native-session-a", [
            ("user", "Draft PR is https://github.com/synthetic-owner/synthetic-repo/pull/10/files"),
            ("assistant", "Ready: [review](https://github.com/synthetic-owner/synthetic-repo/pull/10) and "
                          "http://github.com/synthetic-owner/synthetic-repo/pull/11."),
            ("toolResult", "gh pr create\ncreated https://github.com/synthetic-owner/other-repo/pull/7"),
            ("assistant", [
                {"type": "thinking", "thinking": "https://github.com/synthetic-owner/synthetic-repo/pull/99"},
                {"type": "text", "text": "Visible https://github.com/synthetic-owner/synthetic-repo/pull/12"},
            ]),
        ], visit=visit)
        evidence = self.add_session("native-session-b", [
            ("user", "No link here."),
        ], visit=visit)
        self.store.record_outcome(
            evidence["assignment"]["id"], evidence["claim"]["generation"], "native-session-b", 1,
            "success",
            "Summary references https://github.com/synthetic-owner/synthetic-repo/pull/13",
            "outcome-a",
            documents=[{"title": "Evidence", "content": "Document link https://github.com/synthetic-owner/synthetic-repo/pull/14"}],
        )

        result = self.discovery.scan_once(force=True)

        links = self.urls()
        self.assertEqual(set(links), {
            "https://github.com/synthetic-owner/synthetic-repo/pull/10",
            "https://github.com/synthetic-owner/synthetic-repo/pull/11",
            "https://github.com/synthetic-owner/other-repo/pull/7",
            "https://github.com/synthetic-owner/synthetic-repo/pull/12",
            "https://github.com/synthetic-owner/synthetic-repo/pull/13",
            "https://github.com/synthetic-owner/synthetic-repo/pull/14",
        })
        self.assertNotIn("https://github.com/synthetic-owner/synthetic-repo/pull/99", links)
        for link in links.values():
            self.assertEqual(link["kind"], "pull_request")
            self.assertEqual(link["source"], "discovery")
            self.assertFalse(link["hidden"])
            for word in ("draft", "ready", "merged", "closed"):
                self.assertNotIn(word, link["title"].lower())
        self.assertGreaterEqual(result["saved"], 1)
        self.assertEqual(links["https://github.com/synthetic-owner/other-repo/pull/7"]["title"],
                         "synthetic-owner/other-repo #7")

    def test_non_pull_request_and_enterprise_urls_are_not_discovered_automatically(self):
        self.add_session("native-non-pr", [
            ("user", "Share http://share.example.test:8443/private/report?token=synthetic#summary"),
            ("assistant", "Enterprise https://github.example.test/synthetic-team/synthetic-repo/pull/5"),
            ("toolResult", "Docs https://docs.example.test/guide and issue https://github.com/synthetic-owner/synthetic-repo/issues/4"),
        ])
        self.discovery.scan_once(force=True)
        self.assertEqual(self.urls(), {})
        # Explicit classification and saving remain available beside discovery.
        saved = self.store.save_link(self.feature["id"], {
            "url": "http://share.example.test:8443/private/report?token=synthetic#summary",
            "request_id": "explicit-share",
        })
        self.assertEqual(saved["kind"], "link")
        self.assertEqual(len(self.store.list_links(self.feature["id"])), 1)

    def test_hidden_links_stay_suppressed_until_explicit_restore(self):
        self.add_session("native-hidden", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/20"),
        ])
        self.discovery.scan_once(force=True)
        link = self.urls()["https://github.com/synthetic-owner/synthetic-repo/pull/20"]
        self.store.set_link_visibility(self.feature["id"], link["id"],
                                       {"hidden": True, "request_id": "hide-one"})

        # A cursor replay (fresh private cursors after restart) must not unhide it.
        self.discovery.cursor_path.unlink()
        self.discovery.scan_once(force=True)
        retained = self.store.list_links(self.feature["id"])
        self.assertEqual(len(retained), 1)
        self.assertTrue(retained[0]["hidden"])
        self.assertEqual(retained[0]["id"], link["id"])

        self.store.set_link_visibility(self.feature["id"], link["id"],
                                       {"hidden": False, "request_id": "restore-one"})
        self.assertFalse(self.store.list_links(self.feature["id"])[0]["hidden"])

    def test_partial_records_replacement_and_restart_resume_from_cursors(self):
        path = self.add_session("native-partial", [
            ("assistant", "Complete https://github.com/synthetic-owner/synthetic-repo/pull/30"),
            ("assistant", "Partial https://github.com/synthetic-owner/synthetic-repo/pull/31"),
        ], trailing_newline=False)["path"]
        self.discovery.scan_once(force=True)
        self.assertNotIn("https://github.com/synthetic-owner/synthetic-repo/pull/31", self.urls())
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/30", self.urls())

        # Completing the partial record makes it eligible on the next pass.
        with path.open("a", encoding="utf-8") as handle:
            handle.write("\n")
        self.discovery.scan_once(force=True)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/31", self.urls())

        # A truncated replacement is detected and rescanned from the start.
        path.unlink()
        write_session(path, "native-partial", [
            ("assistant", "Replaced https://github.com/synthetic-owner/synthetic-repo/pull/32"),
        ])
        self.discovery.scan_once(force=True)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/32", self.urls())

        # A restarted discovery instance reuses the private cursor without rescans.
        restarted = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0.0)
        with patch.object(self.store, "register_link", wraps=self.store.register_link) as upsert:
            restarted.scan_once(force=True)
        self.assertEqual(upsert.call_count, 0)

    def test_cursor_is_not_persisted_until_every_upsert_succeeds(self):
        self.add_session("native-cursor", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/40"),
        ])
        with patch.object(self.store, "register_link", side_effect=RuntimeError("storage unavailable")):
            with self.assertRaisesRegex(RuntimeError, "storage unavailable"):
                self.discovery.scan_once(force=True)
        self.assertEqual(self.store.list_links(self.feature["id"]), [])

        with patch.object(self.store, "register_link", wraps=self.store.register_link) as upsert:
            self.discovery.scan_once(force=True)
            self.assertEqual(upsert.call_count, 1)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/40", self.urls())

        with patch.object(self.store, "register_link", wraps=self.store.register_link) as upsert:
            self.discovery.scan_once(force=True)
        self.assertEqual(upsert.call_count, 0)

    def test_more_than_one_thousand_managed_sessions_are_processed_in_bounded_passes(self):
        total = 1005
        for index in range(total):
            native_id = f"native-bulk-{index:04d}"
            self.add_job(native_id, [
                ("assistant", f"https://github.com/synthetic-owner/synthetic-repo/pull/{1000 + index}"),
            ], finalized=index % 2 == 0)
        discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0.0,
                                           max_sources_per_pass=64)
        passes = 0
        with patch.object(self.store, "snapshot", side_effect=AssertionError("full snapshot read")), \
             patch.object(self.store, "list_assignments", side_effect=AssertionError("unbounded assignments read")), \
             patch.object(self.store, "list_session_records", side_effect=AssertionError("unbounded ledger read")):
            while True:
                result = discovery.scan_once(force=True)
                passes += 1
                self.assertLessEqual(result["attempted"], 64)
                self.assertLessEqual(result["sources"], 64)
                if len(self.store.list_links(self.feature["id"])) >= total:
                    break
                self.assertLess(passes, 40, "bounded passes must still reach every managed session")
        self.assertEqual(len(self.store.list_links(self.feature["id"])), total)
        self.assertGreater(passes, 10)

    def test_inventory_never_reads_full_snapshots_or_unbounded_ledgers(self):
        visit = self.visit()
        evidence = self.add_session("native-light", [
            ("assistant", "Session https://github.com/synthetic-owner/synthetic-repo/pull/80"),
        ], visit=visit)
        self.store.record_outcome(
            evidence["assignment"]["id"], evidence["claim"]["generation"], "native-light", 1,
            "success", "Outcome https://github.com/synthetic-owner/synthetic-repo/pull/81",
            "outcome-light",
            documents=[{"title": "Evidence",
                        "content": "Document https://github.com/synthetic-owner/synthetic-repo/pull/82"}],
        )
        self.store.complete_visit(visit["id"],
                                  "Visit https://github.com/synthetic-owner/synthetic-repo/pull/83",
                                  "", "complete-light")
        with patch.object(self.store, "snapshot", side_effect=AssertionError("full snapshot read")), \
             patch.object(self.store, "list_assignments", side_effect=AssertionError("unbounded assignments read")), \
             patch.object(self.store, "list_session_records", side_effect=AssertionError("unbounded ledger read")), \
             patch.object(self.store, "get_document", side_effect=AssertionError("full document read")):
            self.discovery.scan_once(force=True)
        links = self.urls()
        for suffix in ("80", "81", "82", "83"):
            self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/" + suffix, links)

    def test_oversized_records_are_skipped_in_resumable_bounded_steps(self):
        visit = self.visit()
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Evidence", "role": "reviewer", "prompt": "Inspect",
            "request_id": "assignment-huge", "input_revision": 1,
        })
        claim = self.store.claim_assignment(assignment["id"], "worker-huge")
        native_id = "native-huge"
        path = self.root / "sessions" / native_id / "session.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        huge = json.dumps({"type": "message", "message": {"role": "user", "content": "x" * 40000}})
        valid = json.dumps({"type": "message", "message": {"role": "assistant",
            "content": "https://github.com/synthetic-owner/synthetic-repo/pull/77"}})
        path.write_text(json.dumps({"type": "session", "id": native_id, "version": 3}) + "\n" + huge + "\n" + valid + "\n",
                        encoding="utf-8")
        self.store.bind_session(assignment["id"], claim["generation"], "worker-huge", native_id, str(path))
        discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0.0,
                                           max_sources_per_pass=1, max_bytes_per_pass=4096,
                                           max_bytes_per_source=4096)
        reads = []
        original = link_discovery_module._read_records

        def counting(*args, **kwargs):
            result = original(*args, **kwargs)
            reads.append(result[2])
            return result

        with patch.object(link_discovery_module, "MAX_RECORD_BYTES", 8192), \
             patch.object(link_discovery_module, "_read_records", side_effect=counting):
            passes = 0
            while "https://github.com/synthetic-owner/synthetic-repo/pull/77" not in self.urls():
                discovery.scan_once(force=True)
                passes += 1
                self.assertLess(passes, 60, "bounded skipping must still reach the following record")
        self.assertGreater(passes, 1)
        self.assertGreater(len(reads), 1)
        # A complete record may overshoot by one line cap; skipping never drains
        # an arbitrary amount in one pass.
        self.assertLessEqual(max(reads), 8192 + 1)

    def test_documents_are_scanned_in_bounded_resumable_slices(self):
        evidence = self.add_session("native-doc", [("user", "No link here.")])
        tail = "https://github.com/synthetic-owner/synthetic-repo/pull/90"
        self.store.record_outcome(
            evidence["assignment"]["id"], evidence["claim"]["generation"], "native-doc", 1,
            "success", "Accepted outcome without a link.", "outcome-doc",
            documents=[{"title": "Long evidence", "content": ("x" * 40000) + " " + tail}],
        )
        discovery = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=0.0,
                                           max_sources_per_pass=8, max_bytes_per_pass=4096,
                                           max_bytes_per_source=4096)
        slices = []
        original = self.store.link_discovery_document_slice

        def counting(document_id, verdicts, *, offset=0, limit=64):
            slices.append((offset, limit))
            return original(document_id, verdicts, offset=offset, limit=limit)

        with patch.object(self.store, "link_discovery_document_slice", side_effect=counting), \
             patch.object(self.store, "get_document", side_effect=AssertionError("full document read")):
            passes = 0
            while tail not in self.urls():
                discovery.scan_once(force=True)
                passes += 1
                self.assertLess(passes, 60, "sliced documents must still reach their tail")
        self.assertGreater(passes, 1)
        self.assertTrue(slices)
        offsets = [offset for offset, _ in slices]
        self.assertEqual(offsets, sorted(offsets))
        self.assertGreater(offsets[-1], 0)
        self.assertTrue(all(0 < limit <= TEXT_CHUNK_CHARS for _, limit in slices))

    def test_case_variant_pr_references_deduplicate_and_keep_hidden_state(self):
        self.add_session("native-casing", [
            ("assistant", "Upper https://github.com/Synthetic-Owner/Synthetic-Repo/pull/60/files#diff-1"),
            ("assistant", "Lower https://github.com/synthetic-owner/synthetic-repo/pull/60"),
        ])
        self.discovery.scan_once(force=True)
        links = self.store.list_links(self.feature["id"])
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]["url"], "https://github.com/synthetic-owner/synthetic-repo/pull/60")
        self.store.set_link_visibility(self.feature["id"], links[0]["id"],
                                       {"hidden": True, "request_id": "hide-casing"})
        self.discovery.cursor_path.unlink()
        self.discovery.scan_once(force=True)
        retained = self.store.list_links(self.feature["id"])
        self.assertEqual(len(retained), 1)
        self.assertTrue(retained[0]["hidden"])
        self.assertEqual(retained[0]["id"], links[0]["id"])

    def test_foreign_mismatched_ambiguous_and_malformed_sources_are_ignored(self):
        foreign = self.base / "foreign-session.jsonl"
        self.add_job("native-foreign", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/50"),
        ], session_file=foreign)
        self.add_job("native-mismatch", [], header_id="native-other-header")
        malformed = self.add_job("native-malformed", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/51"),
        ])
        with malformed.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"type": "message", "message": {"role": "assistant", "content": [
                {"type": "text", "text": "https://github.com/synthetic-owner/synthetic-repo/pull/52"}]}}) + "\n")
            handle.write("not-json\n")

        other = self.store.create_feature({
            "title": "Other feature", "goal": "Other", "cwd": str(self.base.resolve()),
            "request_id": "other-create",
        })
        # A job that reuses another feature's native ID at a copied path is rejected.
        self.add_session("native-ledger-owned", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/54"),
        ])
        self.add_job("native-ledger-owned", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/55"),
        ], feature_id=other["id"], job_id="fmj_other_owned")
        shared = self.root / "sessions" / "shared" / "session.jsonl"
        self.add_job("native-shared", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/53"),
        ], session_file=shared)
        self.add_job("native-shared", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/53"),
        ], session_file=shared, feature_id=other["id"], job_id="fmj_other_shared")

        self.discovery.scan_once(force=True)
        links = self.urls()
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/51", links)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/52", links)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/54", links)
        for skipped in ("pull/50", "pull/53", "pull/55"):
            self.assertNotIn("https://github.com/synthetic-owner/synthetic-repo/" + skipped, links)

    def test_only_accepted_outcomes_and_their_documents_are_scanned(self):
        visit = self.visit()
        failed = self.add_session("native-failed", [("user", "Blocked.")], visit=visit)
        self.store.record_outcome(
            failed["assignment"]["id"], failed["claim"]["generation"], "native-failed", 1,
            "blocked", "Blocked by https://github.com/synthetic-owner/synthetic-repo/pull/60",
            "outcome-failed",
            documents=[{"title": "Failure notes",
                        "content": "https://github.com/synthetic-owner/synthetic-repo/pull/61"}],
        )
        accepted = self.add_session("native-accepted", [("user", "Passed.")], visit=failed["visit"])
        self.store.record_outcome(
            accepted["assignment"]["id"], accepted["claim"]["generation"], "native-accepted", 1,
            "passed", "Passed with https://github.com/synthetic-owner/synthetic-repo/pull/62",
            "outcome-passed",
            documents=[{"title": "Review evidence",
                        "content": "https://github.com/synthetic-owner/synthetic-repo/pull/63"}],
        )
        self.discovery.scan_once(force=True)
        links = self.urls()
        self.assertEqual(set(links), {
            "https://github.com/synthetic-owner/synthetic-repo/pull/62",
            "https://github.com/synthetic-owner/synthetic-repo/pull/63",
        })

    def test_retained_predecessor_and_finalized_job_sources_are_discovered(self):
        evidence = self.add_session("native-retained", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/41"),
        ])
        self.store.record_outcome(
            evidence["assignment"]["id"], evidence["claim"]["generation"], "native-retained", 1,
            "success", "Retained predecessor finished.", "outcome-retained", documents=[],
        )
        self.assertEqual(self.store.get_session("native-retained")["status"], "retained")
        self.add_job("native-finalized", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/42"),
        ], finalized=True)
        self.discovery.scan_once(force=True)
        links = self.urls()
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/41", links)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/42", links)

    def test_unavailable_sources_preserve_saved_links_and_never_touch_the_network(self):
        evidence = self.add_session("native-missing", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/70"),
        ])
        self.discovery.scan_once(force=True)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/70", self.urls())
        evidence["path"].unlink()
        with patch("socket.create_connection", side_effect=AssertionError("network is not allowed")), \
             patch.object(subprocess, "run", side_effect=AssertionError("subprocess is not allowed")), \
             patch.object(subprocess, "Popen", side_effect=AssertionError("subprocess is not allowed")):
            self.discovery.scan_once(force=True)
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/70", self.urls())

    def test_minimum_interval_defers_repeated_passes_without_losing_work(self):
        self.add_session("native-interval", [
            ("assistant", "https://github.com/synthetic-owner/synthetic-repo/pull/80"),
        ])
        throttled = FirstMateLinkDiscovery(self.store, root=self.root, minimum_interval=3600.0)
        first = throttled.scan_once()
        second = throttled.scan_once()
        self.assertNotEqual(first.get("skipped"), "interval")
        self.assertEqual(second.get("skipped"), "interval")
        self.assertIn("https://github.com/synthetic-owner/synthetic-repo/pull/80", self.urls())


if __name__ == "__main__":
    unittest.main()
