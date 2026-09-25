# First Mate gate verification

First Mate's workflow status and its verification verdict answer separate
questions. Workflow status says where a stage is (running, coordinating,
awaiting direction, and so on). A verification verdict says which suites
passed or failed, in which packages, on which source revision. The two never
replace each other: a feature can be parked while its verification is
**Partially verified**, and a workflow badge is never proof that tests ran.

The incident shape this feature fixes: a feature reported "all gates green"
over a narrower dispatch after an earlier, broader run had been green at an
older revision. The omitted suite was failing at the current revision, and
nothing in the report named the suites the green covered. First Mate now keeps
the feature-wide run history, names previously passing suites that drop out of
the current gate set before it parks, records the exact gate set with the
verdict, and labels incomplete coverage **Partially verified** instead of
green.

All examples, fixtures, and identifiers in this guide are synthetic. The
private project, ticket, host, session, and commit identifiers from the
original report are incident context only and are not retained in source,
fixtures, screenshots, or documentation.

## Evidence model: inventories, runs, assessments

Three record types stay distinct.

| Record | Question it answers | Retention |
| --- | --- | --- |
| Discovery inventory | Which suites exist in one workspace package? | Upserted per feature/workspace/package; a later inventory for the same package replaces the earlier one. |
| Gate run | What did one execution actually run, and what happened? | Append-only; a run is never rewritten or deleted, including failures, errors, skipped suites, and interruptions. |
| Assessment | What is the current coverage verdict? | Computed by the companion, recorded with checkpoints and parks, and recomputed live for detail and status reads. |

A **suite identity** is the repository-relative package directory, the suite or
test-target name, and the relevant test configuration. An empty package means
the repository root. `pkg/one/SharedTests` and `pkg/two/SharedTests` are two
different suites, and `pkg/app/SuiteOne (Debug)` and `pkg/app/SuiteOne
(Release)` are two different suite entries. The exact runner selector is
retained as display and replay evidence but is not part of identity. Display
labels use `package/suite` with the configuration appended, for example
`pkg/app/SuiteOne` or `pkg/app/SuiteOne (Release)`.

**Inventories versus selected gates versus history.** An inventory says what
exists; a gate run says what was executed; an assessment selects retained runs
and decides whether their results cover the changed packages at the current
revision. Selecting a run never removes other runs from the ledger: a suite
that was green earlier and is missing from the current gate set is still named.
Replacing an inventory does not erase run history either, so a suite dropped
from a replacement inventory can still appear as previously passing and
missing.

### Worker-reported evidence, not independent proof

Typed inventories and results are exactly what the managed worker reported,
with retained provenance (visit, assignment, native session, generation). First
Mate does not run the project's test discovery, parse arbitrary command output,
or infer suites from aggregate counts, command strings, or naming conventions.
`state: "complete"` means the worker reported that it discovered every suite in
that package; it is not independent proof that arbitrary project discovery was
exhaustive. Consequently:

- an incomplete or missing inventory keeps coverage partial;
- a changed path that no discovered package contains keeps coverage partial;
- an aggregate "N tests passed" claim never establishes suite coverage;
- missing evidence stays **Verification unavailable**, never green.

## Freshness: evidence is bound to the current revision

The companion observes each deliverable workspace's current HEAD and cumulative
changed paths from the earliest retained assignment baseline, plus uncommitted
working-tree paths. A retained run is **fresh** only when:

- the run reported the exact current revision for that workspace;
- the run was not interrupted; and
- the current revision could be observed at assessment time.

A new commit or an unreadable revision makes earlier evidence stale, and
uncommitted changes keep scope incomplete so no run can establish current
verification. A selected run that no longer matches remains listed in
`stale_evidence` with its recorded revision and the reason, but it cannot
establish current verification. A later failure always supersedes an earlier
pass, and choosing a passing subset of runs cannot hide it: the assessment
examines the latest retained result for each suite, even when that suite is
omitted from the selected gate set.

## Verdict semantics

| Status | Label | Meaning |
| --- | --- | --- |
| `verified` | Verified | Complete, current scope; every suite belonging to every changed package has a current fresh passing result; no stale, failing, unmapped, incomplete, or dropped previously passing evidence remains. |
| `partially_verified` | Partially verified | Structured evidence exists, but at least one coverage requirement is unmet: a missing or incomplete inventory, an unmapped changed path, a required or previously passing suite without a current pass, stale evidence, a failure in the selected set, or an unknown selected run. |
| `failed` | Failed | The latest retained result for at least one suite is `failed` or `error`. This stays visible even when the failing suite is omitted from the selected passing subset. |
| `unavailable` | Verification unavailable | No structured inventory or gate run is retained. Legacy features and workers that never reported remain here. |

Only the complete, current, passing case is **Verified**. Everything else that
has evidence is **Partially verified** or **Failed**; absent evidence is
**Verification unavailable**. Missing evidence is never treated as a pass.

### Coverage drops and gaps

Every assessment carries the fields that explain it:

- `gate_set`: the exact selected results with package-qualified labels, outcomes, tested revisions, run identity, and freshness.
- `required_suites`: the suites of every changed package according to the retained inventories.
- `missing_suites`: required suites without a current passing result, with the reason `never run` or `no current passing result`.
- `previously_green_missing`: suites whose latest retained result is a pass but which have no current fresh passing result. These are the coverage drops; they are named before a checkpoint parks.
- `failing_suites`: the latest failing result per suite, independent of the selected subset.
- `stale_evidence`: selected runs that no longer match the current revision, with the recorded revision and reason.
- `coverage_reasons`: deterministic human-readable explanations for each unmet requirement.

