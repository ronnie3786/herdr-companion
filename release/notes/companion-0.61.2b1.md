# Herdr Companion server 0.61.2b1

First Mate no longer stops an actively working coordinator merely because its
turn has reached ten minutes.

- Separate inactivity from total runtime. New coordinator turns use the existing
  `coordinator_timeout_seconds` setting as an inactivity budget (default 600
  seconds). Model output and completed tools renew that budget; telemetry and
  RPC acknowledgments do not.
- Add `coordinator_max_seconds`, an absolute ceiling with a 3600-second default.
  Activity never extends this ceiling. The supervisor nudges a long-running
  coordinator once to finish or delegate work within the existing authorization.
- Explain why automatic continuation was declined. Interrupted replies distinguish
  completed workflow operations from other tool receipts, instead of implying no
  tools ran when the coordinator was using its shell.

This is a server-only update, compatible with existing Mac and iOS clients.
Install the wheel and bundled Pi package using `herdr_harness/README.md`, verify
the installation with `scripts/verify-installed.py`, and preserve private
configuration and consistent state backups during service switching. The Mac
updater does not install this package.

Existing private timeout values become inactivity settings for new coordinator
turns. Running or spooled executions keep their persisted limits. Failed messages
are retained but are not replayed by installation. Human checkpoints, paused
work, and external-effect reconciliation remain enforced.
