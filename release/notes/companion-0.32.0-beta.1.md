# Companion 0.32.0b1

This package supplies the server and shared web Git workbench needed by First Mate Git in **Herdr Companion 0.32.0 Preview 1** on Mac.

## Changes

- Adds authenticated `first-mate-git-v1` workspace discovery and Git endpoints for a feature's project folder and its recorded worker worktrees. No terminal pane is required.
- Reuses the existing Git tools for status, diffs, history, stage/unstage, and file opening, retaining expected-root checks and file/commit validation. Workspace selection uses feature-owned records, not arbitrary client-supplied paths.
- Adds a First Mate embed route to the existing web Git workbench while preserving pane-based Chat Git. Terminal-pane-only contextual Ask is not offered for feature targets.
- Keeps the API additive: existing native clients, browser pane routes, and Pi integrations continue to use their existing contracts. There is no state-format migration for this feature.

## Installation and compatibility

Install the wheel into a **new versioned Python 3.11+ environment** and follow the [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.32.0-beta.1/herdr_harness/README.md#update-the-server). The wheel contains the updated web assets. Preserve private configuration, current state, and the prior runtime for rollback; update matching CLIs and the bundled Pi package as described there. Switch and restart the server only when you explicitly choose to perform that cutover.

This release does not install itself. The Mac updater updates only the native app; it does not deploy this package or restart a running server. Upgrade the owning companion for every machine on which you want First Mate Git. Older hosts show an upgrade-required message in the new Mac surface.

Download the separate [Mac update](https://github.com/ronnie3786/herdr-companion/releases/tag/macos-v0.32.0-beta.1) through Herdr's signed updater. No iOS binary is published here.

## Verify the feature

1. Confirm the authenticated capabilities advertise `first-mate-git-v1`.
2. Open a feature in Mac First Mate and choose **Git**. Inspect its project folder, then select a recorded worker worktree and confirm the path and changes switch together.
3. Choose **Open Git in New Window**, return to Chat or another feature, and confirm the separate window remains on the original machine and workspace.
4. Use a synthetic repository to inspect staged, unstaged, and untracked diffs, stage/unstage a file, and browse commit history. Removing a selected worktree must show an unavailable state rather than fall back to the project.

`source-revision.txt` identifies the source commit; `SHA256SUMS` records the downloadable artifact hashes.
