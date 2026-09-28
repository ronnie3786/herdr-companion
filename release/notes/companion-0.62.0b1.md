# Herdr Companion server 0.62.0b1

Provides the shared Git comparison and inspection APIs for macOS 0.63.0-beta.1.
PR Review, pane Git and First Mate can compare authorized commits. Questions
inspect exact revision content on demand, and working-tree questions retain a
validated private snapshot. Large diffs preserve the changed-file catalog.

First Mate captures each new workflow step's commit interval and separately
retains the target branch baseline. Earlier feature commits remain available
when the target branch advances. Existing steps without captured evidence are
not reconstructed from timestamps or labels.

## Install separately

Build/install in a new Python 3.11+ runtime from the tested source revision.
Preserve private configuration and use a consistent SQLite backup before
switching the companion service and matching CLI/Pi integration. This release
adds First Mate visit metadata columns through the existing additive migration.
Retain the previous runtime and backup for rollback. Do not interrupt active
workers or replace a user's working checkout during an update.

Existing clients retain their prior APIs. The Mac updater does not install this
package. No iOS update is required for compatibility.

## Verify

Authenticated capabilities must expose `git-comparison-v1` and assistant profile
`git-question-v1`. Compare two commits in a synthetic repository, select a file,
and ask a question about the displayed revision. With narration configured,
verify Breeze pauses for questions and marks Viewed only after playback finishes.
