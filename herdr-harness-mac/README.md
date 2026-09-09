# Herdr Harness for Mac

A native macOS companion to the Herdr Harness iOS app — same Catppuccin Mocha aesthetic, same
attention-first workflow, near-complete feature parity, rebuilt around a Mac-native shell: a
persistent sidebar (workspaces → tabs → chats), a resizable chat/terminal detail view, real
keyboard input to terminals, menu-bar fleet pulse, and system keyboard shortcuts.

The shell is the deliberate difference. iOS's workspace *switcher* screen — status filter chips
(all / needs you / active), the inline top-2 attention strip, and the git-worktree sibling rails —
has no Mac counterpart: the always-visible sidebar and the Attention scope (⌘1) replace it, and
those three affordances are dropped rather than reproduced.

Swift 6 · SwiftUI + Observation · strict concurrency · zero third-party dependencies · macOS 26.

## September Mac improvements

- **Session bubbles:** Each bubble shows the chat name in bold, an emoji followed by italic activity, and a separate status with its own icon. Live activity comes from Pi's current work. A short AI topic summary is the fallback when there is no current activity; it never replaces the chat name.
- **HUD attachments:** Drop a Finder file or image into the open HUD, or use Attach. Send a file by itself or with a prompt. Sent attachments appear inline and are copied into app storage so their history and retries survive a moved source file or app restart.
- **Models:** Every shared model menu puts favorites first. Use the current model's star action or Manage Favorites. Short names are consistent while provider identities remain distinct.
- **Code-block paste:** Use the code-block paste button in either composer to insert clipboard text surrounded by literal backtick fences. Existing clipboard fences are enclosed safely.
- **Unread results:** Extra sessions in `+N` do not create an unread orb badge. Links and results remain attached to their session bubble. Reading that session clears its result indicators and preserves the inline chat cards.
- **Prompt history:** Click Prompt History in a pane's header to search, copy, or reuse earlier submissions. Reuse edits the draft; it does not send automatically. The local archive survives restarts and transcript compaction and is scoped to the machine and pane.
- **Notes:** Unopened notes stay compact. Click a note to edit it, scroll to older notes, or use New note in the compact stack, open card, header, or orb menu. File → New Note (Shift-Command-N) also works with the HUD hidden. The hover region follows visible content more closely.
- **Chat identity:** Click the title above a chat to edit it. Right-click its sidebar row, HUD session bubble, or header to copy the workspace pane ID.
- **Delayed iOS alerts:** The harness waits a minute before pushing an unread agent alert, cancels read or superseded alerts, and retries failed device deliveries without repeating successful ones. Requires configured APNs and the updated harness; configure `[push]` in the private TOML on each companion that owns sessions. Local Mac banners do not establish APNs delivery.
- **Recording permissions:** Settings identifies this running app, checks access, explicitly requests it, and verifies ScreenCaptureKit access. See [recording permission recovery](RECORDING_PERMISSIONS.md) for the ad-hoc signing diagnosis.
- **Portable configuration:** Apple identities and the optional machine roster are generated from your private cluster TOML. Public source uses neutral development defaults.

## What's in the app

External apps can now start a Pi chat with a custom prompt, context, and source link using `herdr://pi/new`. See [external Pi links](EXTERNAL_PI_LINKS.md) for the URL contract and Slack HUD examples.

Hovering visible HUD controls expands result icons into document-title pills. The same documents appear beneath the response that produced them in Chat. Saved transcripts retain older document cards; opening a missing document shows an alert with a browser fallback when a web login may be needed.

- **Sidebar navigator** — workspaces at the top level, panes grouped by tab beneath them, click a
  chat row to make it the main view. Collapse state persists across launches. Rows are styled in
  a single calm tone (no per-status hues) — active status words and unread counts carry the signal.
- **My Work watchlist** — the top of the sidebar tracks GitHub pull requests requesting your
  review and every non-Done Jira ticket assigned to you. Each provider has an independent count,
  error state, and collapsible list; data refreshes on launch, manually, and every five minutes.
- **Native Pi chat** — the rich chat timeline (streaming turns, collapsed thinking, tool cards,
  interaction/permission cards, markdown with tables and code blocks, context meter, model +
  thinking-level switching) with the terminal always one toggle away.
