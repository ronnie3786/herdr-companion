# Companion 0.30.0b1

First Mate now collects recorded model usage, tokens, and estimated USD costs from its saved Pi sessions. The additive `first-mate-usage-v1` API supplies per-session, per-agent, child-tree, and whole-task totals for native and browser clients.

Task totals include all retained managed coordinator history, workers and nested children, retries, handoff predecessors/successors, and watchdog/recovery advisors. Repeated dispatches of one saved session count once. Totals do not depend on the visible session-history limit. Existing records are backfilled on read without invoking a model. Usage updates do not require a workflow transition.

Missing, unreadable, or incomplete usage is reported as unavailable or partial, not silently converted to zero. Pi-reported cost is an estimate, not a provider invoice; subscription providers may report zero. Arbitrary unregistered Pi sessions and external-service charges are outside the managed accounting scope.

## Installation and compatibility

Install the wheel in a new versioned Python 3.11+ environment and follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.30.0-beta.1/herdr_harness/README.md#update-the-server). Preserve private configuration, state, and the previous runtime for rollback. Update the matching installed CLIs and bundled Pi package as part of the server update. Restart the companion service only when ready for that explicit server cutover.

This package does not install itself. The Mac updater updates only the Mac app. **Mac 0.30.0-beta.1** displays the new usage data; existing Mac, iOS, and web API consumers remain compatible. The wheel contains the updated First Mate browser inspector; the matching iOS source also supports usage, but this release does not distribute an iOS binary.

After installation, open First Mate on the updated host. Compare the cost beside a task's ticket label with its Overview total, then inspect Agents and saved sessions for the recorded model/token breakdown and any coverage warnings. A task with no reported pricing must not be treated as a free task.
