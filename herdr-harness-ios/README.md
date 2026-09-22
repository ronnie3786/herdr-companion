# Herdr for iOS

The iPhone app connects directly to the standalone Herdr server. It includes
terminal and Pi chat views, machine management, notes, and Herd Pulse Live Activities.
No other orchestration server is required.

## First Mate

The **First Mate** tab brings the feature workspace to iPhone and iPad. Talk to one
First Mate per feature, then inspect its workflow, independent agents, documents,
and exact saved sessions. Features waiting for your direction appear first. iPhone uses
focused detail sheets; iPad keeps a feature sidebar and a trailing inspector.
Choose System, Light, or Dark from First Mate options.

The matching companion server with `first-mate-v1` is required. Work continues on
that host when the phone app closes. Launch with `-HerdrFirstMateDemo` to explore
synthetic planning, seven reviewers, checkpoints, and session handoffs. See
[mobile behavior and verification](../docs/first-mate/ios.md).

## Native mobile interface

The **Agents** tab groups all currently available Pi sessions by workspace
across machines, without the navigator’s twenty-chat limit. A prominent
workspace heading and small machine label introduce tab sections containing
compact agent cards with full wrapping titles and a single status/activity row.
Short activity ages update once a minute. Generic Pi labels appear once in the
list summary; specific agent names remain visible on their cards. Workspace and
machine labels share a row when they fit, and long names or large text expand
the layout. Header controls keep at least 44-point touch targets.
Workspaces and tabs sort by their newest matching
chat, and agents within each tab sort newest first. Workspaces with identical
names on different machines stay separate. Search filters before grouping, so
counts and ordering describe the matching chats. Tap any agent to open its
session. Offline machines indicate that agent status is last known. Workspace
browsing and creation remain in the navigator. Long-press any agent card for
**Rename**, **Smart Rename**, star/unstar, tab color, its workspace, and copying
its workspace pane ID. Mac focus/zoom and Interrupt are grouped under **Mac
controls**. Interrupt and both close options require confirmation; **End Pi &
close pane** preserves the tab and workspace. Remote controls respect each
machine's connection and busy state. Smart Rename appears for identified Pi
sessions and requires a readable conversation. It uses a separate read-only run with the
selected agent model and low thinking, and never prompts the live chat. A newer
manual rename or changed session takes precedence over an in-flight result.
Smart Rename is also available in the navigator and pane actions. These actions
use existing server endpoints; no server update is needed.

The navigator defaults to **Recents**, a flat newest-20 conversation list. Choose
**All** for Unread, then Starred, then the real machine → workspace → tab → pane
hierarchy. Search, machine, range, and optional tab-color filters work together.
Six tab-owned colors and editable labels are stored only in this iOS app sandbox;
Mac assignments are not imported or synchronized. The navigator scrolls as a
whole so chats remain reachable with large text in landscape.

Pane views use charcoal chrome and system-scaled prose. Chat, Git, Terminal, and
Skills are available from **Pane actions → View**, without a separate segment
row taking conversation space. Chat uses a one-line inline navigation title and
flat, full-width conversation rows: there is no turn rail, large agent/status
header, standalone star, or location breadcrumb. Star remains in Pane actions;
**Chat history → Last prompt** shows only the latest visible user prompt and is
disabled when there is none. Pushed panes use native Back and swipe. Root and
split-detail panes expose the app Chat navigator; split detail removes the
split view's automatic Agents-column control rather than duplicating it. Model and
Thinking are small plain-text pickers, grouped at the leading edge with an adjacent
down chevron on each interactive value and independent 44-point tap targets.
Listen and TL;DR are icon-only actions at the trailing edge; preparing, playing,
and paused playback use spinner, pause, and play indicators while retaining their
complete spoken actions. Common values share one compact row; long model names
truncate within their budget, and accessibility text stacks safely. The controls retain the connected Pi session's
catalog, capability, and playback behavior. No server update is required.

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