- **Live terminal** — the same bounded ANSI grid engine as iOS (full + delta frames over SSE,
  snapshot fallback), plus real Mac keyboard routing: click the terminal to focus it and type;
  arrows/tab/esc/ctrl-C go straight through. The compact key deck stays for parity.
- **Comfortable reading**: charcoal surfaces, lavender actions, readable secondary text,
  and a consistent style across the sidebar, settings, HUD, menu bar, Git, and Active Work.
  Conversations in Chat and the HUD use 15-point system text at the default scale, generous spacing, and a
  bounded reading width. The app's text-size preference continues to apply.
- **Prompt composer**: model, effort, and Terminal keys controls sit above a unified
  input. Labeled Attach, Paste code, and Voice actions are in its footer. More contains
  additional context tools. Active voice and playback states remain visible. Drafts
  remain shared between chat and terminal modes. Return sends; Shift, Option, or
  Command-Return inserts a newline.
- **`$` skills palette** — type `$` at a word boundary to raise a filtering HUD of the
  workspace's skills. Arrow keys move the highlight, Enter/Tab (or click) inserts the skill,
  Esc dismisses, and space dismisses while typing normally — so a stray `$` never gets in your
  way. Zero matches auto-dismisses; only a fresh `$` re-opens it.
- **Voice** — tap the mic for the long-form recorder sheet, press-and-hold to dictate
  (auto-locks after a beat). Recordings are mono 16 kHz WAV, transcribed by your private
  Parakeet endpoint with on-device Speech as fallback.
- **Attention deck** — blocked and done agents rise to the top; alerts sync read-state with the
  server; local notifications deep-link straight into the pane (`herdr://pane/{id}` works too).
- **Workspace overview** — fleet summary, pane topology radar built from Herdr's real split
  geometry, git status/diffs, skills, project file search, Jira tickets, attachments.
- **Herd Pulse in the menu bar** — the iOS Live Activity becomes a menu-bar extra whose top-level
  aggregate remains privacy-safe (counts only, never names), plus a clickable list of sessions
  needing attention. Session titles show by default and can be redacted in Settings for screen
  shares. Start it from the toolbar's pulse button or View ▸ Start Herd Pulse (⇧⌘P); the extra is
  only inserted while Pulse is on. The event stream and the pulse feed outlive the window, so
  closing it keeps alerts and the menu bar live.

## Requirements

- macOS 26.0+ and Xcode 26.2+ (the project uses Xcode folder-sync groups; new `.swift` files
  are picked up automatically — no pbxproj edits).
- A running standalone Herdr server on this Mac or reachable over HTTPS. See the
  [repository README](../README.md) for installation, terminal requirements, and configuration.

## Build & run

```bash
cd herdr-harness-mac
xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac \
  -destination 'platform=macOS' build
```

Or open `herdr-harness-mac.xcodeproj` in Xcode and hit Run. The only shared scheme is
`herdr-harness-mac`.

### Try it instantly (no server): demo mode

Add the launch argument `-HerdrDemoMode` (Xcode: Product → Scheme → Edit Scheme → Arguments) to
load the canned fleet — 3 workspaces, 6 panes, alerts, git, skills — with no backend at all.
`-HerdrResetSidebarState` (DEBUG) clears persisted sidebar collapse state.

### Connect to your real herd

1. Follow the [server setup](../README.md) to copy and customize the single private
   cluster TOML. Run the standalone server once on each configured machine.
2. Optionally generate local Apple identities and the machine roster before building:

   ```bash
   python3 herdr-harness-mac/Scripts/configure-apple.py --config /path/to/private/cluster.toml --machine desktop
   ```

   Run this command from the repository root. Generated `Local.xcconfig`,
   `Local.entitlements`, and `HerdrBootstrap.plist` are ignored and contain no tokens.
   Generated machine addresses and app identities become part of local app artifacts.
   Build public releases from a clean checkout without your private generated settings.
3. Launch the app. Use a configured machine or enter `http://localhost:9092` for this
   Mac, or an HTTPS address for another machine. Enter its bearer token in onboarding
   or Settings. Tokens are stored only in Keychain. A failed secure save is reported.

See [Apple configuration](APPLE_CONFIGURATION.md) for signing, universal links, and
private upgrade compatibility.

