# Herdr Companion server 0.46.2b1

First Mate keeps PR links relevant to the feature being worked on.

- Automatic discovery checks the feature's named PR, local repository, and ticket context. Background research, historical PR lists, and dependency mentions no longer become feature PR links just because they appeared in saved evidence.
- Existing automatic links are rechecked. Unrelated or unverified links are hidden without deleting their records; use **Documents → Links → Show hidden → Restore** to keep one explicitly.
- Explicit user saves, user titles, restores, and hide choices are preserved. Managed agents also receive clearer instructions to save the implementation or review PR for the current feature.
- Discovery uses local evidence and Git configuration only. It does not call GitHub, fetch a destination, or infer PR lifecycle state.

## Compatibility and installation

This server update includes the matching First Mate Pi extension. Existing Mac,
iOS, and web clients remain compatible; no new Mac app is required. The Mac
updater does not install companion packages.

Install the wheel into a new versioned Python 3.11+ environment, retain private
configuration and state, validate configuration and Fleet paths, take a consistent
database backup, then switch the companion and its CLI/Pi integration using the
server update procedure. The saved-link migration is additive and preserves all
records. Retain the old runtime and backup for rollback; an older server does not
apply the new contextual visibility filter.

## Verify the behavior

Refresh the affected First Mate feature's Overview. Only matching or explicitly
saved PRs should appear. Inspect hidden links in Documents to confirm unrelated
records remain available, and restore one explicitly if the feature needs it.
Features without enough ticket or repository context can still save links manually.
