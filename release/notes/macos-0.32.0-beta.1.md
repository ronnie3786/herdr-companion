# Herdr Companion 0.32.0 Preview 1

## First Mate Git workspaces

- Open **First Mate**, select a feature, then choose **Git** to inspect its project folder with the same Git workbench used by Chat: changed files, staged and unstaged diffs, untracked files, commit history, and stage/unstage actions.
- Use the workspace picker to inspect a recorded worker worktree. The project folder is the default; parallel workers are never selected by guessing which one is active.
- Choose **Open Git in New Window** to keep that machine, feature, and workspace in a separate resizable Git window while you return to the conversation or inspect another feature. Opening the same target reuses its window.
- First Mate Git works without a terminal pane. Missing folders, deleted worktrees, API-unreachable companions, and unsupported servers report their state rather than switching to a different repository.

## Compatibility and installation

Install the Mac update through **Herdr Companion → Check for Updates…** with preview builds enabled. This is a signed personal-testing development build, not a notarized Developer ID release.

First Mate Git requires the matching **companion 0.32.0b1** package with updated web assets and the additive `first-mate-git-v1` capability on each feature's owning machine. Download it from the separate [companion release](https://github.com/ronnie3786/herdr-companion/releases/tag/companion-v0.32.0-beta.1) and follow its server update instructions. **The Mac updater does not install or restart companion servers.** Other existing Mac features and pane-based Chat Git remain available on compatible older servers.

The Git workbench reuses existing repository/path validation. First Mate's feature-scoped view does not offer the terminal-pane-only contextual **Ask** action. No iOS binary or standalone First Mate browser navigation is added by this release.

See [First Mate Git](https://github.com/ronnie3786/herdr-companion/blob/macos-v0.32.0-beta.1/docs/first-mate/git.md) for workspace selection, window behavior, and checks.