Human-facing summaries render the same list. A checkpoint or informal park whose
assessment is not **Verified** appends a deterministic
`Verification coverage: <label>` note naming failing, missing, and previously
passing dropped suites, so the warning travels with the conversation itself.

## Synthetic reproduction

The deterministic fixtures in `tests/test_first_mate_verification.py` and
`tests/test_first_mate_verification_runtime.py` use synthetic packages,
suites, and revisions. They reproduce the incident and its recovery. Run them
with:

```sh
python3 -m unittest tests.test_first_mate_verification tests.test_first_mate_verification_runtime
```

### Six suites to four

1. Revision A: six suites are green. The assessment is **Verified**, and its gate set lists all six.
2. The source revision advances to B and the inventory is recorded at B.
3. Only four suites are re-run and selected at B. The assessment becomes **Partially verified** and names the two omitted suites in both `missing_suites` and `previously_green_missing`. The gate set lists only the four B results, and selecting the earlier A run as well reports it in `stale_evidence` with its recorded revision.

Covered by
`CoverageRulesTests.test_six_to_four_omission_is_partial_and_names_previously_green_suites`
and the end-to-end
`VerificationRuntimeTests.test_six_to_four_omission_survives_restart_and_names_dropped_suites`.

### Complete-coverage recovery and supersession

A fresh six-suite batch at the current revision restores **Verified**; the
earlier stale run stays in the ledger for history, a selection containing only
the fresh run reports no `stale_evidence`, and the earlier gate set is no
longer used to establish the current verdict. If a later batch reports a
failure, the verdict becomes **Failed**, and selecting only the older passing
run cannot hide it. Covered by
`test_stale_revision_is_partial_until_fresh_complete_evidence_arrives`,
`test_later_failure_supersedes_an_earlier_pass_and_cannot_be_hidden`,
`test_partial_selection_of_latest_failure_is_visible`, and
`test_stale_head_cannot_verify_and_later_failure_supersedes_a_pass`.

### Restart, handoff, and later stages

History belongs to the feature, not to a store instance or a session. Closing
and reopening the store keeps the verdict and its gate set. A worker handoff
and a later stage keep the earlier runs, default the later selection to the new
stage's own runs, and still name the dropped suites. Covered by
`test_stage_completion_persists_the_scoped_verdict_and_gate_set_atomically` and
`test_history_survives_worker_handoff_and_a_later_stage`.

### Alternate packages and configurations

- Two changed packages each declare a suite named `SharedTests`; running only the first leaves `pkg/two/SharedTests` missing. Duplicate display names never collapse.
- `Debug` and `Release` entries for the same suite name stay distinct; a passing `Debug` result does not cover a skipped `Release` entry.
- A changed path outside every discovered package is reported in `unmapped_paths` and keeps coverage partial.
- A separate deliverable worktree is assessed on its own revision; the primary checkout's evidence does not cover it.

Covered by
`test_duplicate_display_names_in_different_packages_stay_distinct`,
`test_skipped_and_multiple_configurations_are_represented_exactly`,
`test_multiple_changed_packages_union_their_required_suites`,
`test_incomplete_inventory_and_unmapped_paths_lower_coverage`,
`test_never_run_required_suite_is_partial_and_duplicate_names_stay_distinct`,
and `test_isolated_workspace_scope_ignores_the_primary_checkout`.

## Where humans inspect the gate set

| Surface | What it shows |
| --- | --- |
| Mac and iOS First Mate **Overview** | A Verification section separate from workflow status: status, tested revision(s), the full package-qualified gate set with per-suite outcomes, and named missing, previously passing dropped, failing, and stale evidence. Long lists disclose their remainder instead of truncating. Offline cached evidence is badged **Last reported** and is never silently refreshed into green. |
| Browser `/first-mate/` Overview | The same section, tones, disclosure, and last-reported badge. |
| Checkpoint and park messages | The canonical `Verification coverage: …` line naming failing, missing, and previously passing dropped suites; the message metadata carries the compact gate set. |
| Authenticated feature detail and CLI | `feature.verification` on summaries and detail; detail also returns `verification_runs` and `suite_inventories`; `herdr-first-mate get` passes them through unchanged. |
| Managed `fm_status` | The scoped `verification` assessment and a bounded `verification_runs` list for the coordinator, worker, or advisor. |
| Workflow badges | Workflow only. A parked green badge is an attention signal, not test evidence. |

Clients never recompute coverage. They decode the companion's assessment and
present exactly the gate set, tested revision, and gaps it names. An unknown
future status is retained verbatim and never treated as verified.

## Compatibility and installation

- The companion advertises `first-mate-verification-v1` at both capability
  surfaces. The API is additive: older clients ignore `verification`,
  `verification_runs`, and `suite_inventories`, and newer clients accept their
  absence.
- A legacy feature or an older companion that omits the fields shows
  **Verification unavailable**. Malformed or partial payloads degrade
  conservatively, and a delayed response or feature/host switch cannot
  resurrect a stale **Verified** state.
- Recording happens through the managed worker's typed
  `fm_record_verification` tool inside the First Mate extension; there is no
  new HTTP mutation route. The companion and Pi extension must be upgraded and
  restarted together (the extension verifies its own module path), and that
  package is installed separately. The Mac updater installs only the Mac app.
- The iPhone/iPad build and the browser assets ship separately from the Mac
  app. None of these steps implies a production server cutover; exercise them
  against a disposable companion with synthetic data first.
- Verification changes no workflow authorization, human gate, writer
  ownership, revision fencing, or authorized follow-up stage. A stage may park
  with an explicit partial-verification warning.

See the [runtime guide](runtime.md) for recording behavior, the
[API contract](build-contract.md) for the exact fields and tool schema, and
[delivery verification](verification.md) for the final checklist.
