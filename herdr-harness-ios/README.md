# Herdr for iOS

The iPhone app connects directly to the standalone Herdr server. It includes
terminal and Pi chat views, machine management, notes, and Herd Pulse Live Activities.
No other orchestration server is required.

## Native mobile interface

The navigator defaults to **Recents**, a flat newest-20 conversation list. Choose
**All** for Unread, then Starred, then the real machine → workspace → tab → pane
hierarchy. Search, machine, range, and optional tab-color filters work together.
Six tab-owned colors and editable labels are stored only in this iOS app sandbox;
Mac assignments are not imported or synchronized.

Pane views use charcoal chrome and system-scaled prose. Chat, Git, and Terminal
have a separate mode row, while Skills remains available from Pane actions. Model
and Thinking stay independent and follow the connected Pi session's catalog and
capabilities. Unsent text drafts remain in memory per pane while the app runs;
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
