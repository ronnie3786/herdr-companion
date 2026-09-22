# First Mate Git on Mac

First Mate Git is a full-width Git workbench attached to a selected feature and
its owning companion machine. It reuses the browser workbench used by pane Git:
working-tree status, persistent diffs, commit history, stage/unstage, and local
open or reveal actions have the same behavior.

## Navigate and choose a workspace

1. Open **First Mate** in the Mac navigator and select a feature.
2. Use the **Chat / Git** control above the feature. Switching views does not
   replace the First Mate store, so its draft, conversation, selected workflow
   visit, and inspector state remain intact.
3. In Git, choose **Project workspace** (the default) or one of the assignment
   worktrees recorded by that feature.

The Git page stays mounted during companion catalog refreshes and transient
terminal reconnects, so the open diff, selection, and scroll position do not
flash back to a loading screen. Use **Refresh Git workspaces** to update the
catalog explicitly; the workbench continues to poll Git status on its own.

The picker never guesses the newest worker, borrows the active Chat pane, uses a
terminal's current directory, or creates a shell. Concurrent workers are distinct
choices. Paths are visible for context but are not editable selectors. A worktree
that has since been removed stays listed and reports that it is unavailable; it
never falls back to the project checkout.

## Pop-out windows

Choose **Open Git in New Window** beside the workspace picker. The window is
identified by machine ID, feature ID, and workspace ID:

- reopening the same target focuses its existing window;
- another workspace opens a distinct window;
- changing the main window's machine, feature, or workspace does not retarget it;
- reconnecting or changing credentials re-resolves the same saved machine;
- deleting a feature or removing a worktree produces an unavailable state rather
  than redirecting the window.

The pop-out is presentation only. Closing it does not stop agents or modify the
feature.

## Compatibility and limitations

The companion must advertise `first-mate-git-v1`. An older companion shows a
server-update message. First Mate Git does not require a live terminal pane: an
authenticated capability and catalog response from the owning companion is
enough. An unreachable or removed owning host, missing project directory,
non-Git directory, invalid recorded root, and failed refresh remain explicit
load or retry states.

First Mate Git intentionally has no terminal pane. **Ask AI about selection** is
therefore hidden: that contextual action requires an actual terminal pane and
never falls back to a generic agent. Use the feature conversation for direction.
There is no browser-shell First Mate navigation in this version; the explicit
`#firstMate=<feature>&workspace=<workspace>&view=git&embed=1` route is for the
authenticated native web container.

## Manual verification checklist

- [ ] Select a feature, type an unsent Chat draft, switch to Git and back, and
      confirm the draft and workflow/inspector selection remain.
- [ ] Confirm Project workspace is selected initially and its path is visible.
- [ ] Choose two recorded assignment worktrees and confirm each shows its own
      status without choosing a "latest" worker implicitly.
- [ ] Remove a recorded worktree and confirm retry reports it unavailable without
      showing the project checkout.
- [ ] Exercise working-tree diff, staged/unstaged changes, untracked files,
      commit files, commit diff, open, and reveal on a synthetic repository.
- [ ] Confirm the selection Ask affordance is absent in First Mate Git and still
      present in pane Git.
- [ ] Pop out project and worker targets; confirm each window remains pinned as
      the main window changes machine, feature, and workspace.
- [ ] Stop only the terminal-pane connection while leaving the companion API
      reachable and confirm the open Git page, diff, and scroll position stay
      visible across reconnects and **Refresh Git workspaces**.
- [ ] Disconnect/reconnect the owning companion and confirm the same target reloads.
- [ ] Verify an older companion shows the compatibility message.
- [ ] Verify VoiceOver labels for Chat/Git, workspace, refresh, pop-out, stage,
      unstage, diff, and retry controls.
