"""Deterministic current-coordinator context telemetry tests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_context import (
    MAX_SAFE_INTEGER,
    MAX_TELEMETRY_RECORD_BYTES,
    FirstMateContext,
    handoff_target_tokens,
)
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore


class FirstMateContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "jobs"
        self.root.mkdir()
        self.context = FirstMateContext(self.root, 150000)
        self.feature = {"id": "feature-current", "native_session_id": "native-current"}

    def tearDown(self):
        self.temp.cleanup()

    def job(self, identity, *, kind="coordinator", feature_id="feature-current",
            native_session_id="native-current", created_at="2026-09-22T12:00:00Z"):
        return {
            "id": identity,
            "kind": kind,
            "feature_id": feature_id,
            "native_session_id": native_session_id,
            "created_at": created_at,
        }

    def telemetry(self, job, *events):
        directory = self.root / job["id"]
        directory.mkdir(parents=True)
        path = directory / "telemetry.jsonl"
        path.write_text(
            "".join(json.dumps(event, allow_nan=True) + "\n" for event in events)
        )
        return path

    @staticmethod
    def sample(native="native-current", *, tokens=0, window=200000,
               time="2026-09-22T12:00:00Z"):
        return {
            "type": "context_usage",
            "native_session_id": native,
            "time": time,
            "payload": {"tokens": tokens, "contextWindow": window},
        }

    def test_no_session_is_an_unavailable_new_session_not_an_old_sample(self):
        job = self.job("old", native_session_id="native-old")
        self.telemetry(job, self.sample(native="native-old", tokens=100000))
        projected = self.context.project({"id": "feature-current", "native_session_id": None}, [job])
        self.assertEqual(projected, {
            "native_session_id": None,
            "status": "unavailable",
            "tokens": None,
            "context_window": None,
            "handoff_target_tokens": 150000,
            "observed_at": None,
        })

    def test_latest_valid_exact_coordinator_sample_preserves_zero_and_freshness(self):
        current = self.job("current")
        worker = self.job("worker", kind="worker")
        old = self.job("old", native_session_id="native-old")
        self.telemetry(current,
            self.sample(tokens=120, time="2026-09-22T12:00:00Z"),
            self.sample(tokens=True, time="2026-09-22T12:01:00Z"),
            self.sample(tokens=0, window=100000, time="2026-09-22T12:02:00Z"))
        self.telemetry(worker, self.sample(tokens=999999, time="2026-09-22T12:03:00Z"))
        self.telemetry(old, self.sample(native="native-old", tokens=888888,
                                        time="2026-09-22T12:04:00Z"))
        projected = self.context.project(self.feature, [current, worker, old])
        self.assertEqual(projected, {
            "native_session_id": "native-current",
            "status": "measured",
            "tokens": 0,
            "context_window": 100000,
            "handoff_target_tokens": 90000,
            "observed_at": "2026-09-22T12:02:00Z",
        })

    def test_malformed_foreign_and_non_context_records_never_invent_zero(self):
        current = self.job("current")
        self.telemetry(current,
            {"type": "context_usage", "native_session_id": "native-foreign",
             "time": "2026-09-22T12:00:00Z", "payload": {"tokens": 10}},
            {"type": "context_usage", "native_session_id": "native-current",
             "time": "not-a-time", "payload": {"tokens": 11}},
            self.sample(tokens=float("nan"), time="2026-09-22T12:01:00Z"),
            self.sample(tokens=-1, time="2026-09-22T12:02:00Z"),
            self.sample(tokens=MAX_SAFE_INTEGER + 1, time="2026-09-22T12:03:00Z"),
            {"type": "usage", "native_session_id": "native-current",
             "time": "2026-09-22T12:04:00Z", "payload": {"tokens": 999}})
        projected = self.context.project(self.feature, [current])
        self.assertEqual(projected["status"], "unavailable")
        self.assertIsNone(projected["tokens"])
        self.assertIsNone(projected["observed_at"])

    def test_invalid_window_is_unknown_while_valid_token_measurement_is_retained(self):
        current = self.job("current")
        self.telemetry(current, self.sample(tokens=42, window=False))
        projected = self.context.project(self.feature, [current])
        self.assertEqual(projected["status"], "measured")
        self.assertEqual(projected["tokens"], 42)
        self.assertIsNone(projected["context_window"])
        self.assertEqual(projected["handoff_target_tokens"], 150000)

    def test_rollover_cannot_reuse_predecessor_telemetry(self):
        old = self.job("old", native_session_id="native-old")
        self.telemetry(old, self.sample(native="native-old", tokens=149000))
        successor = {"id": "feature-current", "native_session_id": "native-successor"}
        projected = self.context.project(successor, [old])
        self.assertEqual(projected["native_session_id"], "native-successor")
        self.assertEqual(projected["status"], "unavailable")
        self.assertIsNone(projected["tokens"])

    def test_malformed_job_identity_controls_are_rejected_before_open(self):
        for identity in ("nul\0identity", "line\nbreak", "delete\x7fcontrol"):
            with self.subTest(identity=repr(identity)):
                with patch.object(
                        self.context, "_open_telemetry",
                        side_effect=AssertionError("malformed identity was opened")):
                    projected = self.context.project(self.feature, [self.job(identity)])
                self.assertEqual(projected["status"], "unavailable")

    def test_incomplete_recursive_and_oversize_records_are_ignored(self):
        job = self.job("bounded-tail")
        path = self.telemetry(
            job,
            {"padding": "x" * MAX_TELEMETRY_RECORD_BYTES},
            {"recursive": True},
            self.sample(tokens=17, time="2026-09-22T12:01:00Z"),
        )
        with path.open("ab") as handle:
            handle.write(b'{"type":"context_usage","payload":')
        real_loads = json.loads

        def load_bounded_record(line):
            if b'"recursive"' in line:
                raise RecursionError("synthetic bounded recursive JSON")
            return real_loads(line)

        with patch("herdr_harness.first_mate_context.json.loads",
                   side_effect=load_bounded_record):
            projected = self.context.project(self.feature, [job])
        self.assertEqual(projected["status"], "measured")
        self.assertEqual(projected["tokens"], 17)
        self.assertEqual(projected["observed_at"], "2026-09-22T12:01:00Z")

    def test_job_paths_cannot_traverse_or_follow_outside_root_symlinks(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        outside_telemetry = outside / "telemetry.jsonl"
        outside_telemetry.write_text(json.dumps(self.sample(tokens=999)) + "\n")
        traversal = self.job("../outside")

        linked = self.root / "linked"
        linked.symlink_to(outside, target_is_directory=True)
        linked_job = self.job("linked")

        file_link_job = self.job("file-link")
        file_link_directory = self.root / file_link_job["id"]
        file_link_directory.mkdir()
        (file_link_directory / "telemetry.jsonl").symlink_to(outside_telemetry)

        for job in (traversal, linked_job, file_link_job):
            with self.subTest(job=job["id"]):
                projected = self.context.project(self.feature, [job])
                self.assertEqual(projected["status"], "unavailable")
                self.assertIsNone(projected["tokens"])

    @unittest.skipUnless(hasattr(os, "mkfifo") and hasattr(os, "O_NONBLOCK"),
                         "platform does not support nonblocking FIFOs")
    def test_fifo_telemetry_is_rejected_without_blocking(self):
        job = self.job("fifo")
        directory = self.root / job["id"]
        directory.mkdir()
        os.mkfifo(directory / "telemetry.jsonl")
        script = """
