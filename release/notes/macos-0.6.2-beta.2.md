# Herdr for Mac 0.6.2-beta.2

This preview makes the Mac sidebar, navigation, composer, and HUD easier to use.

## Sidebar and navigation

- Recents uses compact single-line titles, quieter machine/workspace context, and visible Working, Done, and attention states. Full tab context remains available on hover.
- Leaving Recents restores ordinary grouped-row styling. Selected chats keep their background highlight without a leading stripe.
- Sidebar titles and status use live pane data, keeping Smart Rename and agent completion aligned with the chat header and HUD.
- Back and Forward remember Chat/Git segment switches on the same pane.
- New workspace is a labeled sidebar action. A folder-plus button on a machine row opens creation directly on that machine. Workspace headings in Unread and Starred expose the same workspace menu, including New tab.

## Chat and HUD

- Attachment chips remain compact and scroll horizontally instead of stretching the composer.
- Long prompt drafts scroll after five visible lines while retaining the existing Return and modified-Return behavior.
- Grouped tool calls are labeled Clanking. Failures remain visible in the collapsed header and no longer expand the group automatically.
- The HUD notes list starts as one Notes icon. Click to expand or minimize it; creating or opening a note still opens its editable card.
- HUD session bubbles show a cumulative session cost only after Pi reports one. Unavailable values no longer show a placeholder or retain a stale total, and the cost label is quieter while remaining accessible.

## Compatibility and verification

These Mac UI changes require no API contract change. Installing this Mac update does not update the companion server or iPhone app. A separate companion configuration controls the headless-agent timeout; existing explicit overrides remain effective.

Requires macOS 26 or later. To verify the changes, toggle Recents, exercise Back/Forward across Chat and Git, attach multiple images, enter a long draft, inspect a failed grouped tool call, and toggle Notes twice.
