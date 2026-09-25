"""Deterministic coverage-rule tests for First Mate verification assessments.

Every fixture is synthetic. The evaluator is pure: the same inventories, runs,
selection, and observed revisions must always produce the same verdict.
"""
from __future__ import annotations

import unittest

from herdr_harness.first_mate_verification import (
    VerificationValidationError,
    evaluate_coverage,
    normalize_gate_run,
    normalize_inventory,
    normalize_selection,
    normalize_suite,
)


REV_A = "a" * 40
REV_B = "b" * 40
WORKSPACE = "ws_synthetic"


def suite(name: str, package: str = "pkg/app", configuration: str = "") -> dict:
    return {"package": package, "suite": name, "configuration": configuration, "selector": ""}


def inventory(suites: list[dict], *, state: str = "complete", package: str = "pkg/app",
              workspace: str = WORKSPACE, revision: str = REV_A) -> dict:
    return {"workspace": workspace, "package": package, "state": state, "revision": revision,
            "suites": suites, "evidence": "synthetic discovery", "source": "manifest"}


def run(run_id: str, gates, *, revision: str = REV_A, status: str = "completed",
        workspace: str = WORKSPACE, source_state: str = "clean") -> dict:
    return {"id": run_id, "workspace": workspace, "revision": revision, "observed_revision": revision,
            "status": status, "gates": gates, "summary": "synthetic", "source_state": source_state}


def gate(name: str, outcome: str = "passed", package: str = "pkg/app", configuration: str = "", **counts) -> dict:
    return {"suite": suite(name, package, configuration), "outcome": outcome,
            "passed_count": counts.get("passed_count"), "failed_count": counts.get("failed_count"),
            "skipped_count": counts.get("skipped_count")}


def evaluate(**overrides) -> dict:
    arguments = {
        "revision_by_workspace": {WORKSPACE: REV_A},
        "changed_paths_by_workspace": {WORKSPACE: ["pkg/app/Sources/Feature.swift"]},
        "inventories": [],
        "runs": [],
        "selected_run_ids": None,
        "feature_revision": 3,
        "scope_complete": True,
    }
    arguments.update(overrides)
    return evaluate_coverage(**arguments)


SIX = ["SuiteOne", "SuiteTwo", "SuiteThree", "SuiteFour", "SuiteFive", "SuiteSix"]


