# Companion 0.69.0 beta 1

First Mate now keeps one feature worktree and branch through sequential
implementation, review, feedback, builds, and delivery. New assignments and
workflow stages reuse that checkout and its build cache. Separate worktrees
require an explicit fork for independent parallel work or an experiment.

Workspace locks prevent overlapping writers, including during recovery and
nested worker handoffs. Existing staged, unstaged, and untracked work stays in
place. Reviews remain tied to exact revisions and can be refreshed in the same
assignment after a fix. Unambiguous existing feature worktrees are adopted;
independent histories require an exact source selection. Existing extra
checkouts and caches are retained without automatic deletion.

Install this wheel in a new versioned Python 3.11+ runtime on each execution
host, update the matching bundled Pi package and CLIs, and restart the companion
using the server update procedure. Preserve private configuration and state,
and keep the previous runtime for rollback. The authenticated First Mate
capabilities include `first-mate-feature-workspaces-v1` after installation.

This includes the companion fixes and capabilities from 0.68.0 beta 1. Existing
native clients remain compatible; no Mac or iOS app update is needed for feature
workspace reuse. Continue a feature and open Git to see subsequent assignments
using the same branch and checkout. See [feature workspaces](../../docs/first-mate/workspaces.md)
for fork, recovery, review, and retention behavior.
