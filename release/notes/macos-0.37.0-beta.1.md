# Herdr Companion 0.37.0 Preview 1

## PR Review polish

- One shared diff renderer for PR Review, Chat Git and First Mate Git: syntax colors, roomier code lines, clear red/green changes and changed-word emphasis.
- Ask Herdr questions remain as **Saved questions** bubbles below the diff. Reopen them after switching files, closing a review window or relaunching. Each thread retains its original file/revision; older questions are labeled after a refresh.
- A short **Why** explanation is visible beside each file's Impact rating, in either file order.
- Empty file filters no longer vertically center the left-hand controls.
- Refresh errors keep the last usable review visible instead of replacing it with a dead end.

## Companion 0.37.0b1 — separate update

Install the separately published companion package on the PR review host for:

- The Ask Herdr system instruction: “Always give me the ‘short version’ unless I ask for the long version or for more details.”
- Safe refresh of new/rebased commits, coalesced duplicate refreshes, consistent revision/file snapshots, preserved tracked checkout edits, and nonfatal GitHub viewed-file sync failures.
- Fresh impact rankings after revision changes, without late ranking jobs overwriting newer results.

The Mac updater updates only the app. No server, CLI, Pi session or iPhone installation is changed by this release. Existing `pr-review-v1` servers remain compatible with the Mac-side UI changes. Browser/hosted Git pages need the matching companion web assets for the updated shared styling.

## Quick test

1. Open a PR, select code, ask a question, dismiss the answer, then reopen its saved bubble. Switch files or relaunch and reopen it again.
2. Check the visible Impact explanation; try a filter with no matches.
3. Compare code colors/line spacing in PR Review, a chat's Git segment and First Mate Git.
4. With companion 0.37.0b1 installed, refresh after a new commit. Confirm the review stays usable and older question bubbles identify their earlier revision. Ask for more detail to override the short-answer default.

Saved question history is private to this Mac and starts with questions created in this version; older questions are not retroactively indexed.

This preview uses Apple Development signing and signed Sparkle updates. It is not notarized.
