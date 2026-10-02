# Completion and draft PR policy

Install the matching companion wheel and bundled Pi extension package on every
execution host. The Mac app updater does not install this policy. A current
companion advertises `first-mate-lenient-verification-recording-v1` and
`herdr-workflow-policy-v1` in its capabilities.

## Completion

An outcome's optional verification references no longer prevent otherwise valid
completion. The companion resolves retained evidence from the assignment, its
earlier executions, source assignments, and child assignments once. Omitted run
IDs select the latest eligible batches at the reported source revision; an
explicit empty selection remains empty. Original producers and timestamps stay
intact. Unknown or out-of-scope references produce the same generic diagnostic
without exposing another feature's evidence.

Assignment results expose `verification_recording` separately from work status.
Missing references remain incomplete or unavailable. A bounded assessment read
cannot undo an already recorded batch or stall stage completion. No worker is
restarted merely to attach optional evidence. Replayed outcome receipts retain
their original response, including receipts created before this update.

Required source revisions, active ownership, current generations, dependencies,
human gates, review, tests, and release checks remain enforced. Coverage still
examines later failures and source changes. Completing work never turns missing
evidence into a passing test result.

## Pull requests

The shared operating instructions require draft creation (`gh pr create --draft`)
for First Mate, the lead, workers, and ordinary Companion agents. General
instructions to open a PR, finish work, or keep sessions moving do not authorize
ready-for-review status. That requires an explicit human instruction for the
specific PR. Readiness does not itself authorize reviewers, merge, or release.

The lead preserves the original durable human direction in relay metadata. The
receiver distinguishes that direction from the lead's suggested wording. An old
relay without its original direction cannot confer readiness permission. These
instructions are independent of pinned personality snapshots and are injected
on each newly started or resumed dispatch and each extension-controlled turn.

Code Factory, the Herdr app's own autofix pipeline, is separate from First Mate.
It creates draft PRs and marks one ready only immediately before merging the exact
head that passed Verify and its internal review; the `herdr-autofix` label is the
operator's authorization for that pipeline. `require_ready_approval = true` makes
it park each reviewed draft for an explicit operator action instead. See
[Code Factory](../code-factory.md).

For ordinary Pi shell and GitHub tools this is an operating instruction, not a
credential sandbox. A process that retains unrestricted GitHub write credentials
can bypass it. Confining all GitHub mutations to a separately authenticated human
authorization broker is outside this package's enforcement boundary.

## Adoption and verification

Back up the launcher and SQLite state using SQLite's backup API. Install the
wheel into a new versioned environment, verify its hash and the configuration,
and update the service launcher and Pi package reference together. Preserve the
old runtime for rollback. Restart only the companion. Existing detached First
Mate workers retain their current loaded extension and instructions until their
next safe dispatch; do not terminate active work just to adopt policy. Ordinary
Pi panes need an extension reload or a new session.

Check authenticated capabilities, the installed policy file, and the exact wheel
revision on each host. Synthetic tests cover handoffs, idempotent receipts,
missing references, stale owners, later failures, cross-machine relay origin,
draft creation, quiet parking, and explicit readiness authorization. No live PR
is needed to verify these contracts.
