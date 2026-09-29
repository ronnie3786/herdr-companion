# Herdr Companion 0.70.3-beta.1

First Mate now shows consistent execution status across the conversation list, current focus, and workflow. Implementation and test-fixture cleanup use the active worker role instead of being mislabeled as QA. A draft PR link no longer implies readiness for review, and custom workflows no longer show an invented six-step completion percentage.

The matching companion update detects real progress inside nested Git worktrees, preventing false repeated-handoff blockers. Stopped handoffs settle consistently while preserving their checkpoints.

First Mate replies no longer receive generated verification inventories. Detailed evidence remains in Verification and Documents. Skims retain a follow-up only when the original reply explicitly contains it, without adding a new action or scope. Older generated appendices are hidden and incompatible saved skims fall back to the cleaned full reply.

Compatibility: install companion 0.65.2b1 separately on each execution host for the status, recovery, and reply changes. The Mac updater installs only the app. Existing configuration, conversations, and saved sessions are retained; no new API request fields are required.

To check the changes, reopen a First Mate conversation and compare its list badge with Current Focus. Fixture cleanup should show implementation activity, blocked work should stay blocked throughout, and new replies should have no automatic coverage appendix or invented follow-up.