## Tests

```bash
cd herdr-harness-mac
xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac \
  -destination 'platform=macOS' test -only-testing:herdr-harness-macTests
```

The unit suite is the iOS suite ported (reducers, SSE parsers, markdown, sidebar tree, terminal
grid hardening, policies, timeouts, Herd Pulse privacy) plus mac-specific additions (terminal
keyboard mapping, menu-bar privacy, demo screen renders). UI tests (`herdr-harness-macUITests`)
drive demo mode through XCUITest; run them from Xcode — the runner needs macOS Automation
permission, so they can't run from a headless shell.

Troubleshooting: if `xcodebuild test` hangs for minutes with no output, a stale `testmanagerd`
daemon is usually stuck — `pkill -9 testmanagerd` and rerun.

## Diagnosing a freeze

Before force-quitting a beach-balled app, run `Scripts/capture-hang.sh` from another terminal. It
writes a sample, footprint, vmmap summary, heap summary, and system log to
`~/Library/Logs/Herdr/hang-<timestamp>/`. The live diagnostics can also be inspected directly:

```bash
/usr/bin/log show --last 15m --predicate 'subsystem == "org.herdr.companion.macos" AND category == "perf"' --style compact
```

## Relationship to the iOS app

The two apps are partners: models, state, networking, the Pi chat pipeline, the terminal engine,
and the design system are ported **verbatim** from `herdr-harness-ios/` (same types, same file
names); only the shell differs (NavigationSplitView window + menu bar instead of stack/split
navigation + Live Activity). When the iOS app gains a feature in a shared layer, the same file
usually drops into this project unchanged.

## Quick voice side quests

The microphone attaches to the bottom-right of the HUD orb and moves across Spaces with it.
Click it to record, then click **Stop and send** to submit automatically. The main chat HUD
stays closed. The request card shows **Listening**, transcription progress, then **Heard you**
with the full transcript. Named agent notifications appear beneath it during dispatch and show
**Starting**, **Running**, **Finished**, or **Needs your attention**. A four-agent request can
show all four notifications without expanding the list.

Escape or **Cancel recording** discards an unfinished recording. Closing the card after sending
leaves the agents running. The clock menu opens recent requests; right-click an agent notification
and choose **Show voice request** to return to its receipt. View > Record Voice Request
(Control-Command-V while Herdr is active), Voice Requests and Reports, and Hide/Show HUD Microphone
provide menu access. Hiding the HUD hides its microphone too.

Choose the target Mac in the card. New notes inherit the selected chat's working folder on that
Mac, or its home folder otherwise. Parakeet transcribes through the authenticated harness.
The model configured for quick voice chooses one to four independent assignments and
meaningful titles. Pi chats are grouped under **Quick Voice** and use the model and thinking
level configured on that server. They run without focusing their terminals. Herdr confirms those settings before sending each assignment. These launch
overrides leave Pi's default model for other chats unchanged. Independent service checks
get separate agents even without a working folder. Coupled work stays in one assignment.
Up to four voice notes can run at once.

All HUD agent notifications share the same three-line layout: the chat name in bold,
an emoji followed by italic activity, then a status icon and a plain-English status such as
**Running**, **Finished**, or **Needs your attention**. The emoji stays inside the bubble beside
the activity. Long session lists scroll within the available screen height.

Kokoro acknowledges receipt while planning and dispatch proceed. When all chats settle, Qwen
writes a short report based on their results, which Kokoro reads aloud. Click an agent notification
to open its chat. The request card keeps the final report, audio replay, and an **Agent chats**
disclosure for revisiting finished work. Its speaker button mutes automatic playback.
Recording pauses this feature's playback. Text survives audio failures. Failed transcription
keeps the recording for retry, and an unconfirmed submission retries with the same identity.
The **Clear this request** action clears only the local retry record and leaves any agents running.

Jobs and audio live privately under `quick-voice` in the configured server state directory on the target Mac.
Restarting the harness resumes monitoring already-dispatched work; ambiguous dispatches are
flagged for inspection instead of being repeated. A chat that needs input, fails, or has no
confirmed result after 45 minutes is reported as needing attention. The timeout does not stop
its Pi session. Audio plays while Herdr is running, including with its main window closed.
