"""Durable verification evidence tests over the real store and a temporary Git repo.

The fixtures are fully synthetic. They exercise the exact incident shape: a
feature records broad coverage, the source revision advances, a later gate set
silently drops suites, and the assessment must keep naming them until current
complete evidence exists. No Pi process or model is used; only retained records
and Git observations are evaluated.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
from pathlib import Path

from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateError, FirstMateStore

SUITES = ["SuiteOne", "SuiteTwo", "SuiteThree", "SuiteFour", "SuiteFive", "SuiteSix"]


def suite(name: str, package: str = "pkg/app", configuration: str = "") -> dict:
    return {"package": package, "suite": name, "configuration": configuration, "selector": ""}


def gate(name: str, outcome: str = "passed", package: str = "pkg/app", **counts) -> dict:
    return {"suite": suite(name, package), "outcome": outcome, "passed_count": counts.get("passed_count"),
            "failed_count": counts.get("failed_count"), "skipped_count": counts.get("skipped_count")}


class VerificationRuntimeTests(unittest.TestCase):
    def prepare_verified_feature(self):
        self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        self.record_run("read-budget-evidence", SUITES, revision=self.base)
        current = self.runtime.verification_assessment(self.feature["id"])
        self.assertEqual(current["status"], "verified")
        return {**self.store.get_feature(self.feature["id"]), "verification": current}

    def test_expired_display_budget_keeps_prior_green_historical(self):
        feature = self.prepare_verified_feature()
        with patch.object(self.runtime, "_git", side_effect=AssertionError("Git after deadline")):
            value = self.runtime._live_verification(feature, deadline=0)
        self.assertEqual(value["status"], "unavailable")
        self.assertEqual(value["historical_evidence"]["status"], "verified")
        self.assertIn("time budget", value["coverage_reasons"][0])

    def test_git_timeout_stops_display_scope_and_restores_gate_timeout(self):
        feature = self.prepare_verified_feature()
        with patch("herdr_harness.first_mate_runtime.subprocess.run",
                   side_effect=subprocess.TimeoutExpired(["git"], 0.01)) as git:
            value = self.runtime._live_verification(feature)
        self.assertEqual(value["status"], "unavailable")
        self.assertEqual(value["historical_evidence"]["status"], "verified")
        self.assertEqual(git.call_count, 1, "Do not keep scanning worktrees after timeout")
        self.assertGreater(git.call_args.kwargs["timeout"], 0)
        self.assertLessEqual(git.call_args.kwargs["timeout"], 3)
        self.assertEqual(git.call_args.kwargs["env"]["GIT_OPTIONAL_LOCKS"], "0")
        with patch("herdr_harness.first_mate_runtime.subprocess.run",
                   return_value=subprocess.CompletedProcess(["git"], 0, self.base, "")) as git:
            self.assertEqual(self.runtime._git(str(self.repo), "rev-parse", "HEAD"), self.base)
        self.assertEqual(git.call_args.kwargs["timeout"], 30)
        self.assertNotIn("env", git.call_args.kwargs)
        self.assertEqual(self.runtime.verification_assessment(self.feature["id"])["status"], "verified")

    def test_late_success_is_not_cached_or_promoted_to_current_verified(self):
        feature = self.prepare_verified_feature()
        now = [100.0]

        def assessment(_):
            now[0] = 104.0
            return feature["verification"]

        with patch.object(self.runtime, "_verification_read_identity", return_value="same"), \
             patch.object(self.runtime, "_compute_live_verification", side_effect=assessment), \
             patch("herdr_harness.first_mate_runtime.time.monotonic", side_effect=lambda: now[0]):
            value = self.runtime._live_verification(feature)
        self.assertEqual(value["status"], "unavailable")
        self.assertIsNone(self.runtime._verification_read_context.deadline)
        self.assertEqual(self.runtime._assessment_reads._entries, {})
        self.assertEqual(self.runtime._assessment_reads._flights, {})

    def test_slow_verification_does_not_hide_list_or_chat_or_block_workflow_gate(self):
        feature = self.prepare_verified_feature()
        entered, release = threading.Event(), threading.Event()
        original = self.runtime._verification_read_identity

        def identity(feature_id):
            entered.set()
            self.assertTrue(release.wait(5))
            return original(feature_id)

        with ThreadPoolExecutor(max_workers=1) as pool, \
             patch.object(self.runtime, "_verification_read_identity", side_effect=identity):
            first = pool.submit(self.runtime._live_verification, feature)
            try:
                self.assertTrue(entered.wait(5))
                features = self.runtime.list_features()
                self.assertEqual([row["id"] for row in features], [feature["id"]])
                self.assertEqual(features[0]["verification"]["status"], "unavailable")
                chat = self.runtime.read_view(feature["id"])
                self.assertEqual(chat["feature"]["id"], feature["id"])
                self.assertTrue(chat["messages"])
                self.assertEqual(chat["feature"]["verification"]["status"], "unavailable")
                self.assertEqual(self.runtime.verification_assessment(feature["id"])["status"], "verified")
            finally:
                release.set()
            self.assertEqual(first.result(timeout=5)["status"], "verified")

    def test_display_deadline_does_not_leak_to_other_threads(self):
        self.prepare_verified_feature()
        self.runtime._verification_read_context.deadline = 0
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                result = pool.submit(self.runtime.verification_assessment, self.feature["id"]).result(timeout=10)
            self.assertEqual(result["status"], "verified")
        finally:
            self.runtime._verification_read_context.deadline = None

    def test_feature_list_shares_one_verification_budget(self):
        self.prepare_verified_feature()
        self.store.create_feature({"title": "Another synthetic feature", "goal": "Inspect only",
                                   "cwd": str(self.repo), "request_id": "second-feature"})
        with patch.object(self.runtime, "_live_verification", wraps=self.runtime._live_verification) as assess, \
             patch("herdr_harness.first_mate_runtime.VERIFICATION_READ_SECONDS", 0), \
             patch.object(self.runtime, "_git", side_effect=AssertionError("Git after list deadline")):
            features = self.runtime.list_features()
        self.assertEqual(len(features), 2)
        self.assertEqual(assess.call_count, 2)
        self.assertEqual(assess.call_args_list[0].kwargs["deadline"], assess.call_args_list[1].kwargs["deadline"])
        self.assertTrue(all(row["verification"]["status"] == "unavailable" for row in features))

    def test_verification_and_worker_policy_reads_do_not_materialize_telemetry(self):
        assignment = self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        self.record_run("synthetic-verification", SUITES, revision=self.base)
        self.store.append_event(self.feature["id"], "pi.synthetic", "Synthetic telemetry", {"text": "unneeded"})
        original = self.store.snapshot

        def journal_only(feature_id, events="all"):
            self.assertEqual(events, "journal", "A policy/verification read must not fetch the full conversation")
            return original(feature_id, events=events)

        with patch.object(self.store, "snapshot", side_effect=journal_only) as snapshots:
            self.assertEqual(self.runtime.list_features()[0]["verification"]["status"], "verified")
            self.assertEqual(self.runtime.board(self.feature["id"])["feature"]["verification"]["status"], "verified")
            self.assertEqual(snapshots.call_count, 0)
            result = self.runtime.snapshot(self.feature["id"], events="journal")
            self.assertEqual(snapshots.call_count, 1)
        self.assertEqual(result["feature"]["verification"]["status"], "verified")
        self.assertEqual(result["assignments"][0]["id"], assignment["id"])
        self.assertIn("model_selection", result["assignments"][0])
        self.assertFalse(any(event["type"].startswith("pi.") for event in result["events"]))

    def test_targeted_stage_lookup_keeps_feature_ownership_and_missing_visit_behavior(self):
        assignment = self.stage_and_assignment()
        feature_id, visit_id = self.feature["id"], assignment["visit_id"]
        self.assertEqual(self.store.visit_stage_key(feature_id, visit_id), "implementation")
        self.assertIsNone(self.store.visit_stage_key("foreign-feature", visit_id))
        self.assertIsNone(self.store.visit_stage_key(feature_id, "missing-visit"))
        self.assertIsNone(self.runtime._stage_key({"id": feature_id, "current_visit_id": None}))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "project"
        (self.repo / "pkg/app/Sources").mkdir(parents=True)
        (self.repo / "pkg/app/Sources/Feature.swift").write_text("// synthetic feature\n")
        (self.repo / "pkg/other/Sources").mkdir(parents=True)
        (self.repo / "pkg/other/Sources/Other.swift").write_text("// synthetic other\n")
        (self.repo / "README.md").write_text("Synthetic project\n")
        for args in (["init"], ["config", "user.email", "test@example.invalid"],
                     ["config", "user.name", "Test"], ["add", "."], ["commit", "-m", "Synthetic baseline"]):
            subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, check=True)
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")
        self.feature = self.store.create_feature({
            "title": "Synthetic feature", "goal": "Change the synthetic package",
            "cwd": str(self.repo), "request_id": "create"})
        self.base = self.head()
        self.workspace = FirstMateRuntime._workspace_identity(str(self.repo))

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def head(self) -> str:
        return subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, message: str) -> str:
        with (self.repo / "pkg/app/Sources/Feature.swift").open("a") as handle:
            handle.write(f"// {message}\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-m", message], capture_output=True, check=True)
        return self.head()

    def stage_and_assignment(self, *, suffix: str = "1", base: str | None = None,
                             worktree: Path | None = None, feature: dict | None = None):
        feature = feature or self.feature
        message = self.store.claim_message(feature["id"], "coordinator")
        visit = self.store.start_visit(feature["id"], "implementation", "Implementation",
                                       "visit-" + suffix, feature["revision"], message["id"])
        self.store.finish_message(message["id"], "coordinator", "Starting implementation.")
        path = str(worktree or self.repo)
        metadata = {"workspace_mode": "read_only", "worktree_path": path,
                    "base_revision": base or self.base}
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Implement synthetic change " + suffix, "role": "implementer",
            "prompt": "Make the synthetic change.", "request_id": "assignment-" + suffix,
            "metadata": metadata})
        claimed = self.store.claim_assignment(assignment["id"], "worker-" + suffix)
        self.store.bind_session(assignment["id"], claimed["generation"], "worker-" + suffix,
                                "native-" + suffix, str(self.root / f"session-{suffix}.jsonl"),
                                "run-" + suffix)
        return self.store.get_assignment(assignment["id"])

    def record_inventory(self, names: list[str], *, revision: str, package: str = "pkg/app",
                         state: str = "complete", workspace: str | None = None) -> None:
        self.store.record_suite_inventory(self.feature["id"], {
            "workspace": workspace or self.workspace, "package": package, "state": state,
            "revision": revision, "suites": [suite(name, package) for name in names],
            "evidence": "synthetic manifest", "source": "manifest"}, None)

    def record_run(self, run_id: str, names: list[str], *, revision: str, outcome: str = "passed",
                   selected_outcomes: dict | None = None, package: str = "pkg/app",
                   assignment: dict | None = None, workspace: str | None = None,
                   source_state: str = "clean") -> dict:
        gates = []
        for name in names:
            gates.append(gate(name, (selected_outcomes or {}).get(name, outcome), package=package))
        provenance = ({"visit_id": assignment["visit_id"], "assignment_id": assignment["id"],
                       "native_session_id": assignment["native_session_id"],
                       "generation": assignment["generation"]} if assignment else
                      {"visit_id": None, "assignment_id": None, "native_session_id": None, "generation": None})
        return self.store.record_verification(self.feature["id"], {
            "workspace": workspace or self.workspace, "revision": revision, "observed_revision": revision,
            "status": "completed", "gates": gates, "summary": "synthetic batch",
            "source_state": source_state},
            run_id, provenance)["run"]

    def test_six_to_four_omission_survives_restart_and_names_dropped_suites(self):
        self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        broad = self.record_run("run-six", SUITES, revision=self.base)
        first = self.runtime.verification_assessment(self.feature["id"], [broad["id"]])
        self.assertEqual(first["status"], "verified")
        self.assertEqual(first["assessed_revisions"], {self.workspace: self.base})

        advanced = self.commit("advance revision")
        self.record_inventory(SUITES, revision=advanced)
        narrow = self.record_run("run-four", SUITES[:4], revision=advanced)

        # A store restart and a fresh runtime keep the feature-wide history.
        self.store.close()
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")
        assessment = self.runtime.verification_assessment(self.feature["id"], [broad["id"], narrow["id"]])
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(sorted(item["label"] for item in assessment["missing_suites"]),
                         sorted([f"pkg/app/{name}" for name in SUITES[4:]]))
        self.assertEqual(sorted(item["label"] for item in assessment["previously_green_missing"]),
                         sorted([f"pkg/app/{name}" for name in SUITES[4:]]))
        self.assertEqual([entry["label"] for entry in assessment["gate_set"]],
                         sorted(f"pkg/app/{name}" for name in SUITES))
        self.assertEqual(assessment["assessed_revisions"], {self.workspace: advanced})
        self.assertEqual(len(assessment["stale_evidence"]), 1)
        self.assertEqual(assessment["stale_evidence"][0]["run_id"], broad["id"])

    def test_history_survives_worker_handoff_and_a_later_stage(self):
        # Stage one records broad coverage and completes.
        first = self.stage_and_assignment()
        advanced = self.commit("first stage change")
        self.record_inventory(SUITES, revision=advanced)
        broad = self.record_run("run-six", SUITES, revision=advanced, assignment=first)
        self.store.record_outcome(first["id"], first["generation"], first["native_session_id"],
                                  first["input_revision"], "success", "Stage one complete",
                                  "outcome-first", verification_run_ids=[broad["id"]])
        self.store.complete_visit(self.store.get_feature(self.feature["id"])["current_visit_id"],
                                  "Stage one done", "Continue", "complete-first")

        # A later stage runs under a handoff successor and selects only four suites.
        direction = self.store.append_human_message(self.feature["id"], "Run verification", "direction-second")
        claimed_message = self.store.claim_message(self.feature["id"], "coordinator")
        self.assertEqual(claimed_message["id"], direction["id"])
        feature = self.store.get_feature(self.feature["id"])
        visit = self.store.start_visit(self.feature["id"], "verification", "Verification",
                                       "visit-second", feature["revision"], claimed_message["id"])
        self.store.finish_message(claimed_message["id"], "coordinator", "Starting verification.")
        assignment = self.store.create_assignment(visit["id"], {
            "title": "Verify the synthetic change", "role": "reviewer", "prompt": "Verify.",
            "request_id": "assignment-second",
            "metadata": {"workspace_mode": "read_only", "worktree_path": str(self.repo),
                         "base_revision": self.base}})
        claimed = self.store.claim_assignment(assignment["id"], "worker-second")
        self.store.bind_session(assignment["id"], claimed["generation"], "worker-second",
                                "native-second", str(self.root / "session-second.jsonl"), "run-second")
        handoff = self.store.begin_handoff(assignment["id"], claimed["generation"], "handoff-one",
                                           "Checkpointed for successor")
        successor = self.store.bind_handoff_successor(handoff["id"], "native-successor",
                                                      str(self.root / "session-successor.jsonl"),
                                                      "worker-successor", "bind-successor",
                                                      verified_predecessor_stopped=True)
        self.store.acknowledge_handoff(handoff["id"], "native-successor", successor["generation"],
                                       "ack-successor")
        narrow = self.store.record_verification(self.feature["id"], {
            "workspace": self.workspace, "revision": advanced, "observed_revision": advanced,
            "status": "completed", "gates": [gate(name) for name in SUITES[:4]],
            "summary": "handoff successor batch", "source_state": "clean"}, "run-narrow-successor", {
                "visit_id": visit["id"], "assignment_id": assignment["id"],
                "native_session_id": "native-successor", "generation": successor["generation"]})["run"]

        self.assertEqual(self.runtime._default_verification_selection(
            self.store.get_feature(self.feature["id"])), [narrow["id"]])
        assessment = self.runtime.verification_assessment(self.feature["id"], [narrow["id"]])
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(sorted(item["label"] for item in assessment["missing_suites"]),
                         sorted(f"pkg/app/{name}" for name in SUITES[4:]))
        self.assertEqual(sorted(item["label"] for item in assessment["previously_green_missing"]),
                         sorted(f"pkg/app/{name}" for name in SUITES[4:]))
        self.assertEqual([run["id"] for run in self.store.list_verification_runs(self.feature["id"])],
                         [broad["id"], narrow["id"]])

    def test_stale_head_cannot_verify_and_later_failure_supersedes_a_pass(self):
        self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        passed = self.record_run("run-pass", SUITES, revision=self.base)
        self.assertEqual(self.runtime.verification_assessment(self.feature["id"], [passed["id"]])["status"],
                         "verified")

        advanced = self.commit("advance past the passing run")
        stale = self.runtime.verification_assessment(self.feature["id"], [passed["id"]])
        self.assertEqual(stale["status"], "partially_verified")
        self.assertEqual([item["run_id"] for item in stale["stale_evidence"]], [passed["id"]])
        self.assertTrue(any("does not match current" in item["reason"] for item in stale["stale_evidence"]))
        # Detail and status reads show the current stale verdict, not the old green.
        self.assertEqual(self.runtime.feature(self.feature["id"])["verification"]["status"],
                         "partially_verified")
        self.assertEqual(self.runtime.snapshot(self.feature["id"])["feature"]["verification"]["status"],
                         "partially_verified")

        failing = self.record_run("run-fail", SUITES, revision=advanced,
                                  selected_outcomes={"SuiteThree": "failed"})
        self.record_inventory(SUITES, revision=advanced)
        failed = self.runtime.verification_assessment(self.feature["id"], [failing["id"]])
        self.assertEqual(failed["status"], "failed")
        self.assertEqual([item["label"] for item in failed["failing_suites"]], ["pkg/app/SuiteThree"])
        # Selecting only the earlier passing run cannot hide the later failure.
        hidden = self.runtime.verification_assessment(self.feature["id"], [passed["id"]])
        self.assertEqual(hidden["status"], "failed")
        self.assertTrue(any("supersedes" in reason or "omitted" in reason
                            for reason in hidden["coverage_reasons"]))

    def test_never_run_required_suite_is_partial_and_duplicate_names_stay_distinct(self):
        self.stage_and_assignment()
        # Two changed packages each declare a suite with the same display name.
        for path in ("pkg/app/Sources/Feature.swift", "pkg/other/Sources/Other.swift"):
            with (self.repo / path).open("a") as handle:
                handle.write("// changed\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-m", "change both packages"],
                       capture_output=True, check=True)
        current = self.head()
        self.record_inventory(["SharedTests"], revision=current, package="pkg/app")
        self.record_inventory(["SharedTests"], revision=current, package="pkg/other")
        run = self.record_run("run-one", ["SharedTests"], revision=current, package="pkg/app")
        assessment = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([item["label"] for item in assessment["missing_suites"]], ["pkg/other/SharedTests"])
        self.assertEqual([item["label"] for item in assessment["required_suites"]],
                         ["pkg/app/SharedTests", "pkg/other/SharedTests"])

    def test_isolated_workspace_scope_ignores_the_primary_checkout(self):
        worktree = self.root / "isolated-worktree"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-b", "synthetic-isolated",
                        str(worktree), self.base], capture_output=True, check=True)
        self.stage_and_assignment(worktree=worktree)
        with (worktree / "pkg/app/Sources/Feature.swift").open("a") as handle:
            handle.write("// isolated change\n")
        subprocess.run(["git", "-C", str(worktree), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(worktree), "commit", "-m", "isolated change"],
                       capture_output=True, check=True)
        head = subprocess.run(["git", "-C", str(worktree), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        workspace = FirstMateRuntime._workspace_identity(str(worktree))
        self.record_inventory(SUITES, revision=head, workspace=workspace)
        run = self.record_run("run-isolated", SUITES, revision=head, workspace=workspace)
        assessment = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(assessment["status"], "verified")
        self.assertEqual(assessment["assessed_revisions"], {workspace: head})
        self.assertNotIn(self.workspace, assessment["assessed_revisions"])

    def test_unmapped_changed_path_lowers_coverage(self):
        self.stage_and_assignment()
        (self.repo / "untracked-outside.txt").write_text("synthetic\n")
        self.record_inventory(SUITES, revision=self.base)
        run = self.record_run("run-six", SUITES, revision=self.base)
        assessment = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(assessment["unmapped_paths"], [{"workspace": self.workspace,
                                                          "path": "untracked-outside.txt"}])
        self.assertTrue(any("not covered by any discovered package" in reason
                            for reason in assessment["coverage_reasons"]))

    def test_record_verification_is_worker_scoped_idempotent_and_rejects_stale_owners(self):
        assignment = self.stage_and_assignment()
        job = {"kind": "worker", "feature_id": self.feature["id"],
               "claim": {"id": assignment["id"], "generation": assignment["generation"]},
               "native_session_id": assignment["native_session_id"], "cwd": str(self.repo)}
        params = {
            "revision": self.base, "status": "completed", "summary": "one batch",
            "inventory": {"package": "pkg/app", "state": "complete",
                          "suites": [suite(name) for name in SUITES], "evidence": "synthetic"},
            "gates": [gate(name) for name in SUITES],
        }
        first = self.runtime._record_verification(job, params, "verification-request")
        replay = self.runtime._record_verification(job, params, "verification-request")
        self.assertEqual(first["run"]["id"], replay["run"]["id"])
        self.assertEqual(first["verification"]["status"], "verified")
        self.assertEqual(len(self.store.list_verification_runs(self.feature["id"])), 1)
        with self.assertRaises(FirstMateError) as conflict:
            self.runtime._record_verification(job, {**params, "revision": "deadbeef"}, "verification-request")
        self.assertEqual(conflict.exception.code, "idempotency_conflict")

        wrong_session = {**job, "native_session_id": "native-other"}
        with self.assertRaises(FirstMateError) as stale:
            self.runtime._record_verification(wrong_session, params, "verification-other")
        self.assertEqual(stale.exception.code, "stale_owner")
        with self.assertRaises(FirstMateError) as coordinator:
            self.runtime._record_verification({**job, "kind": "coordinator"}, params, "verification-coordinator")
        self.assertEqual(coordinator.exception.code, "stale_owner")

        # Bad evidence references cannot strand otherwise completed work. A
        # foreign feature and an unknown ID get the same generic diagnostic.
        run_id = first["run"]["id"]
        other_feature = self.store.create_feature({
            "title": "Synthetic other feature", "goal": "Other goal",
            "cwd": str(self.repo), "request_id": "create-other"})
        other = self.stage_and_assignment(suffix="2", feature=other_feature)
        result = self.store.record_outcome(other["id"], other["generation"], other["native_session_id"],
                                          other["input_revision"], "success", "Done", "outcome-other",
                                          verification_run_ids=[run_id, "fmvr_invented"])
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["verification_run_ids"], [])
        recording = result["verification_recording"]
        self.assertEqual(recording["state"], "incomplete")
        self.assertEqual([entry["reason"] for entry in recording["unresolved_references"]],
                         ["unavailable_in_assignment_lineage"] * 2)

        # A valid outcome retains the exact run references for later selection.
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Verified", "outcome-linked", verification_run_ids=[run_id])
        linked = self.store.get_assignment(assignment["id"])
        self.assertEqual(linked["verification_run_ids"], [run_id])
        feature = self.store.get_feature(self.feature["id"])
        self.assertEqual(self.runtime._default_verification_selection(feature), [run_id])

    def handoff(self, assignment):
        handoff = self.store.begin_handoff(assignment["id"], assignment["generation"],
                                           "handoff-evidence", "Finished; report retained evidence.")
        successor = self.store.bind_handoff_successor(
            handoff["id"], "native-evidence-successor", str(self.root / "successor.jsonl"),
            "evidence-successor", "bind-evidence-successor", verified_predecessor_stopped=True)
        self.store.acknowledge_handoff(handoff["id"], "native-evidence-successor",
                                       successor["generation"], "ack-evidence-successor")
        return self.store.get_assignment(assignment["id"])

    def test_explicit_empty_selection_does_not_inherit_old_evidence(self):
        assignment = self.stage_and_assignment()
        self.record_run("prior-batch", SUITES, revision=self.base, assignment=assignment)
        result = self.store.record_outcome(assignment["id"], assignment["generation"],
            assignment["native_session_id"], assignment["input_revision"], "success", "Finished", "empty-selection",
            verification_run_ids=[])
        self.assertEqual(result["verification_run_ids"], [])
        self.assertFalse(result["verification_recording"]["inherited"])

    def test_successor_finishes_with_original_evidence_without_duplication(self):
        first = self.stage_and_assignment()
        revision = self.commit("finished source")
        self.record_inventory(SUITES, revision=revision)
        run = self.record_run("original-batch", SUITES, revision=revision, assignment=first)
        successor = self.handoff(first)
        params = (successor["id"], successor["generation"], successor["native_session_id"],
                  successor["input_revision"], "success", "Work complete", "successor-outcome")
        result = self.store.record_outcome(*params, code_revision=revision,
                                           verification_run_ids=[run["id"]],
                                           documents=[{"title": "Result", "content": "Synthetic result"}])
        replay = self.store.record_outcome(*params, code_revision=revision,
                                           verification_run_ids=[run["id"]],
                                           documents=[{"title": "Result", "content": "Synthetic result"}])
        self.assertEqual(result, replay)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["verification_run_ids"], [run["id"]])
        self.assertEqual(result["verification_recording"]["reconciliation_attempts"], 1)
        self.assertEqual(self.store.list_verification_runs(self.feature["id"]), [run])
        self.assertEqual(len(self.store.snapshot(self.feature["id"])["documents"]), 2)  # handoff + outcome
        self.assertEqual(self.runtime.verification_assessment(self.feature["id"])["status"], "verified")

    def test_omitted_selection_inherits_latest_current_results_after_handoff(self):
        first = self.stage_and_assignment()
        old = self.record_run("old-batch", SUITES, revision=self.base, assignment=first)
        revision = self.commit("updated source")
        self.record_inventory(SUITES, revision=revision)
        current = self.record_run("current-batch", SUITES, revision=revision, assignment=first)
        successor = self.handoff(first)
        result = self.store.record_outcome(successor["id"], successor["generation"], successor["native_session_id"],
                                          successor["input_revision"], "success", "Done", "inherit-outcome",
                                          code_revision=revision)
        self.assertEqual(result["verification_run_ids"], [current["id"]])
        self.assertTrue(result["verification_recording"]["inherited"])
        self.assertEqual(self.runtime.verification_assessment(self.feature["id"])["status"], "verified")
        self.assertEqual(self.store.get_verification_run(old["id"]), old)

    def test_missing_evidence_is_terminal_and_retained_across_restart(self):
        assignment = self.stage_and_assignment()
        params = (assignment["id"], assignment["generation"], assignment["native_session_id"],
                  assignment["input_revision"], "success", "Finished implementation", "missing-evidence")
        result = self.store.record_outcome(*params, verification_run_ids=["fmvr_missing"])
        self.assertTrue(result["has_outcome"])
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["verification_recording"]["state"], "incomplete")
        self.store.close()
        self.store = FirstMateStore(self.root / "store.sqlite3")
        replay = self.store.record_outcome(*params, verification_run_ids=["fmvr_missing"])
        self.assertEqual(replay, result)
        restored = self.store.get_assignment(assignment["id"])
        self.assertEqual(restored["verification_recording"], result["verification_recording"])
        self.assertEqual(restored["recovery_count"], 0)

    def test_missing_evidence_never_allows_a_stale_worker_to_finish(self):
        first = self.stage_and_assignment()
        self.handoff(first)
        with self.assertRaises(FirstMateError) as stale:
            self.store.record_outcome(first["id"], first["generation"], first["native_session_id"],
                                      first["input_revision"], "success", "Done", "stale-outcome",
                                      verification_run_ids=["fmvr_missing"])
        self.assertEqual(stale.exception.code, "stale_generation")

    def test_reused_pass_does_not_hide_later_failure(self):
        first = self.stage_and_assignment()
        revision = self.commit("finished source")
        self.record_inventory(SUITES, revision=revision)
        passed = self.record_run("passing-batch", SUITES, revision=revision, assignment=first)
        self.record_run("failing-batch", [SUITES[0]], revision=revision, outcome="failed", assignment=first)
        successor = self.handoff(first)
        result = self.store.record_outcome(successor["id"], successor["generation"], successor["native_session_id"],
                                          successor["input_revision"], "failed", "Test failure retained", "failed-outcome",
                                          code_revision=revision, verification_run_ids=[passed["id"]])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.runtime.verification_assessment(self.feature["id"])["status"], "failed")

    def test_stage_completion_persists_the_scoped_verdict_and_gate_set_atomically(self):
        assignment = self.stage_and_assignment()
        advanced = self.commit("implemented change")
        self.record_inventory(SUITES, revision=advanced)
        run = self.record_run("run-six", SUITES, revision=advanced, assignment=assignment)
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Implementation complete", "outcome-one",
                                  verification_run_ids=[run["id"]])
        visit_id = self.store.get_feature(self.feature["id"])["current_visit_id"]
        assessment = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(assessment["status"], "verified")
        self.store.complete_visit(visit_id, "Synthetic stage done", "Review next", "complete-one",
                                  verification=assessment)
        # Replay with a freshly computed timestamp is the same committed operation.
        replay = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        replayed = self.store.complete_visit(visit_id, "Synthetic stage done", "Review next", "complete-one",
                                             verification=replay)
        self.assertEqual(replayed["status"], "completed")

        snapshot = self.store.snapshot(self.feature["id"])
        checkpoint = next(message for message in snapshot["messages"]
                          if message["role"] == "assistant" and message["metadata"].get("checkpoint"))
        self.assertEqual(checkpoint["metadata"]["verification"]["status"], "verified")
        self.assertEqual([entry["label"] for entry in checkpoint["metadata"]["verification"]["gate_set"]],
                         sorted(f"pkg/app/{name}" for name in SUITES))
        completed_event = next(event for event in snapshot["events"] if event["type"] == "visit.awaiting_direction")
        self.assertEqual(completed_event["payload"]["verification"]["status"], "verified")
        self.assertEqual(self.store.get_feature(self.feature["id"])["verification"]["status"], "verified")

        # Restart keeps the canonical verdict and its gate set.
        self.store.close()
        self.store = FirstMateStore(self.root / "store.sqlite3")
        restored = self.store.get_feature(self.feature["id"])["verification"]
        self.assertEqual(restored["status"], "verified")
        self.assertEqual([entry["label"] for entry in restored["gate_set"]],
                         sorted(f"pkg/app/{name}" for name in SUITES))

    def test_partial_coverage_completion_keeps_the_warning_and_never_upgrades(self):
        assignment = self.stage_and_assignment()
        advanced = self.commit("implemented change")
        self.record_inventory(SUITES, revision=advanced)
        run = self.record_run("run-four", SUITES[:4], revision=advanced, assignment=assignment)
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Implementation complete", "outcome-partial",
                                  verification_run_ids=[run["id"]])
        visit_id = self.store.get_feature(self.feature["id"])["current_visit_id"]
        assessment = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(assessment["status"], "partially_verified")
        self.store.complete_visit(visit_id, "Synthetic stage done", "Review next", "complete-partial",
                                  verification=assessment)
        snapshot = self.store.snapshot(self.feature["id"])
        checkpoint = next(message for message in snapshot["messages"]
                          if message["role"] == "assistant" and message["metadata"].get("checkpoint"))
        self.assertNotIn("Verification coverage:", checkpoint["text"])
        self.assertNotIn("Missing suites", checkpoint["text"])
        self.assertEqual(checkpoint["metadata"]["verification"]["missing_suites"],
                         sorted(f"pkg/app/{name}" for name in SUITES[4:]))
        # Feature completion keeps the same partial verdict instead of promoting it.
        self.store.feature_action(self.feature["id"], "complete", "finish-partial",
                                  verification=assessment)
        replay = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.store.feature_action(self.feature["id"], "complete", "finish-partial",
                                  verification=replay)
        self.assertEqual(self.store.get_feature(self.feature["id"])["verification"]["status"],
                         "partially_verified")
        self.assertEqual([item["label"] for item in
                          self.store.get_feature(self.feature["id"])["verification"]["previously_green_missing"]],
                         [])

    def test_informal_park_carries_the_coverage_warning(self):
        self.stage_and_assignment()
        advanced = self.commit("implemented change")
        self.record_inventory(SUITES, revision=advanced)
        run = self.record_run("run-four", SUITES[:4], revision=advanced)
        assessment = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(assessment["status"], "partially_verified")
        message = self.store.append_human_message(self.feature["id"], "Are we done?", "park-question")
        claimed = self.store.claim_message(self.feature["id"], "coordinator-park")
        self.assertEqual(claimed["id"], message["id"])
        self.store.finish_message(claimed["id"], "coordinator-park",
                                  reply="I finished this turn without a checkpoint.",
                                  verification=assessment)
        snapshot = self.store.snapshot(self.feature["id"])
        reply = next(item for item in reversed(snapshot["messages"]) if item["role"] == "assistant")
        self.assertEqual(reply["text"], "I finished this turn without a checkpoint.")
        self.assertNotIn("Missing suites", reply["text"])
        self.assertEqual([entry["label"] for entry in reply["metadata"]["verification"]["gate_set"]],
                         [entry["label"] for entry in snapshot["feature"]["verification"]["gate_set"]])
        self.assertEqual(snapshot["feature"]["verification"]["status"], "partially_verified")
        original = reply["text"]
        legacy = original + "\n\n" + self.store._coverage_note(assessment)
        self.store._db.execute("UPDATE fm_messages SET text=? WHERE id=?", (legacy, reply["id"]))
        self.assertEqual(self.store.skim_source(reply["id"])["text"], original)
        self.assertEqual(self.store._db.execute("SELECT text FROM fm_messages WHERE id=?", (reply["id"],)).fetchone()[0], legacy)
        # Similar author-written prose is not stripped without the exact appendix.
        authored = original + "\n\nVerification coverage: investigate the changed tests."
        self.store._db.execute("UPDATE fm_messages SET text=? WHERE id=?", (authored, reply["id"]))
        self.assertEqual(self.store.skim_source(reply["id"])["text"], authored)

    def test_legacy_feature_without_evidence_stays_conservatively_unavailable(self):
        self.stage_and_assignment(suffix="legacy")
        assessment = self.runtime.verification_assessment(self.feature["id"], None)
        self.assertEqual(assessment["status"], "unavailable")
        self.assertFalse(assessment["evidence_present"])
        # A legacy completion stores no invented evidence and no warning text.
        user_message = self.store.append_human_message(self.feature["id"], "Legacy question", "legacy-question")
        message = self.store.claim_message(self.feature["id"], "coordinator-legacy")
        self.assertEqual(message["id"], user_message["id"])
        self.store.finish_message(message["id"], "coordinator-legacy",
                                  reply="Legacy workflow reply.", verification=None)
        snapshot = self.store.snapshot(self.feature["id"])
        self.assertEqual(snapshot["feature"]["verification"], {})
        self.assertEqual(snapshot["verification_runs"], [])
        self.assertEqual(snapshot["suite_inventories"], [])
        reply = next(item for item in reversed(snapshot["messages"]) if item["role"] == "assistant")
        self.assertIn("Legacy workflow reply.", reply["text"])

    def test_coordinator_stage_completion_selects_retained_runs_explicitly(self):
        assignment = self.stage_and_assignment()
        advanced = self.commit("implemented change")
        self.record_inventory(SUITES, revision=advanced)
        broad = self.record_run("run-six", SUITES, revision=advanced, assignment=assignment)
        coordinator = {"kind": "coordinator", "feature_id": self.feature["id"],
                       "claim": {"id": "synthetic-message", "role": "user"},
                       "owner": "coordinator-owner", "cwd": str(self.repo)}
        # A live router status sees the recorded evidence before any parking.
        live = self.runtime._tool(coordinator, "fm_status", {}, "status-live")
        self.assertEqual(live["verification"]["status"], "verified")
        self.assertEqual([run["id"] for run in live["verification_runs"]], [broad["id"]])
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Complete", "outcome-select",
                                  verification_run_ids=[broad["id"]])
        result = self.runtime._tool(coordinator, "fm_complete_stage", {
            "summary": "Synthetic", "recommendation": "Next",
            "verification_run_ids": [broad["id"]]}, "complete-explicit")
        self.assertEqual(result["status"], "completed")
        self.assertEqual(self.store.get_feature(self.feature["id"])["verification"]["status"], "verified")

        # Feature completion recomputes and retains the same scoped verdict.
        finished = self.runtime._tool(coordinator, "fm_finish_feature",
                                      {"summary": "Delivered"}, "finish-feature")
        self.assertEqual(finished["status"], "completed")
        self.assertEqual(self.store.get_feature(self.feature["id"])["verification"]["status"], "verified")

    def test_completion_reference_repair_is_bounded_and_does_not_stall(self):
        assignment = self.stage_and_assignment()
        self.store.record_outcome(assignment["id"], assignment["generation"], assignment["native_session_id"],
            assignment["input_revision"], "success", "Finished", "outcome-optional")
        coordinator = {"kind": "coordinator", "feature_id": self.feature["id"],
                       "claim": {"id": "synthetic-message", "role": "user"},
                       "owner": "coordinator-owner", "cwd": str(self.repo)}
        result = self.runtime._tool(coordinator, "fm_complete_stage", {
            "summary": "Finished", "recommendation": "Next", "verification_run_ids": ["fmvr_missing"]}, "complete-missing")
        self.assertEqual(result["status"], "completed")
        verification = self.store.get_feature(self.feature["id"])["verification"]
        self.assertNotEqual(verification["status"], "verified")
        self.assertEqual(verification["recording"]["reconciliation_attempts"], 1)

    def test_optional_assessment_timeout_retains_recorded_batch_and_completion(self):
        assignment = self.stage_and_assignment()
        job = {"kind": "worker", "feature_id": self.feature["id"], "claim": assignment,
               "native_session_id": assignment["native_session_id"], "cwd": str(self.repo)}
        with patch.object(self.runtime, "_verification_read_identity", side_effect=OSError("offline")):
            result = self.runtime._record_verification(job, {
                "revision": self.base, "gates": [gate("SuiteOne")]}, "record-offline")
        self.assertTrue(result["run"]["id"])
        self.assertEqual(result["verification"]["status"], "unavailable")
        self.assertEqual(len(self.store.list_verification_runs(self.feature["id"])), 1)
        with patch.object(self.runtime, "verification_assessment", side_effect=subprocess.TimeoutExpired("git", 3)):
            selection, assessment = self.runtime._completion_verification(self.feature["id"], [result["run"]["id"]])
        self.assertEqual(selection, [result["run"]["id"]])
        self.assertEqual(assessment["status"], "unavailable")

    def test_lineage_successor_inherits_predecessor_package_coverage(self):
        # Implementer A changes pkg/app in an isolated worktree; successor B
        # starts from A's commit and changes pkg/other. B's cumulative diff must
        # still cover pkg/app, so B's pkg/other pass alone cannot verify it.
        worktree_a = self.root / "lineage-a"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-b", "lineage-a",
                        str(worktree_a), self.base], capture_output=True, check=True)
        first = self.stage_and_assignment(worktree=worktree_a)
        with (worktree_a / "pkg/app/Sources/Feature.swift").open("a") as handle:
            handle.write("// pkg app change\n")
        subprocess.run(["git", "-C", str(worktree_a), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(worktree_a), "commit", "-m", "change pkg app"],
                       capture_output=True, check=True)
        a_head = subprocess.run(["git", "-C", str(worktree_a), "rev-parse", "HEAD"],
                                capture_output=True, text=True, check=True).stdout.strip()
        ws_a = FirstMateRuntime._workspace_identity(str(worktree_a))
        self.record_inventory(["OneTests"], revision=a_head, package="pkg/app", workspace=ws_a)
        old_run = self.record_run("run-a", ["OneTests"], revision=a_head, package="pkg/app", workspace=ws_a)

        worktree_b = self.root / "lineage-b"
        subprocess.run(["git", "-C", str(worktree_a), "worktree", "add", "-b", "lineage-b",
                        str(worktree_b), a_head], capture_output=True, check=True)
        feature = self.store.get_feature(self.feature["id"])
        self.store.create_assignment(feature["current_visit_id"], {
            "title": "Lineage successor", "role": "implementer", "prompt": "Continue.",
            "request_id": "assignment-lineage-b",
            "metadata": {"workspace_mode": "isolated", "worktree_path": str(worktree_b),
                         "base_revision": a_head, "source_assignment_id": first["id"]}})
        with (worktree_b / "pkg/other/Sources/Other.swift").open("a") as handle:
            handle.write("// pkg other change\n")
        subprocess.run(["git", "-C", str(worktree_b), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(worktree_b), "commit", "-m", "change pkg other"],
                       capture_output=True, check=True)
        b_head = subprocess.run(["git", "-C", str(worktree_b), "rev-parse", "HEAD"],
                                capture_output=True, text=True, check=True).stdout.strip()
        ws_b = FirstMateRuntime._workspace_identity(str(worktree_b))
        self.record_inventory(["OneTests"], revision=b_head, package="pkg/app", workspace=ws_b)
        self.record_inventory(["TwoTests"], revision=b_head, package="pkg/other", workspace=ws_b)
        narrow = self.record_run("run-b", ["TwoTests"], revision=b_head, package="pkg/other", workspace=ws_b)

        assessment = self.runtime.verification_assessment(self.feature["id"])
        self.assertEqual(assessment["assessed_revisions"], {ws_b: b_head})
        self.assertNotIn(ws_a, assessment["assessed_revisions"])
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertIn("pkg/app/OneTests", {item["label"] for item in assessment["missing_suites"]})

        # A fresh pass on pkg/app at B's revision supersedes the inherited
        # evidence; selecting the B runs removes the stale predecessor run.
        complete = self.record_run("run-b-all", ["OneTests"], revision=b_head, package="pkg/app", workspace=ws_b)
        verified = self.runtime.verification_assessment(self.feature["id"], [narrow["id"], complete["id"]])
        self.assertEqual(verified["status"], "verified")
        self.assertEqual(verified["previously_green_missing"], [])
        self.assertEqual(verified["source_revisions"], [b_head])

    def test_stale_inventory_requires_revalidation_after_new_suite(self):
        self.stage_and_assignment()
        advanced = self.commit("add a suite after discovery")
        self.record_inventory(["SuiteOne"], revision=self.base)
        run = self.record_run("run-one", ["SuiteOne"], revision=advanced)
        stale = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(stale["status"], "partially_verified")
        self.assertEqual(len(stale["stale_inventories"]), 1)
        self.assertIn("revalidate the inventory", " ".join(stale["coverage_reasons"]))
        # Revalidated discovery at the current revision names the suite that was
        # added but has never run.
        self.record_inventory(["SuiteOne", "SuiteTwo"], revision=advanced)
        current = self.runtime.verification_assessment(self.feature["id"], [run["id"]])
        self.assertEqual(current["status"], "partially_verified")
        self.assertEqual([item["label"] for item in current["missing_suites"]], ["pkg/app/SuiteTwo"])

    def test_explicit_gate_selection_survives_reads_restart_and_completion(self):
        assignment = self.stage_and_assignment()
        advanced = self.commit("implemented change")
        self.record_inventory(SUITES, revision=advanced)
        broad = self.record_run("run-six", SUITES, revision=advanced, assignment=assignment)
        narrow = self.record_run("run-four", SUITES[:4], revision=advanced, assignment=assignment)
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Complete", "outcome-selection",
                                  verification_run_ids=[broad["id"]])
        coordinator = {"kind": "coordinator", "feature_id": self.feature["id"],
                       "claim": {"id": "synthetic-message", "role": "user"},
                       "owner": "coordinator-owner", "cwd": str(self.repo)}
        result = self.runtime._tool(coordinator, "fm_complete_stage", {
            "summary": "Synthetic", "recommendation": "Next",
            "verification_run_ids": [narrow["id"]]}, "complete-selection")
        self.assertEqual(result["status"], "completed")
        feature_id = self.feature["id"]
        self.assertEqual(self.store.get_feature(feature_id)["verification_selection"], [narrow["id"]])
        # An informal coordinator park also reuses the retained narrow selection
        # rather than falling back to the outcome's broader references.
        message = self.store.append_human_message(feature_id, "Are we done?", "park-selection")
        claimed = self.store.claim_message(feature_id, "coordinator-park")
        self.assertEqual(claimed["id"], message["id"])
        self.runtime._finish(
            {"kind": "coordinator", "id": "synthetic-park-job", "feature_id": feature_id,
             "claim": {"id": claimed["id"], "role": "user"}, "owner": "coordinator-park",
             "native_session_id": None},
            {"ended": True, "response": "Still partial."})
        reply = next(item for item in reversed(self.store.snapshot(feature_id)["messages"])
                     if item["role"] == "assistant")
        self.assertEqual(reply["metadata"]["verification"]["status"], "partially_verified")
        # Every status surface recomputes the retained narrow selection rather
        # than defaulting back to the outcome's broader references.
        for surface in (self.runtime.feature(feature_id)["verification"],
                        self.runtime.snapshot(feature_id)["feature"]["verification"],
                        next(item for item in self.runtime.list_features("all") if item["id"] == feature_id)["verification"],
                        self.runtime.board(feature_id)["feature"]["verification"]):
            self.assertEqual(surface["status"], "partially_verified")
            self.assertEqual(sorted(entry["label"] for entry in surface["gate_set"]),
                             sorted(f"pkg/app/{name}" for name in SUITES[:4]))
        # A restart keeps the selection and the partial verdict.
        self.store.close()
        self.store = FirstMateStore(self.root / "store.sqlite3")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")
        self.assertEqual(self.store.get_feature(feature_id)["verification_selection"], [narrow["id"]])
        self.assertEqual(self.runtime.feature(feature_id)["verification"]["status"], "partially_verified")

    def test_explicit_empty_gate_selection_survives_reads_and_restart(self):
        assignment = self.stage_and_assignment()
        revision = self.commit("implemented change")
        self.record_inventory(SUITES, revision=revision)
        broad = self.record_run("run-six", SUITES, revision=revision, assignment=assignment)
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Complete", "outcome-empty-selection",
                                  verification_run_ids=[broad["id"]])
        coordinator = {"kind": "coordinator", "feature_id": self.feature["id"],
                       "claim": {"id": "synthetic-message", "role": "user"},
                       "owner": "coordinator-owner", "cwd": str(self.repo)}
        self.runtime._tool(coordinator, "fm_complete_stage", {
            "summary": "Synthetic", "recommendation": "Next",
            "verification_run_ids": []}, "complete-empty-selection")
        for restart in (False, True):
            if restart:
                self.store.close()
                self.store = FirstMateStore(self.root / "store.sqlite3")
                self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                                runtime_root=self.root / "runtime")
            feature_id = self.feature["id"]
            self.assertEqual(self.store.get_feature(feature_id)["verification_selection"], [])
            for surface in (self.runtime.feature(feature_id)["verification"],
                            self.runtime.snapshot(feature_id)["feature"]["verification"],
                            self.runtime.board(feature_id)["feature"]["verification"]):
                self.assertEqual(surface["status"], "partially_verified")
                self.assertEqual(surface["gate_set"], [])
                self.assertEqual(len(surface["previously_green_missing"]), len(SUITES))

    def test_conditional_board_refreshes_when_git_changes_without_ledger_events(self):
        assignment = self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        self.record_run("run-six", SUITES, revision=self.base, assignment=assignment)
        feature_id = self.feature["id"]
        verified = self.runtime.board(feature_id)
        self.assertEqual(verified["feature"]["verification"]["status"], "verified")
        self.assertEqual(self.runtime.board(feature_id, if_version=verified["version"]),
                         {"version": verified["version"], "unchanged": True})
        self.commit("advance without a ledger mutation")
        partial = self.runtime.board(feature_id, if_version=verified["version"])
        self.assertFalse(partial["unchanged"])
        self.assertEqual(partial["feature"]["verification"]["status"], "partially_verified")
        self.assertNotEqual(partial["version"], verified["version"])
        self.assertEqual(self.runtime.board(feature_id, if_version=partial["version"]),
                         {"version": partial["version"], "unchanged": True})
        (self.repo / "pkg/app/Sources/Feature.swift").write_text("// dirty synthetic source\n")
        dirty = self.runtime.board(feature_id, if_version=partial["version"])
        self.assertFalse(dirty["unchanged"])
        self.assertTrue(any("uncommitted" in reason for reason in
                            dirty["feature"]["verification"]["coverage_reasons"]))

    def test_advancing_head_after_a_checkpoint_downgrades_every_status_surface(self):
        assignment = self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        broad = self.record_run("run-six", SUITES, revision=self.base, assignment=assignment)
        assessment = self.runtime.verification_assessment(self.feature["id"], [broad["id"]])
        self.assertEqual(assessment["status"], "verified")
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Complete", "outcome-checkpoint",
                                  verification_run_ids=[broad["id"]])
        visit_id = self.store.get_feature(self.feature["id"])["current_visit_id"]
        self.store.complete_visit(visit_id, "Synthetic stage done", "Review next", "complete-current",
                                  verification=assessment, selection=[broad["id"]])
        self.assertEqual(self.runtime.feature(self.feature["id"])["verification"]["status"], "verified")

        self.commit("advance after the checkpoint")
        feature_id = self.feature["id"]
        surfaces = [self.runtime.feature(feature_id)["verification"],
                    self.runtime.snapshot(feature_id)["feature"]["verification"],
                    next(item for item in self.runtime.list_features("all") if item["id"] == feature_id)["verification"],
                    self.runtime.board(feature_id)["feature"]["verification"]]
        for surface in surfaces:
            self.assertEqual(surface["status"], "partially_verified")
            self.assertTrue(any(entry["run_id"] == broad["id"] for entry in surface["stale_evidence"]))

    def test_assessment_failure_fails_closed_with_historical_evidence(self):
        assignment = self.stage_and_assignment()
        self.record_inventory(SUITES, revision=self.base)
        broad = self.record_run("run-six", SUITES, revision=self.base, assignment=assignment)
        assessment = self.runtime.verification_assessment(self.feature["id"], [broad["id"]])
        self.assertEqual(assessment["status"], "verified")
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Complete", "outcome-failure-surface",
                                  verification_run_ids=[broad["id"]])
        visit_id = self.store.get_feature(self.feature["id"])["current_visit_id"]
        self.store.complete_visit(visit_id, "Synthetic stage done", "Review next", "complete-failure",
                                  verification=assessment, selection=[broad["id"]])

        def broken(*_args, **_kwargs):
            raise FirstMateError("synthetic assessment failure")

        original = self.runtime.verification_assessment
        self.runtime.verification_assessment = broken
        try:
            for surface in (self.runtime.feature(self.feature["id"])["verification"],
                            next(item for item in self.runtime.list_features("all")
                                 if item["id"] == self.feature["id"])["verification"],
                            self.runtime.board(self.feature["id"])["feature"]["verification"]):
                self.assertEqual(surface["status"], "unavailable")
                self.assertEqual(surface["historical_evidence"]["status"], "verified")
                self.assertTrue(any("could not be computed" in reason
                                    for reason in surface["coverage_reasons"]))
        finally:
            self.runtime.verification_assessment = original

    def test_long_retained_history_is_assessed_without_a_selection_limit(self):
        assignment = self.stage_and_assignment()
        self.record_inventory(["SuiteOne"], revision=self.base)
        for index in range(240):
            self.record_run(f"run-long-{index:03d}", ["SuiteOne"], revision=self.base, assignment=assignment)
        assessment = self.runtime.verification_assessment(self.feature["id"])
        self.assertEqual(assessment["status"], "verified")
        self.assertEqual(assessment["run_count"], 240)
        self.assertEqual(self.runtime.feature(self.feature["id"])["verification"]["status"], "verified")

    def test_recording_dirty_then_cleaning_does_not_promote_evidence(self):
        assignment = self.stage_and_assignment()
        job = {"kind": "worker", "feature_id": self.feature["id"],
               "claim": {"id": assignment["id"], "generation": assignment["generation"]},
               "native_session_id": assignment["native_session_id"], "cwd": str(self.repo)}
        params = {
            "revision": self.base, "status": "completed", "summary": "dirty batch",
            "inventory": {"package": "pkg/app", "state": "complete", "revision": self.base,
                          "suites": [suite(name) for name in SUITES], "evidence": "synthetic"},
            "gates": [gate(name) for name in SUITES],
        }
        (self.repo / "uncommitted-fix.patch").write_text("synthetic pending fix\n")
        recorded = self.runtime._record_verification(job, params, "verification-dirty")
        self.assertEqual(recorded["run"]["source_state"], "dirty")
        self.assertIn("uncommitted", recorded["warning"])
        self.assertEqual(recorded["verification"]["status"], "partially_verified")
        (self.repo / "uncommitted-fix.patch").unlink()
        cleaned = self.runtime.feature(self.feature["id"])["verification"]
        self.assertEqual(cleaned["status"], "partially_verified")
        self.assertTrue(any("dirty" in entry["reason"] for entry in cleaned["stale_evidence"]))


if __name__ == "__main__":
    unittest.main()
