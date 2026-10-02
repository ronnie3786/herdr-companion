"""Synthetic source mutation, concurrency, and bounded accounting tests."""
from __future__ import annotations

import json
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

from herdr_harness.first_mate_usage import FirstMateUsage


def paid(identity: str, cost: float) -> dict:
    return {"type": "message", "id": identity, "message": {
        "role": "assistant", "provider": "synthetic", "model": "synthetic",
        "usage": {"input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4,
                  "totalTokens": 10, "cost": {"total": cost}},
    }}


def write(path: Path, *entries: dict, identity: str = "synthetic-session") -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in (
        {"type": "session", "id": identity}, *entries)), encoding="utf-8")


class FirstMateUsageIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "sessions"
        self.root.mkdir()
        self.path = self.root / "session.jsonl"
        self.usage = FirstMateUsage(self.root)

    def read(self) -> dict:
        return self.usage.session_usage(self.path, "synthetic-session")

    def test_concurrent_cache_misses_share_one_parse(self):
        write(self.path, paid("one", 1.0))
        start = threading.Barrier(6)
        entered, release = threading.Event(), threading.Event()
        parse = self.usage._parse

        def blocked(*args):
            entered.set()
            self.assertTrue(release.wait(5), "test did not release the parser")
            return parse(*args)

        def reader():
            start.wait(5)
            return self.read()

        with mock.patch.object(self.usage, "_parse", side_effect=blocked) as scanned:
            with ThreadPoolExecutor(max_workers=6) as pool:
                futures = [pool.submit(reader) for _ in range(6)]
                try:
                    self.assertTrue(entered.wait(5))
                    self.assertEqual(scanned.call_count, 1)
                    self.assertFalse(any(future.done() for future in futures))
                finally:
                    release.set()
                results = [future.result(5) for future in futures]
            self.assertEqual(scanned.call_count, 1)
        self.assertTrue(all(result["cost_usd"] == 1.0 for result in results))

    def test_same_size_rewrite_with_restored_mtime_invalidates_cache(self):
        write(self.path, paid("one", 1.0))
        self.assertEqual(self.read()["cost_usd"], 1.0)
        before = self.path.stat()
        write(self.path, paid("one", 9.0))
        os.utime(self.path, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(self.path.stat().st_size, before.st_size)
        self.assertEqual(self.path.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.read()["cost_usd"], 9.0)

    def test_append_truncate_replace_and_restart_rebuild_exact_totals(self):
        write(self.path, paid("one", 1.0))
        self.assertEqual(self.read()["cost_usd"], 1.0)
        with self.path.open("a") as handle:
            handle.write(json.dumps(paid("two", 2.0)) + "\n")
        self.assertEqual(self.read()["cost_usd"], 3.0)
        write(self.path, paid("one", 1.0))
        self.assertEqual(self.read()["cost_usd"], 1.0)
        replacement = self.root / "replacement.jsonl"
        write(replacement, paid("replacement", 5.0))
        replacement.replace(self.path)
        self.assertEqual(self.read()["cost_usd"], 5.0)
        restarted = FirstMateUsage(self.root)
        self.assertEqual(restarted.session_usage(self.path, "synthetic-session")["cost_usd"], 5.0)

    def test_mutation_between_parse_and_publication_does_not_publish_complete(self):
        write(self.path, paid("one", 1.0))
        parse = self.usage._parse

        def changed(*args):
            result = parse(*args)
            with self.path.open("a") as handle:
                handle.write(json.dumps(paid("two", 2.0)) + "\n")
            return result

        with mock.patch.object(self.usage, "_parse", side_effect=changed):
            result = self.read()
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["_source_state"], "source_changed")
        self.assertFalse(self.usage._cache)
        self.assertEqual(self.read()["cost_usd"], 3.0)

    def test_replacement_during_parse_is_not_credited_to_old_stat(self):
        write(self.path, paid("one", 1.0))
        replacement = self.root / "replacement.jsonl"
        write(replacement, paid("replacement", 7.0))
        loads = json.loads

        def replacing(line):
            entry = loads(line)
            if entry.get("type") == "message":
                replacement.replace(self.path)
            return entry

        with mock.patch("herdr_harness.first_mate_usage.json.loads", side_effect=replacing):
            result = self.read()
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(self.read()["cost_usd"], 7.0)

    def test_transient_open_failure_retries_unchanged_signature(self):
        write(self.path, paid("one", 1.0))
        self.read()
        write(self.path, paid("one", 2.0))
        with mock.patch.object(self.usage, "_open_source", side_effect=OSError("synthetic failure")):
            failed = self.read()
        self.assertEqual((failed["cost_usd"], failed["status"]), (1.0, "partial"))
        self.assertTrue(failed["stale"])
        recovered = self.read()
        self.assertEqual((recovered["cost_usd"], recovered["status"]), (2.0, "complete"))
        self.assertNotIn("stale", recovered)

    def test_malformed_header_cannot_resurrect_cached_identity_after_deletion(self):
        write(self.path, paid("one", 1.0))
        self.read()
        self.path.write_text("not-json\n", encoding="utf-8")
        self.assertEqual(self.read()["_source_state"], "malformed_header")
        self.path.unlink()
        missing = self.read()
        self.assertIsNone(missing["cost_usd"])
        self.assertFalse(missing.get("stale"))

    def test_symlink_escape_evicts_previously_valid_claim(self):
        source = self.root / "owned.jsonl"
        write(source, paid("one", 1.0))
        self.path.symlink_to(source)
        self.assertEqual(self.read()["cost_usd"], 1.0)
        outside = Path(self.temp.name) / "outside.jsonl"
        write(outside, paid("outside", 9.0))
        self.path.unlink()
        self.path.symlink_to(outside)
        self.assertEqual(self.read()["_source_state"], "path_escape")
        self.path.unlink()
        self.assertIsNone(self.read()["cost_usd"])

    def test_swapped_fifo_cannot_block_after_regular_file_stat(self):
        write(self.path, paid("one", 1.0))
        opener = self.usage._open_source

        def swapped(path):
            path.unlink()
            os.mkfifo(path)
            return opener(path)

        with mock.patch.object(self.usage, "_open_source", side_effect=swapped):
            result = self.read()
        self.assertEqual(result["status"], "unavailable")
        self.assertFalse(self.usage._cache)

    def test_swapped_parent_symlink_cannot_escape_after_path_validation(self):
        parent = self.root / "parent"
        parent.mkdir()
        self.path = parent / "session.jsonl"
        write(self.path, paid("one", 1.0))
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        write(outside / "session.jsonl", paid("outside", 9.0))
        opener = self.usage._open_source

        def swapped(path):
            parent.rename(self.root / "retained")
            parent.symlink_to(outside, target_is_directory=True)
            return opener(path)

        with mock.patch.object(self.usage, "_open_source", side_effect=swapped):
            result = self.read()
        self.assertEqual(result["status"], "unavailable")
        self.assertFalse(self.usage._cache)

    def test_growing_source_stops_at_its_initial_read_boundary(self):
        write(self.path, paid("one", 1.0))
        loads = json.loads
        parsed_ids = []

        def appending(line):
            entry = loads(line)
            if entry.get("type") == "message":
                parsed_ids.append(entry["id"])
                with self.path.open("a") as handle:
                    handle.write(json.dumps(paid("appended", 2.0)) + "\n")
            return entry

        with mock.patch("herdr_harness.first_mate_usage.json.loads", side_effect=appending):
            result = self.read()
        self.assertEqual(parsed_ids, ["one"])
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(self.read()["cost_usd"], 3.0)

    def test_both_summary_caches_have_bounded_retention(self):
        usage = FirstMateUsage(self.root, max_cached_sources=2)
        for index in range(5):
            path = self.root / f"source-{index}.jsonl"
            write(path, paid("one", 1.0))
            usage.session_usage(path, "synthetic-session")
        self.assertEqual(len(usage._cache), 2)
        self.assertEqual(len(usage._last_good), 2)

    def test_stop_interrupts_between_records_without_publishing(self):
        write(self.path, *(paid(str(index), 1.0) for index in range(10)))
        stop = threading.Event()
        usage = FirstMateUsage(self.root, stop_event=stop)
        loads = json.loads

        def interrupted(line):
            entry = loads(line)
            if entry.get("type") == "message":
                stop.set()
            return entry

        with mock.patch("herdr_harness.first_mate_usage.json.loads", side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                usage.session_usage(self.path, "synthetic-session")
        self.assertFalse(usage._cache)
        self.assertFalse(usage._last_good)
        stop.clear()
        self.assertEqual(usage.session_usage(self.path, "synthetic-session")["cost_usd"], 10.0)

    def test_header_discovery_is_strict_bounded_and_works_with_accounting_disabled(self):
        write(self.path, paid("one", 1.0))
        usage = FirstMateUsage(self.root, enabled=False)
        with mock.patch.object(usage, "_parse", side_effect=AssertionError("full transcript parse")):
            self.assertEqual(usage.discover_session_id(self.path), "synthetic-session")
            self.assertIsNone(usage.discover_session_id(self.path, "different-session"))
        for invalid in (b'{}\n{"type":"session","id":"later"}\n',
                        b'{"type":"session","id":"partial"}', b'not-json\n'):
            self.path.write_bytes(invalid)
            self.assertIsNone(usage.discover_session_id(self.path))
        self.path.write_bytes(b'{"type":"session","id":"' + b'x' * 128 + b'"}\n')
        with mock.patch("herdr_harness.first_mate_usage.MAX_RECORD", 64):
            self.assertIsNone(usage.discover_session_id(self.path))
        self.assertIsNone(usage.discover_session_id(self.root))
        outside = Path(self.temp.name) / "outside.jsonl"
        write(outside)
        self.assertIsNone(usage.discover_session_id(outside))

    def test_duplicate_conflicts_preserve_partial_first_record_semantics(self):
        first, conflicting = paid("same-entry", 1.0), paid("same-entry", 2.0)
        write(self.path, first, first, conflicting)
        result = self.read()
        self.assertEqual((result["cost_usd"], result["usage_records"], result["status"]),
                         (1.0, 1, "partial"))

    def test_disabled_metadata_discovers_unbound_sessions_and_global_identity_conflicts(self):
        write(self.path, paid("one", 1.0))
        usage = FirstMateUsage(self.root, enabled=False)
        jobs_root = Path(self.temp.name) / "jobs"
        job = {"id": "synthetic-job", "feature_id": "synthetic-feature", "kind": "coordinator",
               "session_file": str(self.path), "claim": {}, "created_at": "2030-01-01T00:00:00Z"}
        (jobs_root / job["id"]).mkdir(parents=True)
        (jobs_root / job["id"] / "started.json").write_text("{}", encoding="utf-8")
        arguments = dict(feature_id="synthetic-feature", assignments=[], ledger_sessions=[],
                         jobs=[job], jobs_root=jobs_root, updated_at="2030-01-01T00:00:00Z")
        with mock.patch.object(usage, "_parse", side_effect=AssertionError("full transcript parse")):
            self.assertFalse(usage.account(**arguments)["sessions"])
            result = usage.account(**arguments, discover_unbound=True)
            self.assertEqual(result["sessions"][0]["native_session_id"], "synthetic-session")
            self.assertIsNone(result["usage"]["cost_usd"])
            other_path = self.root / "conflicting.jsonl"
            write(other_path, paid("other", 2.0))
            other = {**job, "id": "other-job", "feature_id": "other-feature", "session_file": str(other_path)}
            (jobs_root / other["id"]).mkdir()
            (jobs_root / other["id"] / "started.json").write_text("{}", encoding="utf-8")
            conflict = usage.account(**{**arguments, "jobs": [job, other]}, discover_unbound=True)
            self.assertFalse(conflict["sessions"])
            self.assertIsNone(conflict["usage"]["cost_usd"])


if __name__ == "__main__":
    unittest.main()
