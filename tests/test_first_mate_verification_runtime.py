"""Durable verification evidence tests over the real store and a temporary Git repo.

The fixtures are fully synthetic. They exercise the exact incident shape: a
feature records broad coverage, the source revision advances, a later gate set
silently drops suites, and the assessment must keep naming them until current
complete evidence exists. No Pi process or model is used; only retained records
and Git observations are evaluated.
"""
from __future__ import annotations

import subprocess
import tempfile
import unittest
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
                   assignment: dict | None = None, workspace: str | None = None) -> dict:
        gates = []
        for name in names:
            gates.append(gate(name, (selected_outcomes or {}).get(name, outcome), package=package))
        provenance = ({"visit_id": assignment["visit_id"], "assignment_id": assignment["id"],
                       "native_session_id": assignment["native_session_id"],
                       "generation": assignment["generation"]} if assignment else
                      {"visit_id": None, "assignment_id": None, "native_session_id": None, "generation": None})
        return self.store.record_verification(self.feature["id"], {
            "workspace": workspace or self.workspace, "revision": revision, "observed_revision": revision,
            "status": "completed", "gates": gates, "summary": "synthetic batch"},
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
            "summary": "handoff successor batch"}, "run-narrow-successor", {
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

        # An outcome may reference only retained runs of its own execution.
        run_id = first["run"]["id"]
        other_feature = self.store.create_feature({
            "title": "Synthetic other feature", "goal": "Other goal",
            "cwd": str(self.repo), "request_id": "create-other"})
        other = self.stage_and_assignment(suffix="2", feature=other_feature)
        with self.assertRaises(FirstMateError) as mismatch:
            self.store.record_outcome(other["id"], other["generation"], other["native_session_id"],
                                      other["input_revision"], "success", "Done", "outcome-other",
                                      verification_run_ids=[run_id])
        self.assertEqual(mismatch.exception.code, "verification_scope_mismatch")
        with self.assertRaises(FirstMateError) as unknown:
            self.store.record_outcome(other["id"], other["generation"], other["native_session_id"],
                                      other["input_revision"], "success", "Done", "outcome-unknown",
                                      verification_run_ids=["fmvr_invented"])
        self.assertEqual(unknown.exception.code, "not_found")

        # A valid outcome retains the exact run references for later selection.
        self.store.record_outcome(assignment["id"], assignment["generation"],
                                  assignment["native_session_id"], assignment["input_revision"],
                                  "success", "Verified", "outcome-linked", verification_run_ids=[run_id])
        linked = self.store.get_assignment(assignment["id"])
        self.assertEqual(linked["verification_run_ids"], [run_id])
        feature = self.store.get_feature(self.feature["id"])
        self.assertEqual(self.runtime._default_verification_selection(feature), [run_id])

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
        self.assertIn("Verification coverage: Partially verified", checkpoint["text"])
        self.assertIn("Missing suites", checkpoint["text"])
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
        self.assertIn("Verification coverage: Partially verified", reply["text"])
        self.assertIn("Missing suites", reply["text"])
        self.assertEqual([entry["label"] for entry in reply["metadata"]["verification"]["gate_set"]],
                         [entry["label"] for entry in snapshot["feature"]["verification"]["gate_set"]])
        self.assertEqual(snapshot["feature"]["verification"]["status"], "partially_verified")

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
        with self.assertRaises(FirstMateError) as foreign:
            self.runtime._tool(coordinator, "fm_complete_stage", {
                "summary": "Synthetic", "recommendation": "Next",
                "verification_run_ids": ["fmvr_invented"]}, "complete-foreign")
        self.assertEqual(foreign.exception.code, "not_found")
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


if __name__ == "__main__":
    unittest.main()
