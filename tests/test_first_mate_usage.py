"""Deterministic First Mate usage accounting contract tests (no provider calls)."""
from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from herdr_harness.first_mate_runtime import FirstMateRuntime, _write_json
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.first_mate_usage import FirstMateUsage, MAX_SAFE_INTEGER, aggregate_usage


def usage(cost=1.0, *, input=10, output=2, cache_read=3, cache_write=1, total=16):
    return {
        "input": input, "output": output, "cacheRead": cache_read,
        "cacheWrite": cache_write, "totalTokens": total,
        "cost": {"input": 0.0, "output": 0.0, "cacheRead": 0.0,
                 "cacheWrite": 0.0, "total": cost},
    }


def write_session(path: Path, native_id: str, entries: list[dict] = None, *, final_newline=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [{"type": "session", "version": 3, "id": native_id, "cwd": "/synthetic/project"}, *(entries or [])]
    encoded = "\n".join(json.dumps(row) for row in rows) + ("\n" if final_newline else "")
    path.write_text(encoded, encoding="utf-8")


def assistant(identity: str, cost=1.0, *, provider="synthetic", model="reasoner", use=None):
    return {"type": "message", "id": identity, "parentId": None, "message": {
        "role": "assistant", "provider": provider, "model": model,
        "content": [{"type": "text", "text": "synthetic response"}],
        "usage": usage(cost) if use is None else use,
    }}


class FirstMateUsageParserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "sessions"
        self.root.mkdir()
        self.accountant = FirstMateUsage(self.root)

    def test_all_paid_entry_shapes_are_counted_once_and_retained_tail_is_not(self):
        path = self.root / "all.jsonl"
        first = assistant("assistant-a", 1.25, provider="synthetic", model="alpha")
        rows = [
            first,
            first,  # repeated persisted entry ID is not another request
            {"type": "message", "id": "tool-a", "message": {
                "role": "toolResult", "content": [], "usage": usage(.25),
                "provider": "synthetic", "model": "tool-model"}},
            {"type": "compaction", "id": "compact-a", "usage": usage(.5),
             "provider": "synthetic", "model": "alpha",
             "retainedTail": [{"role": "assistant", "provider": "ignored", "model": "ignored",
                               "usage": usage(99), "content": []}]},
            {"type": "branch_summary", "id": "branch-a", "usage": usage(.75)},
            assistant("assistant-b", 2.0, provider="synthetic", model="beta"),
        ]
        write_session(path, "native-all", rows)

        result = self.accountant.public_summary(self.accountant.session_usage(path, "native-all"))
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["usage_records"], 5)
        self.assertEqual(result["cost_usd"], 4.75)
        self.assertEqual(result["total_tokens"], 80)
        self.assertEqual({(row["provider"], row["model"]) for row in result["models"]}, {
            ("synthetic", "alpha"), ("synthetic", "beta"),
            ("synthetic", "tool-model"), (None, None),
        })

    def test_idless_semantic_content_fingerprint_deduplicates_formatting(self):
        path = self.root / "idless-duplicate.jsonl"
        row = assistant("removed", 1.0)
        row.pop("id")
        header = {"type": "session", "version": 3, "id": "native-idless"}
        path.write_text("\n".join([
            json.dumps(header),
            json.dumps(row),
            json.dumps(row, separators=(",", ":")),
            "",
        ]), encoding="utf-8")

        result = self.accountant.public_summary(self.accountant.session_usage(path, "native-idless"))
        self.assertEqual((result["cost_usd"], result["usage_records"]), (1.0, 1))

    def test_paid_errored_and_aborted_assistant_messages_are_counted(self):
        path = self.root / "settled-errors.jsonl"
        errored = assistant("errored", 1.25)
        errored["message"]["stopReason"] = "error"
        errored["message"]["errorMessage"] = "synthetic failure"
        aborted = assistant("aborted", .75)
        aborted["message"]["stopReason"] = "aborted"
        write_session(path, "native-settled-errors", [errored, aborted])

        result = self.accountant.public_summary(self.accountant.session_usage(path, "native-settled-errors"))
        self.assertEqual((result["cost_usd"], result["status"], result["usage_records"]), (2.0, "complete", 2))

    def test_latest_validated_native_selection_wins_over_startup_state(self):
        path = self.root / "changed-model.jsonl"
        write_session(path, "native-changed", [
            assistant("first", provider="synthetic", model="startup"),
            {"type": "model_change", "id": "change", "provider": "synthetic", "modelId": "later"},
            {"type": "thinking_level_change", "id": "thinking", "thinkingLevel": "xhigh"},
        ])
        parsed = self.accountant.session_usage(path, "native-changed")
        selection = FirstMateRuntime._selection({
            "kind": "worker", "actual_model": "synthetic/startup", "actual_thinking": "low",
            "model_selection": {"profile": "execution", "requested_model": "synthetic/requested",
                                "requested_thinking": "high", "actual_model": None,
                                "actual_thinking": None, "source": "host_policy"}}, parsed)
        self.assertEqual(selection["requested_model"], "synthetic/requested")
        self.assertEqual((selection["actual_model"], selection["actual_thinking"]),
                         ("synthetic/later", "xhigh"))
        self.assertNotIn("_actual_model", self.accountant.public_summary(parsed))

    def test_extended_message_roles_do_not_change_usage_coverage(self):
        path = self.root / "extended-message-roles.jsonl"
        write_session(path, "native-extended-roles", [
            assistant("paid", 1.5),
            {"type": "message", "id": "bash", "message": {
                "role": "bashExecution", "command": "printf synthetic", "output": "synthetic",
                "exitCode": 0, "cancelled": False, "truncated": False, "timestamp": 1}},
            {"type": "message", "id": "custom", "message": {
                "role": "custom", "customType": "synthetic", "content": "synthetic",
                "display": False, "timestamp": 2}},
            {"type": "message", "id": "branch", "message": {
                "role": "branchSummary", "summary": "synthetic", "fromId": "paid", "timestamp": 3}},
            {"type": "message", "id": "compaction", "message": {
                "role": "compactionSummary", "summary": "synthetic",
                "tokensBefore": 16, "timestamp": 4}},
        ])

        result = self.accountant.public_summary(
            self.accountant.session_usage(path, "native-extended-roles"))
        self.assertEqual(result["status"], "complete")
        self.assertEqual((result["cost_usd"], result["usage_records"]), (1.5, 1))
        self.assertEqual((result["input_tokens"], result["output_tokens"],
                          result["cache_read_tokens"], result["cache_write_tokens"],
                          result["total_tokens"]), (10, 2, 3, 1, 16))

    def test_empty_zero_differs_from_missing_corrupt_and_invalid_numeric_cost(self):
        empty = self.root / "empty.jsonl"
        write_session(empty, "native-empty")
        valid = self.accountant.public_summary(self.accountant.session_usage(empty, "native-empty"))
        self.assertEqual((valid["cost_usd"], valid["status"], valid["known_cost_sessions"]), (0.0, "complete", 1))

        for name, value in (("missing", None), ("nan", float("nan")), ("bool", True), ("negative", -1)):
            path = self.root / f"{name}.jsonl"
            broken = usage(1)
            if value is None:
                broken["cost"].pop("total")
            else:
                broken["cost"]["total"] = value
            write_session(path, "native-" + name, [assistant("entry", use=broken)])
            result = self.accountant.public_summary(self.accountant.session_usage(path, "native-" + name))
            self.assertIsNone(result["cost_usd"])
            self.assertEqual(result["status"], "unavailable")
            self.assertEqual(result["missing_cost_records"], 1)

        invalid_tokens = self.root / "invalid-tokens.jsonl"
        broken_tokens = usage(2.0)
        broken_tokens["input"] = True
        broken_tokens["output"] = -1
        write_session(invalid_tokens, "native-invalid-tokens", [assistant("entry", use=broken_tokens)])
        result = self.accountant.public_summary(self.accountant.session_usage(invalid_tokens, "native-invalid-tokens"))
        self.assertEqual((result["cost_usd"], result["status"]), (2.0, "partial"))
        self.assertEqual((result["input_tokens"], result["output_tokens"]), (0, 0))

        corrupt = self.root / "corrupt.jsonl"
        corrupt.write_bytes(b'{"type":"session","id":"native-corrupt"}\nnot-json\n')
        result = self.accountant.public_summary(self.accountant.session_usage(corrupt, "native-corrupt"))
        self.assertIsNone(result["cost_usd"])
        self.assertEqual(result["status"], "unavailable")

    def test_huge_numbers_and_aggregate_overflow_are_partial_and_json_safe(self):
        huge_token_path = self.root / "huge-token.jsonl"
        huge_tokens = usage(1.0, input=MAX_SAFE_INTEGER + 1)
        write_session(huge_token_path, "native-huge-token", [assistant("huge", use=huge_tokens)])
        huge_token = self.accountant.public_summary(
            self.accountant.session_usage(huge_token_path, "native-huge-token"))
        self.assertEqual((huge_token["input_tokens"], huge_token["cost_usd"], huge_token["status"]),
                         (0, 1.0, "partial"))

        huge_cost_path = self.root / "huge-cost.jsonl"
        huge_cost = usage(1.0)
        huge_cost["cost"]["total"] = 10 ** 400
        write_session(huge_cost_path, "native-huge-cost", [assistant("huge-cost", use=huge_cost)])
        huge_cost_result = self.accountant.public_summary(
            self.accountant.session_usage(huge_cost_path, "native-huge-cost"))
        self.assertIsNone(huge_cost_result["cost_usd"])
        self.assertEqual(huge_cost_result["status"], "unavailable")

        left_path = self.root / "overflow-left.jsonl"
        right_path = self.root / "overflow-right.jsonl"
        write_session(left_path, "native-overflow-left", [
            assistant("left", use=usage(1e308, input=MAX_SAFE_INTEGER))])
        write_session(right_path, "native-overflow-right", [
            assistant("right", use=usage(1e308, input=1))])
        combined = aggregate_usage([
            self.accountant.session_usage(left_path, "native-overflow-left"),
            self.accountant.session_usage(right_path, "native-overflow-right"),
        ], updated_at="2026-01-01T00:00:00Z")
        self.assertEqual(combined["input_tokens"], MAX_SAFE_INTEGER)
        self.assertEqual(combined["cost_usd"], 1e308)
        self.assertEqual(combined["status"], "partial")
        self.assertLessEqual(max(combined[name] for name in (
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
            "total_tokens", "usage_records", "missing_cost_records", "session_count",
            "known_cost_sessions")), MAX_SAFE_INTEGER)
        json.dumps(combined, allow_nan=False)

    def test_malformed_messages_and_summaries_without_usage_are_incomplete(self):
        path = self.root / "missing-summary-usage.jsonl"
        write_session(path, "native-missing-summary", [
            {"type": "message", "id": "malformed", "message": "not-an-object"},
            {"type": "message", "id": "missing-role", "message": {"content": []}},
            {"type": "compaction", "id": "compact-missing",
             "retainedTail": [{"role": "assistant", "usage": usage(99)}]},
            {"type": "branch_summary", "id": "branch-missing"},
        ])
        result = self.accountant.public_summary(
            self.accountant.session_usage(path, "native-missing-summary"))
        self.assertIsNone(result["cost_usd"])
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual((result["usage_records"], result["missing_cost_records"]), (2, 2))
        self.assertEqual(result["total_tokens"], 0)

    def test_partial_final_line_is_ignored_then_stat_change_refreshes_cache(self):
        path = self.root / "growing.jsonl"
        write_session(path, "native-growing", [assistant("one", 1.0)])
        first = self.accountant.session_usage(path, "native-growing")
        self.assertIs(first, self.accountant.session_usage(path, "native-growing"))
        with path.open("ab") as handle:
            handle.write(json.dumps(assistant("two", 2.0)).encode())
        partial = self.accountant.public_summary(self.accountant.session_usage(path, "native-growing"))
        self.assertEqual((partial["cost_usd"], partial["status"]), (1.0, "partial"))
        with path.open("ab") as handle:
            handle.write(b"\n")
        complete = self.accountant.public_summary(self.accountant.session_usage(path, "native-growing"))
        self.assertEqual((complete["cost_usd"], complete["status"]), (3.0, "complete"))

        restarted = FirstMateUsage(self.root)
        self.assertEqual(restarted.session_usage(path, "native-growing")["cost_usd"], 3.0)

    def test_vanished_source_preserves_cached_cost_as_stale_partial(self):
        path = self.root / "vanished.jsonl"
        write_session(path, "native-vanished", [assistant("one", 2.5)])
        self.assertEqual(self.accountant.session_usage(path, "native-vanished")["status"], "complete")
        path.unlink()
        result = self.accountant.public_summary(self.accountant.session_usage(path, "native-vanished"))
        self.assertEqual(result["cost_usd"], 2.5)
        self.assertEqual(result["status"], "partial")
        self.assertTrue(result["stale"])

    def test_warm_cache_identity_mismatch_never_reuses_previous_identity(self):
        path = self.root / "warm-mismatch.jsonl"
        write_session(path, "expected-native", [assistant("one", 2.0)])
        warmed = self.accountant.session_usage(path, "expected-native")
        self.assertEqual(warmed["_session_id"], "expected-native")
        write_session(path, "different-native-with-longer-id", [assistant("replacement", 9.0)])

        mismatch = self.accountant.session_usage(path, "expected-native")
        self.assertIsNone(mismatch["cost_usd"])
        self.assertIsNone(mismatch["_session_id"])
        self.assertFalse(mismatch["_identity_valid"])
        self.assertNotIn("stale", mismatch)
        self.assertEqual(len(self.accountant._cache), 1)
        path.unlink()
        vanished_mismatch = self.accountant.session_usage(path, "expected-native")
        self.assertIsNone(vanished_mismatch["cost_usd"])
        self.assertNotIn("stale", vanished_mismatch)

    def test_read_error_preserves_previous_cost_as_stale(self):
        path = self.root / "read-error.jsonl"
        write_session(path, "native-read-error", [assistant("one", 3.0)])
        self.accountant.session_usage(path, "native-read-error")
        with path.open("ab") as handle:
            handle.write(b"\n")
        with mock.patch.object(Path, "open", side_effect=OSError("synthetic read failure")):
            result = self.accountant.public_summary(
                self.accountant.session_usage(path, "native-read-error"))
        self.assertEqual((result["cost_usd"], result["status"]), (3.0, "partial"))
        self.assertTrue(result["stale"])

    def test_header_mismatch_and_path_escape_never_attribute_cost(self):
        mismatch = self.root / "mismatch.jsonl"
        write_session(mismatch, "other-native", [assistant("one", 9.0)])
        self.assertIsNone(self.accountant.session_usage(mismatch, "expected-native")["cost_usd"])
        outside = Path(self.temp.name) / "outside.jsonl"
        write_session(outside, "expected-native", [assistant("one", 9.0)])
        self.assertIsNone(self.accountant.session_usage(outside, "expected-native")["cost_usd"])


class FirstMateUsageInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / "project"
        self.cwd.mkdir()
        self.store = FirstMateStore(self.root / "first-mate.sqlite3")
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": ""}, runtime_root=self.root / "runtime")
        self.feature = self.store.create_feature({
            "title": "Synthetic task", "goal": "Account for managed work",
            "cwd": str(self.cwd), "request_id": "feature"})

    def stage(self):
        message = self.store.claim_message(self.feature["id"], self.runtime.owner)
        visit = self.store.start_visit(self.feature["id"], "implementation", "Implementation", "visit", 1, message["id"])
        self.store.finish_message(message["id"], self.runtime.owner, "Started")
        return visit

    def worker(self, visit, suffix, *, parent=None, cost=1.0):
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Worker " + suffix, "role": "implementer", "prompt": "Synthetic work",
            "request_id": "assignment-" + suffix,
            "metadata": {"parent_assignment_id": parent["id"]} if parent else {}})
        claim = self.store.claim_assignment(assignment["id"], self.runtime.owner)
        job = self.runtime._new_job(self.feature, kind="worker", prompt="Synthetic work", claim=claim)
        _write_json(self.runtime._job_dir(job) / "started.json", {"pid": 1})
        native = "native-" + suffix
        write_session(Path(job["session_file"]), native, [assistant("entry-" + suffix, cost)])
        self.runtime._bind(job, native, job["session_file"])
        return self.store.get_assignment(assignment["id"]), job

    def test_coordinator_workers_retries_nested_subtrees_and_advisors_count_once(self):
        visit = self.stage()
        parent, parent_job = self.worker(visit, "parent", cost=2.0)
        child, _ = self.worker(visit, "child", parent=parent, cost=3.0)

        advisor = self.runtime._new_job(self.feature, kind="advisor", prompt="Inspect", claim={"id": "advisor"}, parent_job=parent_job)
        _write_json(self.runtime._job_dir(advisor) / "started.json", {"pid": 2})
        write_session(Path(advisor["session_file"]), "native-advisor", [assistant("advisor-entry", .5)])
        self.runtime._bind(advisor, "native-advisor", advisor["session_file"])

        # A continuation points at the same session and must not duplicate it.
        continuation = {**parent_job, "id": "continuation", "parent_job_id": parent_job["id"]}
        directory = self.runtime.jobs_root / continuation["id"]
        _write_json(directory / "job.json", continuation)
        _write_json(directory / "started.json", {"pid": 3})

        detail = self.runtime.snapshot(self.feature["id"])
        parent_view = next(row for row in detail["assignments"] if row["id"] == parent["id"])
        child_view = next(row for row in detail["assignments"] if row["id"] == child["id"])
        self.assertEqual(parent_view["usage"]["cost_usd"], 2.5)
        self.assertEqual(parent_view["subtree_usage"]["cost_usd"], 5.5)
        self.assertEqual(child_view["usage"]["cost_usd"], 3.0)
        self.assertEqual(detail["feature"]["usage"]["cost_usd"], 5.5)
        self.assertEqual(detail["feature"]["usage"]["session_count"], 3)
        advisor_view = next(row for row in detail["sessions"] if row["native_session_id"] == "native-advisor")
        self.assertEqual(advisor_view["kind"], "advisor")
        self.assertEqual(advisor_view["parent_session_id"], "native-parent")
        advisor_transcript = self.runtime.session("native-advisor", limit=1)
        self.assertEqual(advisor_transcript["session"]["kind"], "advisor")
        self.assertEqual(advisor_transcript["usage"]["cost_usd"], .5)

    def test_coordinator_reuse_and_worker_retry_deduplicate_by_native_session(self):
        first = self.store.claim_message(self.feature["id"], self.runtime.owner)
        coordinator = self.runtime._new_job(self.feature, kind="coordinator", prompt="First", claim=first)
        _write_json(self.runtime._job_dir(coordinator) / "started.json", {"pid": 1})
        write_session(Path(coordinator["session_file"]), "native-coordinator", [assistant("turn-one", 1.0)])
        self.runtime._bind(coordinator, "native-coordinator", coordinator["session_file"])
        self.store.finish_message(first["id"], self.runtime.owner, "First turn")

        direction = self.store.append_human_message(self.feature["id"], "Continue", "continue")
        second_claim = self.store.claim_message(self.feature["id"], self.runtime.owner)
        second = self.runtime._new_job(self.store.get_feature(self.feature["id"]), kind="coordinator", prompt="Second", claim=second_claim)
        _write_json(self.runtime._job_dir(second) / "started.json", {"pid": 2})
        self.runtime._bind(second, "native-coordinator", second["session_file"])
        write_session(Path(second["session_file"]), "native-coordinator", [assistant("turn-one", 1.0), assistant("turn-two", 1.5)])
        visit = self.store.start_visit(self.feature["id"], "implementation", "Implementation", "visit-retry", 1, direction["id"])
        self.store.finish_message(second_claim["id"], self.runtime.owner, "Started")

        original, _ = self.worker(visit, "retry-one", cost=2.0)
        self.store.recover_assignment(original["id"], original["generation"], "Synthetic interruption", "recover", verified_stopped=True)
        replacement_claim = self.store.claim_assignment(original["id"], self.runtime.owner)
        replacement = self.runtime._new_job(self.feature, kind="worker", prompt="Retry", claim=replacement_claim)
        _write_json(self.runtime._job_dir(replacement) / "started.json", {"pid": 3})
        write_session(Path(replacement["session_file"]), "native-retry-two", [assistant("retry-two", 3.0)])
        self.runtime._bind(replacement, "native-retry-two", replacement["session_file"])

        detail = self.runtime.snapshot(self.feature["id"])
        assignment = next(row for row in detail["assignments"] if row["id"] == original["id"])
        self.assertEqual(assignment["usage"]["cost_usd"], 5.0)
        self.assertEqual(detail["feature"]["usage"]["cost_usd"], 7.5)
        self.assertEqual(detail["feature"]["usage"]["session_count"], 3)
        self.assertEqual(len([row for row in detail["sessions"] if row["kind"] == "coordinator"]), 1)

    def test_coordinator_rotation_retains_both_session_costs(self):
        first_claim = self.store.claim_message(self.feature["id"], self.runtime.owner)
        first_job = self.runtime._new_job(self.feature, kind="coordinator", prompt="First", claim=first_claim)
        _write_json(self.runtime._job_dir(first_job) / "started.json", {"pid": 1})
        write_session(Path(first_job["session_file"]), "native-rotation-one", [assistant("one", 1.25)])
        self.runtime._bind(first_job, "native-rotation-one", first_job["session_file"])
        self.store.finish_message(first_claim["id"], self.runtime.owner, "First complete")
        self.store.rotate_coordinator_session(
            self.feature["id"], "native-rotation-one", "rotate-synthetic", verified_stopped=True)
        _write_json(self.runtime._job_dir(first_job) / "finalized.json", {"status": "complete"})

        self.store.append_human_message(self.feature["id"], "Continue", "rotation-direction")
        second_claim = self.store.claim_message(self.feature["id"], self.runtime.owner)
        refreshed = self.store.get_feature(self.feature["id"])
        second_job = self.runtime._new_job(refreshed, kind="coordinator", prompt="Second", claim=second_claim)
        _write_json(self.runtime._job_dir(second_job) / "started.json", {"pid": 2})
        write_session(Path(second_job["session_file"]), "native-rotation-two", [assistant("two", 2.75)])
        self.runtime._bind(second_job, "native-rotation-two", second_job["session_file"])

        detail = self.runtime.snapshot(self.feature["id"])
        self.assertEqual(detail["feature"]["usage"]["cost_usd"], 4.0)
        self.assertEqual(detail["feature"]["usage"]["session_count"], 2)
        self.assertEqual({row["native_session_id"] for row in detail["sessions"]}, {
            "native-rotation-one", "native-rotation-two"})

    def test_cross_feature_alias_and_unbound_header_conflict_are_unavailable(self):
        visit = self.stage()
        _, owner_job = self.worker(visit, "owned", cost=6.0)
        second_feature = self.store.create_feature({
            "title": "Other synthetic task", "goal": "Must not share usage",
            "cwd": str(self.cwd), "request_id": "second-feature"})
        second_claim = self.store.claim_message(second_feature["id"], self.runtime.owner)
        crash_gap = self.runtime._new_job(
            second_feature, kind="coordinator", prompt="Other", claim=second_claim)
        owner_path = Path(owner_job["session_file"])
        crash_gap["session_file"] = str(owner_path.parent / ".." / owner_path.parent.name / owner_path.name)
        crash_gap.pop("native_session_id", None)
        self.runtime._save_job(crash_gap)
        _write_json(self.runtime._job_dir(crash_gap) / "started.json", {"pid": 7})

        owner_total = self.runtime.snapshot(self.feature["id"])["feature"]["usage"]
        other_total = self.runtime.snapshot(second_feature["id"])["feature"]["usage"]
        self.assertEqual((owner_total["cost_usd"], owner_total["status"]), (None, "unavailable"))
        self.assertEqual((other_total["cost_usd"], other_total["status"]), (None, "unavailable"))
        with self.assertRaisesRegex(ValueError, "conflicting First Mate ownership"):
            self.runtime.session("native-owned")

    def test_started_missing_session_makes_known_subtotal_partial_but_pending_job_does_not(self):
        visit = self.stage()
        assignment, _ = self.worker(visit, "known", cost=4.0)
        claim = {**assignment, "id": assignment["id"], "dispatch_id": "missing-dispatch"}
        missing = self.runtime._new_job(self.feature, kind="worker", prompt="Missing", claim=claim)
        _write_json(self.runtime._job_dir(missing) / "started.json", {"pid": 4})
        Path(missing["session_file"]).unlink(missing_ok=True)
        pending = self.runtime._new_job(self.feature, kind="advisor", prompt="Pending", claim={"id": "pending"})
        self.assertFalse((self.runtime._job_dir(pending) / "started.json").exists())

        total = self.runtime.snapshot(self.feature["id"])["feature"]["usage"]
        self.assertEqual(total["cost_usd"], 4.0)
        self.assertEqual(total["status"], "partial")
        self.assertEqual(total["session_count"], 2)

    def test_handoff_predecessor_and_successor_are_both_retained_in_usage(self):
        visit = self.stage()
        predecessor, predecessor_job = self.worker(visit, "handoff-before", cost=1.25)
        handoff = self.store.begin_handoff(predecessor["id"], predecessor["generation"], "handoff", "Synthetic checkpoint")
        self.runtime.environ["HERDR_FIRST_MATE_WORKER_MODEL"] = "synthetic/current-worker"
        self.runtime.environ["HERDR_FIRST_MATE_WORKER_THINKING"] = "high"
        claim = {**predecessor, "dispatch_id": "handoff:" + handoff["id"]}
        successor = self.runtime._new_job(self.feature, kind="worker", prompt="Continue", claim=claim,
                                          parent_job=predecessor_job, handoff_id=handoff["id"])
        self.assertEqual((successor["model"], successor["thinking"]),
                         ("synthetic/current-worker", "high"))
        _write_json(self.runtime._job_dir(successor) / "started.json", {"pid": 5})
        write_session(Path(successor["session_file"]), "native-handoff-after", [assistant("after", 2.75)])
        self.runtime._bind(successor, "native-handoff-after", successor["session_file"])

        detail = self.runtime.snapshot(self.feature["id"])
        assignment = detail["assignments"][0]
        self.assertEqual(assignment["usage"]["cost_usd"], 4.0)
        self.assertEqual(assignment["usage"]["session_count"], 2)
        after = next(row for row in detail["sessions"] if row["native_session_id"] == "native-handoff-after")
        self.assertEqual(after["parent_session_id"], "native-handoff-before")

    def test_ledger_only_session_remains_exactly_openable_after_job_spool_is_absent(self):
        visit = self.stage()
        _, job = self.worker(visit, "ledger-only", cost=2.25)
        shutil.rmtree(self.runtime._job_dir(job))

        transcript = self.runtime.session("native-ledger-only", limit=1)
        self.assertEqual(transcript["session"]["feature_id"], self.feature["id"])
        self.assertEqual(transcript["session"]["kind"], "worker")
        self.assertEqual(transcript["usage"]["cost_usd"], 2.25)

    def test_whole_session_usage_is_independent_of_transcript_page(self):
        visit = self.stage()
        _, job = self.worker(visit, "paged", cost=1.75)
        rows = [assistant(str(index), .25) for index in range(150)]
        write_session(Path(job["session_file"]), "native-paged", rows)
        first = self.runtime.session("native-paged", limit=1)
        older = self.runtime.session("native-paged", before=10, limit=2)
        self.assertEqual(first["usage"], older["usage"])
        self.assertEqual(first["usage"]["cost_usd"], 37.5)
        self.assertEqual(first["session"]["usage"], first["usage"])

    def test_unbounded_inventory_drives_total_while_public_sessions_stay_truncated(self):
        sessions_root = self.runtime.root / "sessions"
        now = "2026-01-01T00:00:00Z"
        for index in range(1001):
            native = f"native-many-{index:04d}"
            path = sessions_root / native / "session.jsonl"
            write_session(path, native, [assistant("entry", .01)])
            self.store._db.execute(
                "INSERT INTO fm_sessions VALUES(?,?,?,?,?,?,?,?,?)",
                (native, self.feature["id"], None, 0, "synthetic", "retained", str(path), now, now))
        detail = self.runtime.snapshot(self.feature["id"])
        self.assertEqual(len(detail["sessions"]), 1000)
        self.assertTrue(detail["sessions_truncated"])
        self.assertAlmostEqual(detail["feature"]["usage"]["cost_usd"], 10.01)
        self.assertEqual(detail["feature"]["usage"]["session_count"], 1001)

    def test_list_detail_and_model_settings_shape_share_same_total(self):
        visit = self.stage()
        self.worker(visit, "shared", cost=1.5)
        listed = self.runtime.list_features()[0]["usage"]
        detail = self.runtime.snapshot(self.feature["id"])["feature"]["usage"]
        self.assertEqual(listed, detail)
        self.assertEqual(listed["cost_usd"], 1.5)


if __name__ == "__main__":
    unittest.main()
