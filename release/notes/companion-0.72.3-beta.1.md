# Companion 0.72.3 beta 1

This package stops false "stuck worker" alarms during long builds and restores
Code Factory's automatic merge. It includes everything in 0.72.2 beta 1 and needs
no native app update.

- The First Mate watchdog no longer treats a worker as stalled while its own tool
  is still running, such as a long build or test, as long as its Pi process is
  alive and the tool started less than 45 minutes ago. Before, any 10 minutes
  without Pi events launched an extra advisor session to judge the worker, which
  added host load and could steer or pause healthy work. Runners record their
  open tool executions in `status.json` (`running_tools`); workers started before
  this update keep the old behavior until their next dispatch.
- The scheduler appends a host load sample about once a minute to
  `load-samples.jsonl` in the First Mate runs directory (rotated near 2 MB), and
  runtime health and `watchdog.suspicion` events include `load_average`.
- Code Factory, the Herdr app's own autofix pipeline, merges on its own again.
  PRs stay drafts through implementation, CI, and review; the daemon marks the
  PR ready only immediately before merging the exact head that passed Verify and
  the Opus review. Set `require_ready_approval = true` in `[code_factory]` to keep the per-PR **Approve ready PR** step. First Mate's draft-PR rule
  for agents is unchanged.

Install the wheel in a new versioned runtime, back up private configuration and
state, and update the companion service, Code Factory, and CLI wrappers. Follow
the server update procedure in herdr_harness/README.md.