class CoverageRulesTests(unittest.TestCase):
    def test_complete_current_passing_coverage_is_verified_and_ships_its_gate_set(self):
        assessment = evaluate(
            inventories=[inventory([suite(name) for name in SIX])],
            runs=[run("run-all", [gate(name) for name in SIX])],
        )
        self.assertEqual(assessment["status"], "verified")
        self.assertEqual(assessment["label"], "Verified")
        self.assertEqual(assessment["assessed_revisions"], {WORKSPACE: REV_A})
        self.assertEqual(assessment["missing_suites"], [])
        self.assertEqual(assessment["previously_green_missing"], [])
        self.assertEqual([entry["label"] for entry in assessment["gate_set"]],
                         sorted(f"pkg/app/{name}" for name in SIX))
        self.assertTrue(all(entry["fresh"] for entry in assessment["gate_set"]))
        self.assertEqual(assessment["coverage_reasons"], [])
        self.assertTrue(assessment["evidence_present"])

    def test_six_to_four_omission_is_partial_and_names_previously_green_suites(self):
        # Six suites were green at revision A. The revision advances and only
        # four are re-run and selected at revision B.
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite(name) for name in SIX], revision=REV_B)],
            runs=[
                run("run-six", [gate(name) for name in SIX], revision=REV_A),
                run("run-four", [gate(name) for name in SIX[:4]], revision=REV_B),
            ],
            selected_run_ids=["run-four"],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(assessment["label"], "Partially verified")
        self.assertEqual([item["label"] for item in assessment["missing_suites"]],
                         ["pkg/app/SuiteFive", "pkg/app/SuiteSix"])
        self.assertEqual([item["label"] for item in assessment["previously_green_missing"]],
                         ["pkg/app/SuiteFive", "pkg/app/SuiteSix"])
        self.assertTrue(any("Previously passing suite" in reason for reason in assessment["coverage_reasons"]))
        # The persisted shape identifies the exact current gate set and results.
        self.assertEqual([(entry["label"], entry["outcome"]) for entry in assessment["gate_set"]],
                         sorted((f"pkg/app/{name}", "passed") for name in SIX[:4]))
        self.assertEqual(assessment["source_revisions"], [REV_B])

    def test_replaced_inventory_does_not_erase_previously_green_history(self):
        # The suite dropped from the replacement inventory; the run history still
        # names it as previously green and missing from the current gate set.
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite(name) for name in SIX[:4]], revision=REV_B)],
            runs=[
                run("run-six", [gate(name) for name in SIX], revision=REV_A),
                run("run-four", [gate(name) for name in SIX[:4]], revision=REV_B),
            ],
            selected_run_ids=["run-four"],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([item["label"] for item in assessment["previously_green_missing"]],
                         ["pkg/app/SuiteFive", "pkg/app/SuiteSix"])
        self.assertEqual(assessment["missing_suites"], [])

    def test_required_suite_never_run_is_missing(self):
        assessment = evaluate(
            inventories=[inventory([suite("RanSuite"), suite("NeverRanSuite")])],
            runs=[run("run-one", [gate("RanSuite")])],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([item["label"] for item in assessment["missing_suites"]],
                         ["pkg/app/NeverRanSuite"])
        self.assertEqual(assessment["missing_suites"][0]["reason"], "never run")
        self.assertEqual(assessment["previously_green_missing"], [])

    def test_duplicate_display_names_in_different_packages_stay_distinct(self):
        assessment = evaluate(
            changed_paths_by_workspace={WORKSPACE: ["pkg/one/A.swift", "pkg/two/B.swift"]},
            inventories=[inventory([suite("SharedTests", "pkg/one")], package="pkg/one"),
                         inventory([suite("SharedTests", "pkg/two")], package="pkg/two")],
            runs=[run("run-one", [gate("SharedTests", package="pkg/one")])],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([item["label"] for item in assessment["missing_suites"]],
                         ["pkg/two/SharedTests"])
        self.assertEqual([entry["label"] for entry in assessment["gate_set"]], ["pkg/one/SharedTests"])

    def test_multiple_changed_packages_union_their_required_suites(self):
        assessment = evaluate(
            changed_paths_by_workspace={WORKSPACE: ["pkg/one/A.swift"]},
            inventories=[inventory([suite("OneTests", "pkg/one")], package="pkg/one"),
                         inventory([suite("TwoTests", "pkg/two")], package="pkg/two")],
            runs=[run("run-one", [gate("OneTests", package="pkg/one")])],
        )
        self.assertEqual([item["label"] for item in assessment["required_suites"]], ["pkg/one/OneTests"])
        self.assertEqual(assessment["status"], "verified")

    def test_incomplete_inventory_and_unmapped_paths_lower_coverage(self):
        assessment = evaluate(
            changed_paths_by_workspace={WORKSPACE: ["pkg/app/A.swift", "outside/orphan.swift"]},
            inventories=[inventory([suite("SuiteOne")], state="incomplete")],
            runs=[run("run-one", [gate("SuiteOne")])],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(assessment["incomplete_inventories"],
                         [{"workspace": WORKSPACE, "package": "pkg/app", "state": "incomplete"}])
        self.assertEqual(assessment["unmapped_paths"], [{"workspace": WORKSPACE, "path": "outside/orphan.swift"}])
        self.assertTrue(any("not covered by any discovered package" in reason
                            for reason in assessment["coverage_reasons"]))

    def test_stale_revision_is_partial_until_fresh_complete_evidence_arrives(self):
        stale = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")])],
            runs=[run("run-old", [gate("SuiteOne")], revision=REV_A)],
        )
        self.assertEqual(stale["status"], "partially_verified")
        self.assertEqual(len(stale["stale_evidence"]), 1)
        fresh = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_B)],
            runs=[run("run-old", [gate("SuiteOne")], revision=REV_A),
                  run("run-new", [gate("SuiteOne")], revision=REV_B)],
            selected_run_ids=["run-new"],
        )
        self.assertEqual(fresh["status"], "verified")
        self.assertEqual(fresh["stale_evidence"], [])

    def test_interrupted_evidence_cannot_establish_current_verification(self):
        assessment = evaluate(
            inventories=[inventory([suite("SuiteOne"), suite("SuiteTwo")])],
            runs=[run("run-one", [gate("SuiteOne")], status="interrupted")],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(sorted(item["label"] for item in assessment["missing_suites"]),
                         sorted(["pkg/app/SuiteOne", "pkg/app/SuiteTwo"]))
        self.assertEqual(len(assessment["stale_evidence"]), 1)
        self.assertTrue(any("interrupted" in entry["reason"] for entry in assessment["stale_evidence"]))

    def test_later_failure_supersedes_an_earlier_pass_and_cannot_be_hidden(self):
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne"), suite("SuiteTwo")], revision=REV_B)],
            runs=[
                run("run-pass", [gate("SuiteOne"), gate("SuiteTwo")], revision=REV_A),
                run("run-fail", [gate("SuiteOne", "failed"), gate("SuiteTwo")], revision=REV_B),
            ],
            # The coordinator selects only the earlier passing run.
            selected_run_ids=["run-pass"],
        )
        self.assertEqual(assessment["status"], "failed")
        self.assertEqual([item["label"] for item in assessment["failing_suites"]], ["pkg/app/SuiteOne"])
        self.assertTrue(any("omitted from the selected gate set" in reason
                            or "supersedes an earlier selected result" in reason
                            for reason in assessment["coverage_reasons"]))

    def test_partial_selection_of_latest_failure_is_visible(self):
        assessment = evaluate(
            inventories=[inventory([suite("SuiteOne"), suite("SuiteTwo")])],
            runs=[
                run("run-one", [gate("SuiteOne"), gate("SuiteTwo")]),
                run("run-two", [gate("SuiteOne", "error")]),
            ],
            selected_run_ids=["run-two"],
        )
        self.assertEqual(assessment["status"], "failed")
        self.assertEqual([item["label"] for item in assessment["failing_suites"]], ["pkg/app/SuiteOne"])
        self.assertEqual(sorted(item["label"] for item in assessment["missing_suites"]),
                         sorted(["pkg/app/SuiteOne", "pkg/app/SuiteTwo"]))

    def test_unknown_selected_run_is_named_and_never_verifies(self):
        assessment = evaluate(
            inventories=[inventory([suite("SuiteOne")])],
            runs=[run("run-one", [gate("SuiteOne")])],
            selected_run_ids=["run-one", "run-invented"],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertTrue(any("run-invented" in reason for reason in assessment["coverage_reasons"]))

    def test_no_evidence_is_unavailable_and_unknown_scope_never_verifies(self):
        self.assertEqual(evaluate()["status"], "unavailable")
        self.assertFalse(evaluate()["evidence_present"])
        unknown = evaluate(
            inventories=[inventory([suite("SuiteOne")])],
            runs=[run("run-one", [gate("SuiteOne")])],
            scope_complete=False,
            scope_reasons=["The current workspace revision is unavailable"],
        )
        self.assertEqual(unknown["status"], "partially_verified")
        self.assertTrue(any("unavailable" in reason for reason in unknown["coverage_reasons"]))

    def test_skipped_and_multiple_configurations_are_represented_exactly(self):
        inventory_record = inventory([suite("SuiteOne", configuration="Debug"),
                                      suite("SuiteOne", configuration="Release")])
        assessment = evaluate(
            inventories=[inventory_record],
            runs=[run("run-one", [gate("SuiteOne", configuration="Debug"),
                                 gate("SuiteOne", "skipped", configuration="Release")])],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([entry["label"] for entry in assessment["gate_set"]],
                         ["pkg/app/SuiteOne (Debug)", "pkg/app/SuiteOne (Release)"])
        self.assertEqual([item["label"] for item in assessment["missing_suites"]],
                         ["pkg/app/SuiteOne (Release)"])

    def test_workspace_qualified_identity_keeps_two_worktrees_independent(self):
        other = "ws_other"
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_A, other: REV_A},
            changed_paths_by_workspace={WORKSPACE: ["pkg/app/Sources/Feature.swift"],
                                        other: ["pkg/app/Sources/Feature.swift"]},
            inventories=[inventory([suite("SharedTests")]),
                         inventory([suite("SharedTests")], workspace=other)],
            runs=[run("run-one", [gate("SharedTests")], workspace=WORKSPACE)],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([item["label"] for item in assessment["missing_suites"]], ["pkg/app/SharedTests"])
        self.assertEqual(assessment["missing_suites"][0]["workspace"], other)
        self.assertEqual(len(assessment["gate_set"]), 1)
        self.assertEqual(assessment["gate_set"][0]["workspace"], WORKSPACE)

    def test_workspace_qualified_failure_is_not_hidden_by_another_worktrees_pass(self):
        other = "ws_other"
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_A, other: REV_A},
            changed_paths_by_workspace={WORKSPACE: ["pkg/app/Sources/Feature.swift"],
                                        other: ["pkg/app/Sources/Feature.swift"]},
            inventories=[inventory([suite("SharedTests")]),
                         inventory([suite("SharedTests")], workspace=other)],
            runs=[run("run-pass", [gate("SharedTests")], workspace=WORKSPACE),
                  run("run-fail", [gate("SharedTests", "failed")], workspace=other)],
        )
        self.assertEqual(assessment["status"], "failed")
        self.assertEqual([item["workspace"] for item in assessment["failing_suites"]], [other])

    def test_stale_discovery_inventory_cannot_establish_verified(self):
        # Discovery listed one suite at revision A. At revision B a second
        # suite exists but the inventory was never revalidated.
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_A)],
            runs=[run("run-one", [gate("SuiteOne")], revision=REV_B)],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(assessment["stale_inventories"][0]["revision"], REV_A)
        self.assertEqual(assessment["stale_inventories"][0]["current_revision"], REV_B)
        self.assertTrue(any("revalidate the inventory" in reason for reason in assessment["coverage_reasons"]))
        # Revalidating at B restores the complete current case.
        fresh = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_B)],
            runs=[run("run-one", [gate("SuiteOne")], revision=REV_B)],
        )
        self.assertEqual(fresh["status"], "verified")
        self.assertEqual(fresh["stale_inventories"], [])

    def test_revisionless_discovery_is_incomplete(self):
        assessment = evaluate(
            inventories=[inventory([suite("SuiteOne")], revision="")],
            runs=[run("run-one", [gate("SuiteOne")])],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(len(assessment["stale_inventories"]), 1)
        self.assertEqual(assessment["stale_inventories"][0]["revision"], "")

    def test_ever_passed_history_survives_skipped_then_removed_inventory(self):
        # Green at A, skipped at B, then the suite disappears from a
        # replacement inventory: the coverage drop must stay named.
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("KeptSuite")], revision=REV_B)],
            runs=[
                run("run-six", [gate("KeptSuite"), gate("DroppedSuite")], revision=REV_A),
                run("run-four", [gate("KeptSuite"), gate("DroppedSuite", "skipped")], revision=REV_B),
            ],
            selected_run_ids=["run-four"],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual([item["label"] for item in assessment["previously_green_missing"]],
                         ["pkg/app/DroppedSuite"])
        self.assertEqual(assessment["missing_suites"], [])

    def test_stale_pass_cannot_clear_a_current_failure_and_failed_batches_do_not_verify(self):
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_B)],
            runs=[
                run("run-pass", [gate("SuiteOne")], revision=REV_B),
                run("run-fail", [gate("SuiteOne", "failed")], revision=REV_B),
                run("run-delayed-old", [gate("SuiteOne")], revision=REV_A),
            ],
            selected_run_ids=["run-pass"],
        )
        self.assertEqual(assessment["status"], "failed")
        self.assertEqual([item["label"] for item in assessment["failing_suites"]], ["pkg/app/SuiteOne"])
        # A batch the caller marks failed cannot establish verification even
        # though its gates are passing.
        failed_batch = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_B)],
            runs=[run("run-failed-batch", [gate("SuiteOne")], revision=REV_B, status="failed")],
        )
        self.assertEqual(failed_batch["status"], "partially_verified")
        self.assertEqual(len(failed_batch["stale_evidence"]), 1)

    def test_interrupted_pass_cannot_clear_a_failure(self):
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_B)],
            runs=[
                run("run-fail", [gate("SuiteOne", "error")], revision=REV_B),
                run("run-interrupted", [gate("SuiteOne")], revision=REV_B, status="interrupted"),
            ],
            selected_run_ids=["run-interrupted"],
        )
        self.assertEqual(assessment["status"], "failed")
        self.assertTrue(any("interrupted" in entry["reason"] for entry in assessment["stale_evidence"]))

    def test_recording_time_dirty_evidence_cannot_establish_verification(self):
        assessment = evaluate(
            inventories=[inventory([suite("SuiteOne")])],
            runs=[run("run-dirty", [gate("SuiteOne")], source_state="dirty")],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertTrue(any("dirty" in entry["reason"] for entry in assessment["stale_evidence"]))
        unrecorded = evaluate(
            inventories=[inventory([suite("SuiteOne")])],
            runs=[run("run-unrecorded", [gate("SuiteOne")], source_state="")],
        )
        self.assertEqual(unrecorded["status"], "partially_verified")
        self.assertTrue(any("not recorded as clean" in entry["reason"]
                            for entry in unrecorded["stale_evidence"]))

    def test_tested_revisions_come_from_selected_runs_not_current_head(self):
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            inventories=[inventory([suite("SuiteOne")], revision=REV_A)],
            runs=[run("run-old", [gate("SuiteOne")], revision=REV_A)],
            selected_run_ids=["run-old"],
        )
        self.assertEqual(assessment["status"], "partially_verified")
        self.assertEqual(assessment["assessed_revisions"], {WORKSPACE: REV_B})
        self.assertEqual(assessment["source_revisions"], [REV_A])
        self.assertEqual(assessment["tested_revisions"], [REV_A])

    def test_workspace_alias_inherits_history_and_prefers_native_inventory(self):
        old = "ws_old"
        assessment = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            changed_paths_by_workspace={WORKSPACE: ["pkg/app/Sources/Feature.swift"]},
            inventories=[inventory([suite("SuiteOne")], revision=REV_A, workspace=old),
                         inventory([suite("SuiteOne"), suite("SuiteTwo")], revision=REV_B)],
            runs=[run("run-old", [gate("SuiteOne")], revision=REV_A, workspace=old),
                  run("run-new", [gate("SuiteOne"), gate("SuiteTwo")], revision=REV_B)],
            selected_run_ids=["run-new"],
            workspace_aliases={old: [WORKSPACE]},
        )
        # The native inventory at B wins over the aliased A inventory, the old
        # pass aliases into the leaf so a re-run satisfies history, and the
        # successor's diff still requires every inherited suite.
        self.assertEqual(assessment["status"], "verified")
        self.assertEqual(assessment["previously_green_missing"], [])
        self.assertEqual([item["label"] for item in assessment["required_suites"]],
                         ["pkg/app/SuiteOne", "pkg/app/SuiteTwo"])
        without_alias = evaluate(
            revision_by_workspace={WORKSPACE: REV_B},
            changed_paths_by_workspace={WORKSPACE: ["pkg/app/Sources/Feature.swift"]},
            inventories=[inventory([suite("SuiteOne")], revision=REV_A, workspace=old),
                         inventory([suite("SuiteOne"), suite("SuiteTwo")], revision=REV_B)],
            runs=[run("run-old", [gate("SuiteOne")], revision=REV_A, workspace=old),
                  run("run-new", [gate("SuiteOne"), gate("SuiteTwo")], revision=REV_B)],
            selected_run_ids=["run-new"],
        )
        self.assertEqual(without_alias["previously_green_missing"][0]["workspace"], old)