import json
import sys
from herdr_harness.first_mate_context import FirstMateContext
context = FirstMateContext(sys.argv[1], 150000)
feature = {"id": "feature-current", "native_session_id": "native-current"}
job = {
    "id": "fifo", "kind": "coordinator", "feature_id": "feature-current",
    "native_session_id": "native-current", "created_at": "2026-09-22T12:00:00Z",
}
print(json.dumps(context.project(feature, [job])))
"""
        try:
            completed = subprocess.run(
                [sys.executable, "-c", script, str(self.root)],
                check=True, capture_output=True, text=True, timeout=5)
        except subprocess.TimeoutExpired:
            self.fail("telemetry FIFO open blocked")
        projected = json.loads(completed.stdout)
        self.assertEqual(projected["status"], "unavailable")
        self.assertIsNone(projected["tokens"])

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"),
                         "platform does not expose no-follow open flags")
    def test_root_and_telemetry_open_flags_preserve_no_follow_boundary(self):
        job = self.job("open-flags")
        self.telemetry(job, self.sample(tokens=7))
        with patch("herdr_harness.first_mate_context.os.open", wraps=os.open) as opened:
            self.assertEqual(self.context.project(self.feature, [job])["tokens"], 7)
        root_flags = opened.call_args_list[0].args[1]
        telemetry_flags = next(
            call.args[1] for call in opened.call_args_list
            if call.args[0] == "telemetry.jsonl")
        self.assertTrue(root_flags & os.O_NOFOLLOW)
        self.assertTrue(telemetry_flags & os.O_NOFOLLOW)
        self.assertTrue(telemetry_flags & os.O_NONBLOCK)

    def test_later_append_wins_equal_timestamp_within_the_newest_job(self):
        job = self.job("same-time")
        path = self.telemetry(job, self.sample(tokens=1))
        self.assertEqual(self.context.project(self.feature, [job])["tokens"], 1)
        with path.open("a") as handle:
            handle.write(json.dumps(self.sample(tokens=2)) + "\n")
        projected = self.context.project(self.feature, [job])
        self.assertEqual(projected["tokens"], 2)

    def test_different_session_predecessor_is_never_reused(self):
        predecessor = self.job(
            "predecessor", native_session_id="native-old",
            created_at="2026-09-22T12:00:00Z")
        successor = self.job("successor", created_at="2026-09-22T12:01:00Z")
        self.telemetry(
            predecessor,
            self.sample(native="native-old", tokens=999,
                        time="2026-09-22T13:00:00Z"),
        )
        successor_path = self.telemetry(
            successor,
            self.sample(tokens=23, time="2026-09-22T12:01:00Z"),
        )
        projected = self.context.project(self.feature, [predecessor, successor])
        self.assertEqual(projected["tokens"], 23)
        self.assertEqual(projected["observed_at"], "2026-09-22T12:01:00Z")

        successor_path.unlink()
        projected = self.context.project(self.feature, [predecessor, successor])
        self.assertEqual(projected["status"], "unavailable")
        self.assertIsNone(projected["tokens"])

    def test_empty_new_turn_retains_same_session_measurement_and_timestamp(self):
        measured = self.job("measured", created_at="2026-09-22T12:00:00Z")
        pending = self.job("pending", created_at="2026-09-22T12:01:00Z")
        self.telemetry(
            measured,
            self.sample(tokens=41, time="2026-09-22T12:00:30Z"),
        )
        self.telemetry(pending)
        projected = self.context.project(self.feature, [measured, pending])
        self.assertEqual(projected["status"], "measured")
        self.assertEqual(projected["tokens"], 41)
        self.assertEqual(projected["observed_at"], "2026-09-22T12:00:30Z")

    def test_latest_timestamp_wins_across_same_session_jobs(self):
        earlier_job = self.job("earlier", created_at="2026-09-22T12:00:00Z")
        newer_job = self.job("newer", created_at="2026-09-22T12:01:00Z")
        self.telemetry(
            earlier_job,
            self.sample(tokens=52, time="2026-09-22T12:03:00Z"),
        )
        self.telemetry(
            newer_job,
            self.sample(tokens=31, time="2026-09-22T12:02:00Z"),
        )
        projected = self.context.project(self.feature, [earlier_job, newer_job])
        self.assertEqual(projected["tokens"], 52)
        self.assertEqual(projected["observed_at"], "2026-09-22T12:03:00Z")

    def test_unreadable_newest_job_drops_its_cache_but_keeps_readable_history(self):
        earlier = self.job("earlier", created_at="2026-09-22T12:00:00Z")
        newest = self.job("newest", created_at="2026-09-22T12:01:00Z")
        self.telemetry(
            earlier,
            self.sample(tokens=11, time="2026-09-22T12:00:30Z"),
        )
        newest_path = self.telemetry(
            newest,
            self.sample(tokens=22, time="2026-09-22T12:01:30Z"),
        )
        self.assertEqual(
            self.context.project(self.feature, [earlier, newest])["tokens"], 22)

        newest_path.unlink()
        projected = self.context.project(self.feature, [earlier, newest])
        self.assertEqual(projected["tokens"], 11)
        self.assertEqual(projected["observed_at"], "2026-09-22T12:00:30Z")

    def test_same_session_history_search_is_bounded_to_latest_128_jobs(self):
        jobs = []
        for index in range(129):
            job = self.job(
                f"job-{index:03d}",
                created_at=f"2026-09-22T12:{index // 60:02d}:{index % 60:02d}Z",
            )
            jobs.append(job)
            if index == 0:
                self.telemetry(job, self.sample(tokens=77))
        projected = self.context.project(self.feature, jobs)
        self.assertEqual(projected["status"], "unavailable")
        self.assertIsNone(projected["tokens"])

    def test_cache_tracks_append_truncate_replace_hit_and_missing_file(self):
        job = self.job("cached")
        path = self.telemetry(job, self.sample(tokens=1))
        self.assertEqual(self.context.project(self.feature, [job])["tokens"], 1)

        with patch("herdr_harness.first_mate_context.json.loads",
                   side_effect=AssertionError("unchanged telemetry was reparsed")):
            self.assertEqual(self.context.project(self.feature, [job])["tokens"], 1)

        with path.open("a") as handle:
            handle.write(json.dumps(self.sample(
                tokens=22, time="2026-09-22T12:01:00Z")) + "\n")
        self.assertEqual(self.context.project(self.feature, [job])["tokens"], 22)

        path.write_text(json.dumps(self.sample(
            tokens=333, time="2026-09-22T12:02:00Z")) + "\n")
        self.assertEqual(self.context.project(self.feature, [job])["tokens"], 333)

        replacement = path.with_name("replacement.jsonl")
        replacement.write_text(json.dumps(self.sample(
            tokens=4444, time="2026-09-22T12:03:00Z")) + "\n")
        replacement.replace(path)
        self.assertEqual(self.context.project(self.feature, [job])["tokens"], 4444)

        path.unlink()
        self.assertEqual(self.context.project(self.feature, [job])["status"], "unavailable")
        path.write_text('{"type":"context_usage"')
        projected = self.context.project(self.feature, [job])
        self.assertEqual(projected["status"], "unavailable")
        self.assertIsNone(projected["tokens"])

    def test_target_math_matches_managed_rotation_reserve(self):
        self.assertEqual(handoff_target_tokens(150000, 200000), 150000)
        self.assertEqual(handoff_target_tokens(150000, 100000), 90000)
        self.assertEqual(handoff_target_tokens(150000, 10000), 4096)
        self.assertEqual(handoff_target_tokens(150000, True), 150000)


class FirstMateContextProjectionTests(unittest.TestCase):
    def test_list_feature_and_snapshot_share_current_context_projection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            store = FirstMateStore(root / "store.sqlite3")
            self.addCleanup(store.close)
            feature = store.create_feature({
                "title": "Synthetic feature",
                "goal": "Inspect context",
                "cwd": directory,
                "request_id": "create",
            })
            runtime = FirstMateRuntime(store, environ={}, runtime_root=root / "runtime")
            claim = store.claim_message(feature["id"], runtime.owner)
            job = runtime._new_job(feature, kind="coordinator", prompt="Inspect", claim=claim)
            runtime._bind(job, "native-current", job["session_file"])
            telemetry = runtime._job_dir(job) / "telemetry.jsonl"
            telemetry.write_text(json.dumps({
                "type": "context_usage",
                "native_session_id": "native-current",
                "time": "2026-09-22T12:00:00Z",
                "payload": {"tokens": 321, "contextWindow": 100000},
            }) + "\n")
            expected = {
                "native_session_id": "native-current",
                "status": "measured",
                "tokens": 321,
                "context_window": 100000,
                "handoff_target_tokens": 90000,
                "observed_at": "2026-09-22T12:00:00Z",
            }
            self.assertEqual(runtime.feature(feature["id"])["coordinator_context"], expected)
            self.assertEqual(runtime.list_features()[0]["coordinator_context"], expected)
            self.assertEqual(runtime.snapshot(feature["id"])["feature"]["coordinator_context"], expected)


if __name__ == "__main__":
    unittest.main()
