"""Verification targets add correct provenance without relaxing cumulative gates."""
from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateError
from tests import test_first_mate_verification_runtime as fixtures


class VerificationTargetTests(unittest.TestCase):
    tearDown = fixtures.VerificationRuntimeTests.tearDown
    head = fixtures.VerificationRuntimeTests.head
    stage_and_assignment = fixtures.VerificationRuntimeTests.stage_and_assignment

    def setUp(self):
        fixtures.VerificationRuntimeTests.setUp(self)
        self.assignment = self.stage_and_assignment()
        self.job = {"kind": "worker", "feature_id": self.feature["id"],
                    "claim": self.assignment, "native_session_id": self.assignment["native_session_id"],
                    "cwd": str(self.repo)}
        self.target = self.root / "target"
        self.git(self.repo, "worktree", "add", "-b", "synthetic-target", str(self.target), self.base)
        with (self.target / "pkg/app/Sources/Feature.swift").open("a") as handle:
            handle.write("// target change\n")
        self.git(self.target, "commit", "-am", "Synthetic target change")
        self.target_head = self.git(self.target, "rev-parse", "HEAD")
        self.target_identity = self.runtime._workspace_identity(str(self.target.resolve()))

    @staticmethod
    def git(path: Path, *arguments: str) -> str:
        return subprocess.run(["git", "-C", str(path), *arguments], check=True,
                              capture_output=True, text=True, timeout=15).stdout.strip()

    def report(self, **overrides):
        report = {"revision": self.target_head, "gates": [fixtures.gate("TargetTests")],
                  "target_workspace_path": str(self.target), "baseline_revision": self.base,
                  "inventory": {"package": "pkg/app", "state": "complete",
                                "suites": [fixtures.suite("TargetTests")]}}
        report.update(overrides)
        return report

    def test_external_worktree_observation_uses_target_and_keeps_original_dirty_scope(self):
        (self.repo / "uncommitted.txt").write_text("synthetic unrelated edit\n")
        result = self.runtime._record_verification(self.job, self.report(), "target-run")
        self.assertEqual(result["run"]["workspace"], self.target_identity)
        self.assertEqual(result["run"]["observed_revision"], self.target_head)
        self.assertEqual(result["run"]["source_state"], "clean")
        self.assertTrue(result["run"]["revision_matches"])
        self.assertEqual(result["warning"], "")
        self.assertNotEqual(result["verification"]["status"], "verified")
        scope = self.runtime._verification_scope(self.feature)
        self.assertEqual(set(scope["revisions"]), {self.workspace, self.target_identity})
        self.assertIn("pkg/app/Sources/Feature.swift", scope["changed_paths"][self.target_identity])
        self.assertIn("uncommitted.txt", scope["changed_paths"][self.workspace])

    def test_old_failure_remains_visible_after_correct_target_pass(self):
        old = self.runtime._record_verification(self.job, {
            "revision": self.base, "gates": [fixtures.gate("OldTests", "failed")]}, "old-failure")
        result = self.runtime._record_verification(self.job, self.report(), "target-pass")
        self.assertEqual(result["run"]["source_state"], "clean")
        self.assertEqual(result["verification"]["status"], "failed")
        self.assertEqual(result["verification"]["failing_suites"][0]["run_id"], old["run"]["id"])
        self.assertEqual(len(self.store.list_verification_runs(self.feature["id"])), 2)

    def test_first_registration_at_target_head_cannot_omit_changed_package(self):
        result = self.runtime._record_verification(self.job, self.report(
            baseline_revision=self.target_head,
            gates=[fixtures.gate("OtherTests", package="pkg/other")],
            inventory={"package": "pkg/other", "state": "complete",
                       "suites": [fixtures.suite("OtherTests", package="pkg/other")]}), "head-baseline")
        self.assertEqual(result["verification"]["status"], "partially_verified")
        self.assertIn({"workspace": self.target_identity, "path": "pkg/app/Sources/Feature.swift"},
                      result["verification"]["unmapped_paths"])

    def test_target_keeps_source_lineage_anchor_before_successor_baseline(self):
        job = self.additional_assignment_job("successor", self.target_head, source=self.assignment["id"])
        self.runtime._record_verification(job, self.report(baseline_revision=self.target_head), "successor-target")
        scope = self.runtime._verification_scope(self.feature)
        self.assertTrue(scope["complete"])
        self.assertIn("pkg/app/Sources/Feature.swift", scope["changed_paths"][self.target_identity])
        self.assertIn(self.workspace, scope["revisions"])

    def test_nonancestor_assignment_anchor_leaves_target_scope_unknown(self):
        (self.repo / "sibling.txt").write_text("synthetic sibling\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "Synthetic sibling anchor")
        job = self.additional_assignment_job("sibling", self.head())
        result = self.runtime._record_verification(job, self.report(), "nonancestor-target")
        scope = self.runtime._verification_scope(self.feature)
        self.assertFalse(scope["complete"])
        self.assertIn("pkg/app/Sources/Feature.swift", scope["changed_paths"][self.target_identity])
        self.assertTrue(any("retained baseline" in reason for reason in scope["reasons"]))
        self.assertNotEqual(result["verification"]["status"], "verified")

    def additional_assignment_job(self, suffix, baseline, *, source=None):
        metadata = {"workspace_mode": "read_only", "worktree_path": str(self.repo), "base_revision": baseline}
        if source:
            metadata["source_assignment_id"] = source
        assignment = self.store.create_assignment(self.assignment["visit_id"], {
            "title": "Synthetic " + suffix, "role": "verifier", "prompt": "Verify synthetic target",
            "request_id": "assignment-" + suffix, "metadata": metadata})
        claimed = self.store.claim_assignment(assignment["id"], "worker-" + suffix)
        self.store.bind_session(assignment["id"], claimed["generation"], "worker-" + suffix,
                                "native-" + suffix, str(self.root / (suffix + ".jsonl")), "run-" + suffix)
        return {**self.job, "claim": self.store.get_assignment(assignment["id"]),
                "native_session_id": "native-" + suffix}

    def test_dirty_target_never_uses_clean_dispatch_source_state(self):
        (self.target / "uncommitted.txt").write_text("synthetic target edit\n")
        result = self.runtime._record_verification(self.job, self.report(), "dirty-target")
        self.assertEqual(result["run"]["source_state"], "dirty")
        self.assertIn("uncommitted", result["warning"])
        self.assertNotEqual(result["verification"]["status"], "verified")

    def test_registration_survives_restart_and_successor_generation(self):
        first = self.runtime._record_verification(self.job, self.report(), "first-target")
        self.runtime = FirstMateRuntime(self.store, environ={"PATH": "/usr/bin:/bin"},
                                        runtime_root=self.root / "runtime")
        report = self.report()
        del report["target_workspace_path"], report["baseline_revision"]
        second = self.runtime._record_verification(self.job, report, "retained-target")
        self.assertEqual(second["run"]["workspace"], first["run"]["workspace"])
        successor = {**self.assignment, "generation": self.assignment["generation"] + 1}
        retained = self.runtime._verification_target(self.feature, successor, self.job, {})
        self.assertEqual(retained["generation"], self.assignment["generation"])
        self.assertEqual(retained["native_session_id"], self.assignment["native_session_id"])
        self.assertEqual(retained["baseline_revision"], self.base)

    def test_registration_inherits_only_explicit_same_feature_assignment_lineage(self):
        self.runtime._record_verification(self.job, self.report(), "first-target")
        successor = {**self.assignment, "id": "synthetic-successor", "generation": 0,
                     "metadata": {"source_assignment_id": self.assignment["id"]}}
        retained = self.runtime._verification_target(self.feature, successor, self.job, {})
        self.assertEqual(retained["assignment_id"], successor["id"])
        self.assertEqual(retained["inherited_from_assignment_id"], self.assignment["id"])
        self.assertEqual(retained["target_workspace_path"], str(self.target.resolve()))

    def test_registration_is_immutable_and_corruption_fails_closed(self):
        self.runtime._record_verification(self.job, self.report(), "first-target")
        with self.assertRaises(FirstMateError) as error:
            self.runtime._record_verification(self.job, self.report(baseline_revision=self.target_head), "changed-target")
        self.assertEqual(error.exception.code, "verification_target_changed")
        path = next(self.runtime._verification_target_directory(self.feature["id"]).glob("*.json"))
        registration = json.loads(path.read_text())
        self.assertEqual(registration["feature_id"], self.feature["id"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        path.write_text("invalid synthetic registration")
        with self.assertRaises(FirstMateError):
            self.runtime._verification_scope(self.feature)

    def test_target_requires_root_exact_baseline_and_ancestry(self):
        invalid = [
            {"target_workspace_path": "relative/target"},
            {"target_workspace_path": str(self.target / "pkg")},
            {"baseline_revision": "HEAD"},
            {"baseline_revision": "a" * 40},
            {"baseline_revision": None},
        ]
        # A sibling commit is a real commit in the repository, but is not an
        # ancestor of the target and cannot describe its cumulative changes.
        (self.repo / "sibling.txt").write_text("synthetic sibling\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "Synthetic sibling")
        invalid.append({"baseline_revision": self.head()})
        for index, override in enumerate(invalid):
            with self.subTest(override=override), self.assertRaises(FirstMateError):
                self.runtime._record_verification(self.job, self.report(**override), f"invalid-{index}")
        self.assertEqual(self.runtime._verification_targets(self.feature["id"]), [])
        self.assertEqual(self.store.list_verification_runs(self.feature["id"]), [])

    def test_separate_clone_requires_matching_normalized_origin(self):
        clone = self.root / "clone"
        self.git(self.repo, "clone", str(self.target), str(clone))
        self.git(self.repo, "config", "remote.origin.url", "git@example.invalid:synthetic/project.git")
        self.git(clone, "config", "remote.origin.url", "https://example.invalid/different/project.git")
        with self.assertRaises(FirstMateError) as error:
            self.runtime._record_verification(self.job, self.report(target_workspace_path=str(clone)), "wrong-repo")
        self.assertEqual(error.exception.code, "verification_scope_mismatch")
        self.git(clone, "config", "remote.origin.url", "https://example.invalid/synthetic/project.git")
        result = self.runtime._record_verification(self.job, self.report(target_workspace_path=str(clone)), "matching-repo")
        self.assertEqual(result["run"]["observed_revision"], self.target_head)
        self.assertEqual(result["run"]["workspace"], self.runtime._workspace_identity(str(clone.resolve())))


if __name__ == "__main__":
    unittest.main()