class ValidationTests(unittest.TestCase):
    def assert_invalid(self, callback):
        with self.assertRaises(VerificationValidationError):
            callback()

    def test_suite_identity_rejects_unknown_or_empty_fields(self):
        self.assert_invalid(lambda: normalize_suite({"suite": "Suite", "unexpected": True}))
        self.assert_invalid(lambda: normalize_suite({"suite": ""}))
        self.assert_invalid(lambda: normalize_suite({"suite": "Suite\x00"}))

    def test_inventory_requires_state_and_unique_suite_identities(self):
        self.assert_invalid(lambda: normalize_inventory({"package": "pkg", "state": "maybe", "suites": []}))
        self.assert_invalid(lambda: normalize_inventory({"package": "pkg", "state": "complete",
                                                         "suites": [suite("A"), suite("A")]}))

    def test_gate_run_requires_revision_and_a_non_empty_gate_list(self):
        self.assert_invalid(lambda: normalize_gate_run({"gates": [gate("A")]}))
        self.assert_invalid(lambda: normalize_gate_run({"revision": REV_A, "gates": []}))
        self.assert_invalid(lambda: normalize_gate_run({"revision": REV_A,
                                                        "gates": [gate("A", outcome="unknown")]}))

    def test_selection_is_bounded_and_unique(self):
        self.assertEqual(normalize_selection(["a", "b"]), ["a", "b"])
        self.assert_invalid(lambda: normalize_selection(["a", "a"]))
        self.assert_invalid(lambda: normalize_selection("run-one"))

    def test_internal_selection_can_exceed_the_caller_limit(self):
        many = [f"run-{index}" for index in range(250)]
        self.assertEqual(normalize_selection(many, maximum=None), many)
        self.assert_invalid(lambda: normalize_selection(many))


if __name__ == "__main__":
    unittest.main()
