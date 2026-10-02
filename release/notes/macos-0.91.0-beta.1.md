# macOS 0.91.0-beta.1

Preview channel · build 141.

## PR Review: undo and redo Viewed

Press ⌃Z to undo your last Viewed toggle and ⌃⇧Z to redo it. Both marking a file viewed and clearing Viewed are supported, in the main PR Review window or a popped-out review window. ([Issue #162](https://github.com/ronnie3786/herdr-companion/issues/162), [PR #166](https://github.com/ronnie3786/herdr-companion/pull/166))

## Companion compatibility

This release updates the Mac app only and adds no companion API requirements. No companion update is needed for Viewed undo/redo. The companion server, CLI and Pi package are published separately.

## Install and verify

With preview releases enabled, open **Settings → Updates** and choose **Check for Updates…** to install **0.91.0-beta.1** (build 141).

In PR Review, mark a file Viewed, press ⌃Z to undo, then ⌃⇧Z to redo. Repeat after clearing Viewed, and try both the main and popped-out review windows.
