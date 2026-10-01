# Companion 0.72.1 beta 1

This package keeps stuck First Mate work recoverable and adds checkout-independent
Second Mate tasks. It needs no native app update.

- Fixes automatic recovery assessments that never started. The read-only recovery
  advisor runs without Pi extensions, but it was also given
  `--herdr-parent-session-id`, a flag only the semantic bridge registers. Pi
  exited on the unknown option, First Mate reported "Pi did not confirm its saved
  session during startup", and each failure used up a recovery attempt until the
  assignment needed a human reset. The advisor now starts without the flag; its
  job record keeps the parent session.
- Adds `first-mate-independent-workers-v1` (first deployed as 0.72.0b1, never
  published). Second Mate can delegate research or authorized PR-description work
  that needs no checkout with `workspace_mode: independent` and an
  `independence_reason`. These tasks run beside code edits in private scratch
  directories and create no Git worktree. Work that needs unfinished code or the
  same writable checkout stays ordered. See docs/first-mate/workspaces.md.

Install the wheel in a new versioned runtime, back up private configuration and
state, and update the companion service, background workers, and CLI wrappers.
Preserve the separate terminal service and running First Mate workers. Follow the
server update procedure in herdr_harness/README.md.
