# Herdr for iOS

The iPhone app connects directly to the standalone Herdr server. It includes
terminal and Pi chat views, machine management, notes, and Herd Pulse Live Activities.
No other orchestration server is required.

## Native mobile interface

The **Agents** tab lists all currently available Pi sessions across machines,
newest first, without the navigator’s twenty-chat limit. System-font cards show
the session title, agent name, machine, workspace, tab, and status. Search any
of these fields and tap a card to open its session. Offline machines indicate
that their agent status is last known. Workspace browsing and creation remain
in the navigator; a card’s context menu also opens its workspace. No server
update is needed.

The navigator defaults to **Recents**, a flat newest-20 conversation list. Choose
**All** for Unread, then Starred, then the real machine → workspace → tab → pane
hierarchy. Search, machine, range, and optional tab-color filters work together.
Six tab-owned colors and editable labels are stored only in this iOS app sandbox;
Mac assignments are not imported or synchronized. The navigator scrolls as a
whole so chats remain reachable with large text in landscape.

Pane views use charcoal chrome and system-scaled prose. Chat, Git, Terminal, and
Skills are available from **Pane actions → View**, without a separate segment
row taking conversation space. Compact Model and Thinking controls stay
independent and follow the connected Pi session's catalog and capabilities.

The unified input card keeps Attach, Voice, More, and Send close to the editor.
**More → Show terminal keys** reveals the optional key deck; it is hidden by
default. More also contains Paste code, workspace-file and Jira context, and
explicit voice dictation. Selected attachments appear inside the input card with
upload status, retry/removal controls, and small photo previews retained in
memory after upload. No full-size preview image is retained.

Unsent text drafts remain in memory per pane while the app runs;
they are not persisted or synced. The legacy Pi bridge may still trim surrounding
whitespace when a draft is submitted.

Use Xcode 26.2 or newer. Open `herdr-harness-ios.xcodeproj`, select the shared
`herdr-harness-ios` scheme, and run on an iPhone simulator. Add `-HerdrDemoMode` as a
launch argument to explore sample content without any server.

For device signing and the optional machine roster, use the single private cluster
TOML and [Apple configuration guide](../herdr-harness-mac/APPLE_CONFIGURATION.md).
The public project has an empty signing team and neutral development identifiers.
API tokens are entered at runtime and saved only in Keychain.

See the [repository README](../README.md) for server setup. Simulator may connect
to `http://localhost:9092`; physical devices require an HTTPS address reachable from
the phone. Tailscale Serve is one option for a private network.

Build the app, widget, and tests without signing:

```bash
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```
