# Companion 0.65.2b1

- Derive First Mate activity from current assignment roles and explicit phase names. Do not infer QA from test-related stage keys or review readiness from a saved PR URL.
- Detect edits and commits inside nested Git worktrees when applying handoff retry budgets. Settle stopped blocked handoffs without restarting them or discarding checkpoints.
- Keep detailed verification evidence out of conversation prose while preserving assessments and verification gates.
- Require skim follow-ups to match explicit original questions or suggestions. Hide generated legacy verification appendices and fall back to full replies when old skim anchors no longer match.

Deploy the wheel with freshly built web assets into a new versioned runtime. Preserve private configuration and state, use consistent SQLite backups, update matching CLI and Pi package paths, and keep the previous runtime for rollback. Existing detached First Mate executions must survive the service update. New coordinator turns use the updated instructions; a live executor keeps its existing context until its next turn or handoff.

The companion remains compatible with existing native clients. Mac 0.70.3-beta.1 also updates Current Focus and workflow status labels. The app updater does not install this server package.
