# First Mate Git no longer flashes on reconnect

- Keep the open First Mate Git workbench, selected diff, and scroll position in place while the terminal connection changes or the Git workspace catalog refreshes. A different feature or workspace still switches to its exact target; missing worktrees and API failures remain explicit.

## Try it

Open **First Mate** on Mac, choose a feature, then switch **Chat / Git** to **Git**. Keep a diff open across a companion catalog refresh or a transient terminal disconnect. **Refresh Git workspaces** updates the list without replacing an otherwise usable page.

## Compatibility and installation

The Mac app requires a companion server already advertising `first-mate-git-v1` for First Mate Git. This patch changes only the Mac app; no companion server or iPhone update is included. Use **Herdr Companion → Check for Updates…** with preview builds enabled to install the signed Mac update. The app updater does not deploy server packages.
