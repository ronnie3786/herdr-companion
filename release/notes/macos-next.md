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
- The computer segment bar uses compact labels—All plus short names such as Work, Dev, and Studio—while each segment selects the same original machine and the saved selection survives relaunch. Full configured names stay in the segment tooltips, and each segment announces its visible short label. This is sidebar presentation only: machine records, roles, URLs, credentials, the larger-fleet menu, and the zero-machine hidden state are unchanged. No server update or configuration migration is needed.

## Chat and HUD

- Smart Rename can now name a pane or HUD chat from a successfully submitted prompt before the agent replies, and name shell or nonsemantic panes from bounded terminal output and pane metadata. Settings → Agents → Smart Rename chooses the naming model and thinking level; an empty model still follows the Agent model and thinking still defaults to Low, so existing behavior is unchanged. Every rename resolves and runs on the machine that owns the target; an unavailable saved model falls back to that machine's Pi default with a visible notice and does not rewrite the preference, and a non-reasoning model receives Off without changing the saved effort. Responses and tool activity arriving during naming no longer cancel it, while manual edits, replaced terminals or sessions, removed chats, and changed targets still win. HUD titles created before the first run is accepted are retained across relaunch and reopening from history. Model catalogs are not proof of provider credentials or service health. This reuses existing Pi snapshot, terminal-output, agent-model, and headless-agent APIs; no new server capability is required, and every provider used must work in the environment of the companion that runs the rename. See docs/smart-rename.md.
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
6. Narrow the sidebar and enlarge the text size: workspace folder titles should stay visibly larger and brighter than the tabs and chats beneath them, with long names truncating at the tail and their counts and chevrons still visible. No server update or new setting is needed.
7. With a synthetic two- or three-machine roster, confirm the computer segments read All, Work, Dev, and Studio. Selecting each one scopes chats to that machine, and each segment's tooltip shows its full configured machine name. Select a machine, relaunch, and confirm it is still selected; then restore All. A roster of four or more machines keeps the existing menu picker.
8. Smart Rename a fresh HUD chat immediately after submitting its prompt, before any reply appears. Confirm the title appears, a reply arriving during naming does not cancel it, and Settings → Agents → Smart Rename keeps its model and thinking choices. On two disposable companions with different model catalogs, confirm each rename runs where its target lives and a saved model missing from that catalog falls back with a visible notice without rewriting the preference. See docs/smart-rename.md for the full synthetic matrix.
