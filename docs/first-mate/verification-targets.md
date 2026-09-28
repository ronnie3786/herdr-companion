# Explicit verification targets

A worker can test a separate worktree or clone while its managed process stays
in the assignment's original directory. On its first `fm_record_verification`
report for that target, supply both optional fields:

- `target_workspace_path`: the absolute Git working-tree root.
- `baseline_revision`: the full commit SHA anchoring cumulative changes.

The companion resolves the canonical root and verifies repository identity
using the common Git directory or an identical normalized origin. The baseline
must resolve to that exact commit and be an ancestor of the target's current
HEAD. The companion then observes HEAD and dirty state in the target itself.
The reported tested `revision` remains the worker's claim and is compared with
that observed HEAD, as before. Dirty or mismatched evidence cannot verify the
current source.

Registration is saved in the private runtime directory with assignment,
generation, session and timestamp provenance before the gate batch is retained.
An assignment keeps one immutable target. Later reports may omit both fields;
the registration survives server restart and successor generations. A new
assignment with explicit source-assignment lineage can inherit that target.
Use a new assignment to select a different target or baseline. Registration
does not move the worker, acquire write permission, or mutate Git state.

The target and baseline add to cumulative assessment scope. Original assignment
workspaces, retained runs, failures, and previously passing suites remain in
scope. Each target also retains the earliest assignment/source-lineage baseline:
the supplied baseline can widen discovery but cannot remove prior changes.
An unavailable or nonancestor retained baseline leaves scope unknown.
A correctly recorded clean target can therefore coexist with a partial
or failed overall assessment. This change does not repair historical runs
attributed to the wrong directory, discard old failures, or change release
gates. Historical reassessment requires a separate explicit correction.

Regression coverage is in `tests/test_first_mate_verification_targets.py`,
including dirty source versus clean target, dirty target, retained failures,
restart and successor continuity, immutable registration, invalid baselines,
and matching versus unrelated repositories.
