# Next macOS update — unreleased

## Feedback

- Help → **Report a Bug or Request a Feature…** (⌘⌥F) and Settings → General → Feedback open a sheet that files a public GitHub issue with your verbatim description and up to six attachments. Included environment details are listed before sending and never contain machine names or hostnames.
- With several paired machines the sheet checks every connected companion at once, preselects the one that last filed a report from this Mac (otherwise the first available in machine order), and keeps unavailable machines selectable so their reason under the picker explains what to configure. **Check again** rechecks every connected companion without discarding the draft, whether an unavailable machine is selected or none can file; if the selected machine disappears from Settings, the sheet shows the replacement's machine and repository notice instead of silently filing through it. When none can file, the submit button is replaced by an explanation that names the machines checked, calls out disconnected machines that were not checked, and links to the Code Factory setup guide.
- **Start the automated fix pipeline** labels the issue for the optional Code Factory daemon. Requires a companion server advertising `issue-reports-v1`; older servers show an update message.

## Sidebar and navigation

- Recents uses compact single-line titles, quieter machine/workspace context, and visible Working, Done, and attention states. Full tab context stays available on hover.
- Leaving Recents restores the ordinary grouped-row styling. Selected chats keep their background highlight without a leading vertical stripe.
- Sidebar titles and status read live pane data so Smart Rename and agent completion stay aligned with the chat header and HUD.
- Back and Forward remember Chat/Git segment switches on the same pane, including returning to Git after visiting another pane or screen.
- New workspace is a labeled sidebar action. Hover a machine row for a folder-plus button that opens creation directly on that machine, without another machine selection. Workspace headings in Unread and Starred expose the same right-click menu as the workspace tree, including New tab.

## Chat and HUD

- Attachment chips remain compact and scroll horizontally instead of stretching the composer.
- Long prompt drafts scroll with the mouse or trackpad after reaching five visible lines. Existing Return and modified-Return behavior is retained.
- Grouped tool calls are labeled Clanking. Failures remain indicated in the collapsed header and no longer expand the group automatically.
- The HUD notes list starts as one Notes icon. Click to expand; click again to minimize. Creating or opening a note still opens its editable card.

## Companion compatibility

The Mac UI changes require no API contract change. A separate companion update raises the shared headless-agent timeout, including HUD chat, from ten minutes to one hour by default. A Mac-only update does not change the running server's timeout. Existing explicit overrides remain effective; `HERDR_HARNESS_AGENT_TIMEOUT_SECONDS` supports 1–86,400 seconds through the private configuration's `[environment]` table. Cancellation remains available.

## Quick verification

1. Toggle Recents on and off; Smart Rename a chat and compare its sidebar/header title. Let a working agent finish and compare the sidebar with its HUD notification.
2. Switch Chat → Git → another pane; use Back twice and Forward twice.
3. Attach multiple images, enter a draft longer than five lines, and scroll inside the editor. Confirm Return sends and modified Return inserts a newline.
4. Open a conversation with a failed tool call: Clanking should remain collapsed and show the failure count.
5. Toggle Notes twice, create a note, and close its card. Use New workspace and right-click workspace headings to find New tab.
6. Pair two synthetic machines, connect only the second, and open the report sheet: it should preselect the connected one, let you select the disconnected one to read its reason while submission stays disabled, and, after disconnecting both, replace File report with the checked-machine explanation and **Check again**. Do not file a real issue for this check.
