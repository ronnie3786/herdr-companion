# First Mate stability and recovery

Open **First Mate → Workflow → Stability & recovery** to see the hourly sweep schedule, durable progress checkpoints, recovery decisions, saved sessions, and source-archive references.

- Distinguish stale execution from a healthy scheduler; show active work as **Unverified** when monitoring is unavailable.
- Automatically assess and nudge workers that remain alive without observable progress, then continue from retained work only after a verified stop and safety checks.
- Preserve stage approvals, uncertain external-action safeguards, retry budgets, and current role routing. Detect repeated handoffs without progress and stranded coordinators.
- Add scheduler supervision, free-space admission checks, and bounded private recovery archives. No worktree cleanup, Git reset, commit, or automatic archive restore is performed.

Requires companion **0.39.0b1** and its matching Pi extension for automatic monitoring/recovery (`first-mate-reliability-v1`). Older servers remain compatible but cannot provide these protections. The Mac updater does not install the server package.

Existing executions without trustworthy effect receipts require human inspection. A live hung scheduler is surfaced, not replaced by a competing scheduler. Recovery archives are local, bounded snapshots at stopped recovery boundaries—not full-machine or continuous backups.

This preview preserves the published 0.38 Agent Profiles feature and existing First Mate chat, archive, usage, and role-selection behavior. See `docs/first-mate/reliability.md` for configuration and limits.
