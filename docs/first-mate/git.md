# First Mate Git on Mac

First Mate Git is a full-width Git workbench attached to a selected feature and
its owning companion machine. It reuses the browser workbench used by pane Git:
revision comparisons, contextual questions, working-tree status, persistent
diffs, commit history, stage/unstage, and local open or reveal actions have the
same behavior. See [shared Git comparisons](../shared-git-diff.md) for the
comparison and AI inspection contract.

## Navigate and choose a workspace

1. Open **First Mate** in the Mac navigator and select a feature.
2. Use the **Chat / Git** control above the feature. Switching views does not
   replace the First Mate store, so its draft, conversation, selected workflow
   visit, and inspector state remain intact.
3. In Git, choose **Project workspace** (the default) or one of the assignment
   worktrees recorded by that feature.

**Compare commits** opens the recorded baseline against the latest commit.
The baseline is the target branch's merge-base captured when workflow tracking
begins, so feature commits made before the first step remain visible even if
the target branch later advances. Each step separately records its starting
revision to attribute only the commits produced during that step.
Use **Before** and **After** to choose an ordered pair of revisions, or choose
**Uncommitted changes** on the right. **Working files** retains staging and
unstaging. A workflow commit opens its exact recorded workspace with the
baseline on the left and that commit on the right. Each completed step keeps
its captured ending commit visible and can expand to show its other commits;
commit dates never replace the recorded ending revision.

The Git page stays mounted during companion catalog refreshes and transient
terminal reconnects, so the open diff, selection, and scroll position do not
flash back to a loading screen. Use **Refresh Git workspaces** to update the
catalog explicitly; the workbench continues to poll Git status on its own.
Native feature refreshes also preserve the embedded document: its identity uses
the actual API configuration and route rather than serialized JSON key order.
This prevents repeated “Reading working tree…” screens after successful loads.
Real URL, credential, feature, or workspace changes still load the new target.
This correction applies to pane Git and pop-out Git views too, without a server
update.

The picker never guesses the newest worker, borrows the active Chat pane, uses a
terminal's current directory, or creates a shell. Concurrent workers are distinct
choices. Paths are visible for context but are not editable selectors. A worktree
that has since been removed stays listed and reports that it is unavailable; it
never falls back to the project checkout.

## Pop-out windows

Choose **Open Git in New Window** beside the workspace picker. The window is
identified by machine ID, feature ID, workspace ID, and an optional selected
commit SHA:

- reopening the same target focuses its existing window;
- another workspace opens a distinct window;
- another workflow commit opens a distinct window on that exact revision;
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

**Compare commits** supports **Ask AI** for the selected file or highlighted
lines on companions advertising `git-comparison-v1` and `git-question-v1`.
Questions stay scoped to the exact feature, recorded workspace, comparison,
and selection. The buddy can inspect authorized history and files on demand,
without requiring a terminal pane. Uncommitted source is captured for the
question. Cited files available in the displayed comparison can be opened with
**Show file**.

On an older companion, the legacy **Working files** viewer remains available.
Its selection Ask action is still hidden for First Mate because the older
question contract requires a terminal pane. Use the feature conversation for
direction when that companion lacks comparison questions.
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
- [ ] In Compare commits, ask about a file and selected lines in First Mate Git,
      then switch revisions and confirm the question context changes with them.
- [ ] Confirm the legacy Working files selection Ask stays absent for First Mate
      and remains present in pane Git.
- [ ] Open a workflow commit and confirm the exact workspace and captured SHA
      are selected. Expand its step to open another recorded commit.
- [ ] Pop out project and worker targets; confirm each window remains pinned as
      the main window changes machine, feature, and workspace.
- [ ] Stop only the terminal-pane connection while leaving the companion API
      reachable and confirm the open Git page, diff, and scroll position stay
      visible across reconnects and **Refresh Git workspaces**.
- [ ] Leave the same feature on Git for at least 30 seconds while native feature
      refreshes continue; confirm the initial “Reading working tree…” state does
      not return and the selected diff and scroll position remain. Repeat in a
      pop-out and pane Git. With navigation instrumentation, the document time
      origin should stay fixed even while Git status requests continue.
- [ ] Disconnect/reconnect the owning companion and confirm the same target reloads.
- [ ] Verify an older companion shows the compatibility message.
- [ ] Verify VoiceOver labels for Chat/Git, workspace, refresh, pop-out, stage,
      unstage, diff, and retry controls.
