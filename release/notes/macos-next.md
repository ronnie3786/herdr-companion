# Next macOS update — unreleased

## Feedback

- Help → **Report a Bug or Request a Feature…** (⌘⌥F) and Settings → General → Feedback open a sheet that files through this Mac's companion, or the first connected companion, as a public GitHub issue with your verbatim description and up to six attachments. Included environment details are listed before sending and never contain machine names or hostnames.
- **Start the automated fix pipeline** labels the issue for the optional Code Factory daemon. Requires a companion server advertising `issue-reports-v1`; older servers show an update message.

## Sidebar and navigation

- Recents uses compact single-line titles, quieter machine/workspace context, and visible Working, Done, and attention states. Full tab context stays available on hover.
- Leaving Recents restores the ordinary grouped-row styling. Selected chats keep their background highlight without a leading vertical stripe.
- Sidebar titles and status read live pane data so Smart Rename and agent completion stay aligned with the chat header and HUD.
- Back and Forward remember Chat/Git segment switches on the same pane, including returning to Git after visiting another pane or screen.
- New workspace is a labeled sidebar action. Hover a machine row for a folder-plus button that opens creation directly on that machine, without another machine selection. Workspace headings in Unread and Starred expose the same right-click menu as the workspace tree, including New tab.
- Workspace folders are easier to pick out of the sidebar: 14-point semibold titles in the brighter text color, 14-point mist folder icons, and taller folder rows while tabs, chats, machines, and group labels keep their compact styling. Long names still truncate at the tail with their counts, chevrons, tooltips, and accessibility information intact. This visibility change needs no server update and adds no new setting.
- The computer segment bar now uses optional `sidebar_label` and `sidebar_order` values from the private machine roster instead of built-in name aliases. Ordered computers appear first; ties and computers without an order keep saved roster order. Missing labels show the full name, duplicate labels remain separate connections, and selection still uses the original paired machine ID. Zero machines remain hidden and four or more still use the full-name menu. Runtime updates require an updated companion and Mac app: restart the companion after editing the first saved connection's authoritative TOML, then Refresh or reconnect. Failed or unsupported metadata requests retain the cached presentation offline; URLs, credentials, roles, and saved connection order are unchanged.

## Chat and HUD

- Attachment chips remain compact and scroll horizontally instead of stretching the composer.
- Long prompt drafts scroll with the mouse or trackpad after reaching five visible lines. Existing Return and modified-Return behavior is retained.
- Grouped tool calls are labeled Clanking. Failures remain indicated in the collapsed header and no longer expand the group automatically.
- The HUD notes list starts as one Notes icon. Click to expand; click again to minimize. Creating or opening a note still opens its editable card.

## Companion compatibility

The configurable computer segments add optional fields to the authenticated machine-roster response. Existing clients ignore them. The Mac matches metadata only to already-paired unique exact origins; it never imports machines or credentials. Both the companion and Mac app must be updated for runtime synchronization, and a Mac-only update does not install companion code.

A separate companion update raises the shared headless-agent timeout, including HUD chat, from ten minutes to one hour by default. A Mac-only update does not change the running server's timeout. Existing explicit overrides remain effective; `HERDR_HARNESS_AGENT_TIMEOUT_SECONDS` supports 1–86,400 seconds through the private configuration's `[environment]` table. Cancellation remains available.

## Quick verification

1. Toggle Recents on and off; Smart Rename a chat and compare its sidebar/header title. Let a working agent finish and compare the sidebar with its HUD notification.
2. Switch Chat → Git → another pane; use Back twice and Forward twice.
3. Attach multiple images, enter a draft longer than five lines, and scroll inside the editor. Confirm Return sends and modified Return inserts a newline.
4. Open a conversation with a failed tool call: Clanking should remain collapsed and show the failure count.
5. Toggle Notes twice, create a note, and close its card. Use New workspace and right-click workspace headings to find New tab.
6. Narrow the sidebar and enlarge the text size: workspace folder titles should stay visibly larger and brighter than the tabs and chats beneath them, with long names truncating at the tail and their counts and chevrons still visible. No server update or new setting is needed.
7. In a synthetic private roster, give arbitrary computer names optional labels such as Build and Lab, include tied and missing orders, restart the first saved companion, then Refresh the Mac app. Confirm explicit orders precede unordered machines, ties remain in saved order, unlabeled segments use full names, duplicate labels still select distinct machines, and the saved selection survives relaunch. Remove a field and Refresh to confirm it clears. A roster of four or more machines keeps the existing full-name menu.
