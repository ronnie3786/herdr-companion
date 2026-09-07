# Herdr 0.3.0 beta 1

Pi sessions now form collapsible families in the Mac sidebar. A spawned session appears beneath its parent, including when it runs in another workspace. Cross-workspace children show their workspace so you can see where the work is happening. Search keeps the matching session's ancestors visible, and opening a child expands its family.

The Herdr Pi package records a single parent session ID and derives children from it. New local subprocesses inherit their launching Pi session's ID. Agents receive instructions for forwarding that ID through Herdr and SSH launches. Saved ancestry survives resume and reload; older sessions can be tagged with `/herdr-parent`.

## Setup and compatibility

Install the companion server and its matching Pi package from this release's source revision on each machine. Restart the companion. New Pi sessions use the updated package automatically. Sessions using only the globally installed package can run `/reload` when idle. Sessions launched with an explicit `-e` or `--extension` path should be exited and resumed using the updated installation: `/reload` retains the old launch-time extension path and can load both versions. Historical parentage is not guessed.

The parent field is additive. Existing iPhone and web clients continue to work. The Mac app still connects to older companions, but session families require the updated server and Pi package. Grouping is scoped to the selected machine and spans its workspaces.

The Mac update installs the app only. Use Settings > App updates > Include preview builds, then Herdr > Check for Updates to get this preview. Open a workspace containing a parent session and use its disclosure arrow to collapse or expand children.

This personal testing preview uses Apple Development signing and signed Sparkle updates. It is not notarized.
