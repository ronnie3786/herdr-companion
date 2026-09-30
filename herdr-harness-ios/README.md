# Herdr for iOS

The iPhone app connects directly to the standalone Herdr server. It includes
terminal and Pi chat views, machine management, notes, and Herd Pulse Live Activities.
No other orchestration server is required.

## First Mate

**First Mate for iPhone, Phase 0:** the dark-only Mono theme, cached dusk/haze,
static glass recipes, Dynamic Type ramp, and avatar primitives are available.
New First Mate chrome uses a quiet 6% selected/pressed row fill, 10 pt row corners,
and a `.xxxLarge` text-scaling cap. Bubbles retain 18 pt corners; messages stay
complete and scrollable, and controls retain 44 pt targets. The cap moves app-wide
in Phase 6. Settings → Appearance saves Glass and Haze independently for this
phone; passive Reduce Motion/Transparency fallbacks remain, without separate
release gates. Existing tabs keep their layouts and opaque backgrounds,
with a deeper neutral palette. Phase 2 now installs the dark conversations list,
client-built lead briefing and restyled create/archive sheets; the legacy First
Mate appearance menu is removed. Phase 3 replaces the old detail/chat helpers with
a grouped bubble transcript, text composer v1, pushed Info and briefing readouts. Debug builds
can open the synthetic theme sample with
`-HerdrDemoMode -HerdrFirstMateDemo -HerdrThemeDuskSample`. Render outputs go to
`$HERDR_IOS_RENDER_DIR`. See the [phase plan](../docs/first-mate/ios-chat/IMPLEMENTATION-PLAN.md)
and [verification guide](../docs/first-mate/ios.md). Phase 1 now adds the shared
fleet/chat rules, app-active polling, global feature-dot tab badge, exact-owner
links, fenced read/lead state and concrete authenticated client gaps. Phase 2 adds
the compact bar, lead + six needs-you pins with overflow, two-line recency rows,
and shared reply-progress projection for rows and the global badge. Phase 3 adds
bottom-following chat, exact-owner mentions/resources, frozen optimistic sends,
explicit retry, topmost-only phone read hooks and native swipe-back. Phase 4 adds
real My First Mate chat, owned machine selection/stand-in/recovery, frozen lead
context, assistant-aware reads and Overview-only Info. Phase 5 adds owned
attachments, voice, model/context controls, mentions and response feedback.
Phase 6 Info/iPad/app-wide polish remains planned, with automated verification and one final signed
iOS build after Phase 6
rather than intermediate phone-test pauses. No first-push approval gate remains.
No server update, Mac release or Phase 7 work is included. Lead metadata never
replaces saved connection identity; unknown/ambiguous link origins do not fall
back to another machine. First Mate POSTs retain the 86,400-second mutation
budget, with 90-second uploads, 120-second voice and 15-second reads.


The **First Mates** tab opens on **All Machines**, with needs-you features in a
pinned avatar strip and a flat activity-sorted conversation list. Visible names
honor shared user presentation metadata. Working replies use the shared progress
projection immediately, without changing native feature status or creating a
store per row; the global badge stays independent of scope/search. The host
menu also lists every machine individually, and choosing one filters the list to
it. An explicit choice is remembered until you change it, and a host removed from
the roster falls back to All Machines rather than another machine. Search matches
title, user label, preview, goal, ticket or machine name, and **Show archived** applies across the
hosts in scope.

Talk to one First Mate per feature, then inspect its workflow, independent agents,
documents, and exact saved sessions. Creating a feature from All Machines
requires choosing its destination host; a single-machine scope preselects that
host. Recent folders belong to the chosen destination, and changing the
destination clears the previous folder. Every message, archive action, and saved
resource resolves the machine that owns the feature, even when two hosts share a
feature ID. One offline or older companion shows its own notice without hiding a
healthy host's features. iPhone pushes Info from chat; documents and sessions still
open as sheets from Info. iPad keeps a feature sidebar and pushed detail navigation;
the three-column inspector is Phase 6. First Mates is dark-only, with capped `.xxxLarge`
scaling and full readable messages. My First Mate opens the real lead on a capable
host, with Automatic/pinned selection and a named stand-in after two failed LIST
polls. Recovery returns to the preferred host; drafts, history and pending sends
stay with their original owners. Lead Info shows your features at a glance, not
feature-only workflow/action controls. When no host advertises lead capability,
an explicitly client-built briefing retains capsule readouts and a creation goal
without discarding its draft on cancel/failure. A capable lead failure shows a
retry/read-only state rather than pretending it is an older host. The composer
uses a 1–7-line text pill and explicit send. Plus offers Photos, Files, Paste code
and documents; hold the mic to dictate, or type @ for owned feature/crew mentions.
Expandable model/context controls preserve host capability and confirmation gates.
Long-press a response to rate it. Draft attachments, picks and voice provenance
stay with the original host and feature, including after a failed send. Swipe/context
archive actions capture the exact owner and roll back optimistic removal on error.

The matching companion server with `first-mate-v1` is required. Work continues on
that host when the phone app closes. The scope preference is versioned; a missing
or legacy-only value opens on All Machines without changing the older machine
preference. Launch with `-HerdrFirstMateDemo` to explore two synthetic hosts,
shared planning, seven reviewers, checkpoints, session handoffs and both owned
lead histories. Debug-only `-HerdrFirstMateLeadScenarios` adds synthetic failed
LIST/recovery controls to the lead menu; `-HerdrFirstMateOlderHosts` exercises the
briefing fallback. Neither launches agents or uses a companion. See
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

## Pi compaction completion

In an ordinary Pi pane chat, the composer status area keeps its existing
**compacting** spinner while Pi summarizes context and no prompt controls are
accepted. Once Pi confirms success, the spinner is replaced by a checkmark and
**Context compacted** with a readiness line: **Ready for your next message.**
when the session is connected and idle, the available **Steer** or **Follow-up**
modes while Pi is still working, and an offline/reconnect message otherwise.
The cue is text-labeled, wraps at large Dynamic Type sizes, uses the normal
44-point row height, and carries a combined VoiceOver label; color is never the
only signal.

Manual, automatic-threshold, and overflow compactions all show the cue, even
when no assistant reply follows. It stays while you type and after a failed
send, and the next accepted message dismisses only the composer cue; the
transcript's **Context compacted** notice remains. Starting another compaction,
changing sessions, or switching branches removes it. Cancellation, failure,
settlement, disconnection, or a timeout never shows it. Opening an
already-compacted chat reconstructs the historical fact from its saved
compaction entries. No server update is needed: the existing `session_compact`
event and compaction entries are sufficient, and missing evidence is never
guessed from token counts, elapsed time, or a disappearing spinner. The Mac
update feed installs only the Mac app; the iOS build ships separately. See
[cross-client behavior and verification](../docs/compaction-indicators.md).

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
