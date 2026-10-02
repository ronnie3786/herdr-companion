# Companion 0.72.2 beta 1

This package keeps finished First Mate work from stalling on verification
bookkeeping and makes draft pull requests the default for every agent. It
includes everything in 0.72.1 beta 1 and needs no native app update.

- Workers can finish when optional verification evidence is incomplete. An
  outcome no longer fails with "Verification run does not belong to this
  execution" after a handoff or retry: the companion resolves retained results
  from the assignment's earlier executions, source assignments, and children.
  When run IDs are omitted, it selects the latest eligible batches at the
  reported revision. Assignment results show `verification_recording` separately
  from work status. Agents are told not to retry or hand off only to re-record
  evidence. Coverage, failures, required gates, and release checks are unchanged.
- Agents create pull requests as drafts. A general instruction to open a PR or
  keep work moving does not authorize ready-for-review; that needs an explicit
  human instruction for the specific PR. The lead preserves the original human
  direction when relaying a message, so a relay cannot grant new permission.
- Code Factory creates draft PRs and parks after its internal review and CI. A
  new dashboard action, after the human marks the exact PR ready in GitHub,
  lets it continue. A PR that is already ready without a draft-readiness record
  is left for the operator to finish by hand.
- Adds `first-mate-lenient-verification-recording-v1` and
  `herdr-workflow-policy-v1`. The First Mate store gains one column on first
  start; no migration step is needed.

Install the wheel in a new versioned runtime on every execution host, back up
private configuration and state, and update the companion service, background
workers, Code Factory, and CLI wrappers. Running First Mate workers keep their
current instructions until their next dispatch. Follow the server update
procedure in herdr_harness/README.md and see
docs/first-mate/completion-and-draft-pr-policy.md.
