# Herdr Companion 0.11.0 Preview 1

## Close chats without losing the project

- **Pane actions → End Pi & close pane** now preserves the tab and workspace. For the tab's last pane, the updated server creates and verifies a fresh shell in the same folder before ending Pi and closing the old pane.
- Companion shows **No open chats** with **New Pi chat** and **Open shell**. Both reuse the reserved terminal without carrying over the old chat's title or transcript. Saved conversations are not deleted.
- Failed or uncertain operations do not fall back to destructive close. Ordinary **Close pane**, workspace cleanup, and upstream Herdr's own close commands retain their existing behavior.

## HUD and response navigation

- Finished HUD session bubbles show their workspace name in the activity line. Running agents still show live activity, and hidden-title mode also hides workspace names.
- Agent replies in Chat, saved HUD chats, and the Agent window link valid pane references such as `w3:p9`, machine-scoped IDs, and supported Herdr deep links. Click to open the target inside Companion; HUD links open the main window.
- References are checked against the latest connected fleet snapshot and rechecked when clicked. Bare IDs stay on the response's machine, missing or ambiguous references stay plain, and an old link cannot silently target a replaced terminal. Copying and quoting retain the original text.
- Sidebar tab-color shortcuts use slightly smaller 14-point labels and tappable/background rows that are 10% shorter, with inline rename following the same text size.

## Compatibility and installation

The HUD labels, response links, and color sizing are Mac-only presentation changes and require no server update. Pane-preserving retirement requires installing the Companion server from this source revision; an older server gets an upgrade message, not a destructive fallback. No upstream Herdr or Pi-extension upgrade is required for these changes.

The corresponding iPhone pane-preservation changes are in source and require a separate iOS build/install. This signed GitHub Mac update does not install the iOS app or deploy/restart Companion servers. Follow the repository's independent component update instructions, preserving the existing private configuration and state. The new reservation store is `pane-lifecycle.sqlite3` under the configured server state directory.

This is a signed experimental development preview, not a notarized Developer ID release. Existing users can enable **Include preview builds** in **Settings → App updates**, then choose **Check for Updates…**.

## Try it

1. Let an agent finish; its HUD bubble should show the workspace under the chat title.
2. Read an agent response containing a real pane ID or Herdr pane link, then click it. A made-up ID should remain plain text.
3. Click or rename a sidebar tab-color shortcut; its row should be more compact.
4. After updating the server, use **End Pi & close pane** on a disposable workspace's final chat. Confirm the tab and color remain, then start a fresh Pi chat from the folder landing page.
