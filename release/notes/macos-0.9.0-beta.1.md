# Herdr Companion 0.9.0-beta.1

## Mac improvements

- Chat no longer shows “Other session attachments” when the originating response
  is absent. Attachments associated with visible responses are unchanged.
- Notes group **Ask about this note**, **Tidy with AI**, and **Take action** under
  a labeled **Actions** menu.
- Right-click a sidebar chat and choose **Mark Unread** to leave a persistent local
  green-check reminder. Opening/interacting with the chat or choosing **Mark Read**
  clears it. This does not change live agent status or restore a HUD notification.
- **Quote & comment…** works on the last three completed, text-bearing agent
  messages, including code. Tool calls, empty messages, and user prompts do not
  consume slots; user messages and closed-session chapters remain copy-only.

## Saved HUD chats — companion update required

The HUD clock button opens searchable **Chat history** for the selected machine.
**New chat** saves the conversation instead of deleting its server session. Saved
HUD chats stay outside terminal workspaces and have no automatic expiry. Use
**Continue in agent** to promote the full Pi session when it is worth continuing
in a terminal; history remains available afterward.

HUD action chats now use normal Pi tools, configured extensions, skills, and project
context under the server’s OS account. They are not Herdr-sandboxed or read-only.
Pi’s existing project trust decisions remain in effect; headless runs cannot show
interactive terminal prompts. Contextual note/code questions retain their separate
restricted, supplied-context-only profile.

Install the companion server and matching CLI/Pi package from this release’s source
revision for saved HUD chats. The Mac app displays an upgrade requirement rather
than submitting an expiring chat to an older server. The other Mac improvements do
not need a server update. Updating the Mac app does **not** deploy or restart servers.

The server upgrade preserves still-present legacy HUD action threads before expiry
pruning, but cannot recover sessions already deleted or reaped. Agents can discover
saved chats with `herdr-hud-chats list`, `search <text>`, and `show <agr_ID>`; use
`--offset` to follow paginated results. Keep private backups of server state.
See the repository’s `docs/hud-chat-history.md` for lifecycle and API details.

## Installation

This is an experimental preview (build 23), Apple Development signed and not
notarized. Existing configured installations can enable **Include preview builds**
and use **Herdr Companion → Check for Updates…**. Normal macOS approval may be
required on first installation. Signed feed/archive verification remains enabled;
app, Keychain, and update-feed identities are unchanged.
