# Companion 0.74.1 beta 1

This package fixes failure handling found in the 2026-09-30 First Mate audit. It
includes everything in 0.74.0 beta 1 and needs no native app update.

- When SQLite has already rolled a transaction back itself, for example on a full
  disk, the stores no longer issue a second `ROLLBACK`. That second rollback failed
  with "cannot rollback - no transaction is active" and hid the real error.
  This covers First Mate, control, PR Review, notes, Agent Profiles, Agent Roles,
  Code Factory and simulator preview stores.
- The PR Review status refresh stops its batch quietly when the review store
  can't be written, instead of raising from its error path. The next scheduled
  refresh retries.
- First Mate removes `runtime-error.json` after the next healthy scheduler pass,
  including a file left behind by an earlier run, so a recovered error no
  longer looks current.
- The stability sweep no longer wakes a coordinator that has already reported
  to the human since its stage's last outcome settled. Those turns were waiting
  on the human, and two wake-ups ended in a "did not settle the current stage"
  block.
- Second Mate reports tests in chat as one plain line, such as "Tests: 42
  passed; UI tests not run because no simulator was free", without internal
  coverage terms.

The Mac app's own source also stops starting hang diagnostics when it runs as a
test host, so local Mac test runs no longer write to the user's hang log. That
change ships with the next Mac app release.

Install the wheel in a new versioned runtime, back up private configuration and
state, and update the companion service, Code Factory, and CLI wrappers. Follow
the server update procedure in herdr_harness/README.md.
