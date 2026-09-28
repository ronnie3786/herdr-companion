# Herdr Companion server 0.57.0b1

First Mate can continue through routine recovery without repeatedly asking for
permission that the operator already granted.

- Publishes one primary conversation response when a checkpoint already answered
  the turn. The closing response remains in the activity journal.
- Preserves authorized follow-up stages and permits the current coordinator to
  refine an empty stage without invalidating that authorization.
- Retries safe transient coordinator failures twice with backoff. It does not
  replay uncertain or externally mutating operations, override a human checkpoint,
  or retry after a response was already published.
- Retains lead relay and feature-creation receipts across retries, preventing the
  same action from duplicating a human instruction or feature after an interruption.
- Bounds worker status and document references, breaks the recovery-acknowledgment
  context loop, and gives a successor a limited opportunity to perform useful work.
- Renews recovery budgets only after independently observed worktree or completed
  child progress. Repeated handoffs without progress trigger one focused repair
  before stopping with retained diagnostic evidence.
- Isolates malformed jobs and feature-specific failures so healthy features can
  keep running. Shared storage failures still stop writes.
- Accepts an explicitly registered verification worktree and baseline, validates
  repository provenance, and records the actual tested revision. Existing failures
  and verification coverage are retained.

Install the wheel in a fresh Python 3.11+ environment using the server procedure in
`herdr_harness/README.md`. Build web assets before packaging. Run
`scripts/verify-installed.py`, validate the destination's existing private
configuration, and take consistent SQLite backups before switching the companion,
its CLI wrappers, enabled workers, and the wheel's bundled Pi package together.
Preserve unrelated Pi packages and disabled services. Retain the prior runtime and
service definitions for rollback; do not restore an old database over newer work.

The matching Mac app is **0.57.0-beta.1**. Older clients remain compatible with the
API additions, but the new Mac app also groups historical same-turn duplicate
replies and identifies the current decision checkpoint. Neither the Mac updater
nor publishing this wheel performs a server cutover or an iOS installation.
Existing paused features stay paused. Historical verification records are not
rewritten by this update.
