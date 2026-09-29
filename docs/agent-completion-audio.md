# Agent completion audio on Mac

This guide describes the Mac companion's completion cue: when it plays, what
stays silent, how notification authorization interacts with it, and the
installed listening checklist that still has to be performed. It covers
ordinary pane chats (new and existing), saved HUD chats, and the Agent window
on Mac.

iPhone, iPad, the web client, and First Mate's chat window keep their existing
behavior. No companion server capability, endpoint, package, or configuration
change is required; this is a Mac client fix, and the signed Mac update feed
installs only the app.

## One owner for the completion cue

The Mac app keeps one process-owned decision point,
`AgentCompletionFeedbackCoordinator`, on the app model rather than on any view.
It lives for the whole app process, so a completion observed while the main
window is closed still plays exactly once. Mounted chats no longer infer a
completion from a working → idle phase change, and a restored or re-created
chat cannot request its own sound.

Completion audio is the explicit companion sink only:
`HerdrMacFeedback.play(.completed)` requests the quiet system “Glass” cue.
Completed work never requests SwiftUI `.success` sensory feedback, and the
companion never sets a sound on a Notification Center notification.

Evidence reaches the one owner from three observation paths:

| Evidence | Completion meaning |
| --- | --- |
| Committed Pi lifecycle | An `agent_settled` event that the committed reducer applied while the published phase was working. Private recovery replay, history snapshots, and phase resets never report. |
| Successful fleet refresh | A pane that moves from working/blocked to done, or a brand-new `.done` alert for a pane the poll did not otherwise catch working. The first successful refresh after launch or a connection identity change is a silent baseline. |
| User-facing headless runs | A HUD-chat or Agent-window run that reaches `completed` or `promoted`, including a run that finished before its first running poll and one restored as active. Internal summary and naming runs never report. |

The owner scopes receipts by real identities rather than display labels or
ordering:

- a machine + pane + terminal identity for pane work, with the Pi session
  recorded per work episode (`HerdrPane.episodeKey` distinguishes two done
  results in the same pane);
- a machine + durable run ID for headless runs.

A committed Pi settlement and the fleet observation of the same run share one
receipt: whichever arrives first plays the one cue, and the delayed duplicate is
silent in either order. One completion normally produces two fleet observations
- the `working → done` transition and the server's done alert, published at
different times - and each receipt records which channels have been
acknowledged, so the later observation never claims a second completion and a
delayed alert cannot complete a newer turn. A committed Pi start carries the
committed event's server timestamp and journal cursor; a start covered by the
receipted completion is the replay of an episode whose stream was interrupted,
so it keeps the existing receipt instead of arming a duplicate settlement. The
journal cursor proves a replay when it is at or before the receipt; a strictly
earlier start instant also proves one when a fleet alert arrived ahead of its
pane snapshot and that snapshot's cursor lagged behind. This includes a
snapshot fetched before but committed after the fleet already receipted the
run. Snapshot/candidate cursor and generated-at provenance are carried through
that commit. Each played
completion also keeps an exact reconciliation obligation: a stalled fleet that
later delivers a batch of already-heard completions - an acknowledged pane
reports idle, so no status transition accompanies them - consumes one
obligation per completion instead of replaying one. A per-pane ordering
watermark additionally collapses arbitrarily many delayed duplicates that
arrive after a newer turn began.
A fresh completion alert carries its own server timestamp: when the debounced
pane snapshot still reports the previous done episode, the alert instant - not
the stale pane episode key or its Pi cursor - identifies the alert for ordering.
A pane cursor can advance past batched old alerts or lag behind a fresh alert;
it does not identify which run created that alert. A late replay of that run's
start and settlement therefore cannot look like a newer turn. This is evidence
ordering against server-recorded evidence, not a local elapsed-time window.
Repeated polling, replayed alerts, a later turn, and a different machine or run
stay independently correct. Unmatched reconciliation obligations remain until
consumed or until a real identity boundary, such as changed credentials, a
re-created pane, or a pane that left the fleet; recent evidence IDs and headless
run receipts are separately bounded.

## What plays and what stays silent

| Moment | Audio |
| --- | --- |
| Submitting a prompt, accepting it, agent/turn start, or the running HUD bubble appearing | None |
| Streaming assistant text, intermediate tools, or any non-final message | None |
| A confirmed final response (`agent_settled` while working) | One companion completion cue |
| A user-facing HUD-chat or Agent-window run that completes or is promoted | One companion completion cue per durable run ID |
| A working → done fleet transition, or a fresh completion alert | One companion completion cue, unless the committed settlement already played it |
| Attention: an agent is blocked or needs you | The existing distinct attention cue (unchanged) |
| Cancellation, failure, disconnect, compaction, or a phase reset | None |
| Opening saved history, a completed saved HUD chat, or an already-finished run | None |
| First observation after launch, a relaunch, or a connection identity change | None (silent baseline) |
| Replayed or repeated observation of the same episode, alert, or run receipt | None |

## Startup, history, and reconnect

Launching the app, reconnecting, or opening a conversation that already shows a
completed answer never replays a cue: the first successful refresh seeds a
silent baseline, and opening history is not a new completion. A run that is
restored as still active is armed and cues once when it genuinely finishes.

A transient network reconnect does not replay a completion that was already
heard. Work that was genuinely in flight before the disconnect remains eligible
for exactly one cue when the refreshed evidence proves it finished. A changed
connection identity (changed credentials, configuration, or paired roster)
starts a new baseline, because no receipt from the old connection describes the
new one.

## Notifications stay visual and silent

Completion and attention banners, badge counts, deep-link routing, and read
acknowledgement are unchanged. What changed is one field: notification content
is always built with `sound == nil`, while the title, body, interruption level
(time-sensitive for blocked, active otherwise), and machine/workspace/pane
routing metadata are exactly as before. Notification Center therefore remains a
visual channel, and the companion cue is the only completion audio.

Notification authorization is independent of the cue:

- **Authorization enabled** — completion and attention notifications appear as
  silent banners or in Notification Center; the companion cue still plays once
  when work finishes.
- **Authorization denied, not determined, or unavailable** — no banner or badge
  is delivered; the companion cue still plays when work finishes, because it is
  process-owned and is not gated on notification permission.

There is deliberately no “if notifications are unavailable, play a fallback
sound” branch, so neither authorization state can add a second completion
sound. The notification content is constructed as a pure value; automated
tests assert `sound == nil` for both done (active) and blocked (time-sensitive)
alerts, so the two authorization states cannot diverge in what the companion
posts. Enabling Smart Alerts still asks for the standard notification
authorization (alerts, badges, and sound access); that permission decides
whether the system delivers banners and badges, not whether the companion cue
plays. Toggling the real authorization in System Settings and re-listening
remains an installed check below.

## Installed listening matrix (pending)

These checks require an installed, signed build, working audio output, and a
real or synthetic agent run. **None of them were performed for this source
revision; every row is pending until it is actually run and its result is
recorded.** “One cue” means one audible companion completion cue with no second
chime, and “silent” means no completion cue at all; the existing attention cue
for a blocked or needs-you agent is a different sound and is expected to remain.

| # | Scenario | Expected audio | Status |
| --- | --- | --- | --- |
| 1 | New pane chat: submit a prompt, watch the agent bubble appear, then let the response finish | Silent until the final response; then one cue | Pending |
| 2 | Existing pane chat that already shows a completed answer: submit another prompt | No cue on submission, no replay of the old answer; one cue when the new response finishes | Pending |
| 3 | New saved HUD chat: submit and watch the running bubble appear, then finish | No cue while running; one cue on completion | Pending |
| 4 | Continued saved HUD chat, then two consecutive turns in a row | One cue per completed turn; no cue for the first turn’s replay or duplicate observations | Pending |
| 5 | Agent window run: submit, then finish | No cue at submit; one cue at completion, whether the run finishes before or after the first running poll | Pending |
| 6 | Foreground: app window frontmost through the run | Exactly one cue at completion | Pending |
| 7 | Background: another app frontmost while Herdr stays running | Exactly one cue at completion | Pending |
| 8 | Main window closed while the app keeps running (menu bar/Dock), run finishes | Exactly one cue; reopening the window does not replay it | Pending |
| 9 | Transient companion reconnect during and after a run | No replay of an already-heard completion; work that genuinely finishes after recovery cues once | Pending |
| 10 | Opening completed history: saved chat, completed HUD chat, or an already-finished run | Silent | Pending |
| 11 | Notification authorization enabled: finish a background run | One silent banner (if backgrounded) and exactly one companion cue | Pending |
| 12 | Notification authorization unavailable: finish a background run | No banner and exactly one companion cue; no fallback sound | Pending |
| 13 | Blocked / needs-you agent | Existing attention cue only; no completion cue for that event | Pending |
| 14 | Cancel a run, fail a run, or lose the connection mid-run | No completion cue | Pending |
| 15 | Independently installed upstream Herdr terminal with its notification sound on (see below) | Mute only that sender; the companion cue stays at one | Pending |

## Automated evidence versus heard audio

The automated Mac suites inject a recording closure instead of playing audio.
They prove which playback requests the app makes and how many; they cannot
prove that a sound was audible, that the chosen system cue is comfortable, or
that an independently installed upstream application is silent. Only the
installed listening matrix above provides that evidence.

Relevant suites:

- `AgentCompletionFeedbackTests` — coordinator receipts for silent startup,
  prompt start, per-episode settlement, fleet/alert evidence, two machines,
  connection reset, re-created panes, headless run IDs, and delayed duplicates.
- `AgentCompletionFeedbackIntegrationTests` — committed Pi settlement and
  cancellation/failure, private recovery replay, fleet-only completion,
  fast-completion alerts, and user-facing headless runs including restored and
  history observations.
- `HerdrHudChatsTests.hudCompletionRequestsOneCue` — saved HUD chat submission
  and a second consecutive turn.
- `NotificationManagerTests.alertContentIsSilent` — silent notification content
  with unchanged routing and interruption level.
- `HerdrHapticTests.mapsWorkflowFeedback` — completed work requests no SwiftUI
  success feedback.

Run the focused Mac unit target (extend with `-only-testing:` suite selectors as
needed; the final Verify gate owns the full matrix):

```sh
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' \
  -derivedDataPath /tmp/herdr-mac-derived \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  test -only-testing:herdr-harness-macTests
```

## Competing upstream Herdr notification sounds

Upstream Herdr is installed separately and is not configured by this
repository or by the signed Mac update feed. If a second chime returns, use
this sender-specific check instead of assuming the companion regressed:

1. When the extra chime plays, open Notification Center (click the date and
   time in the menu bar) and find the banner that arrived at that moment.
2. Note the exact sending application. **Herdr Companion** is this app. Any
   other Herdr-named sender is the independently installed upstream
   application, and its sound is not part of this app.
3. Open **System Settings → Notifications** (older macOS: **System
   Preferences → Notifications**), select that exact application, and turn off
   only its notification sound — for example **Play sound for notifications**
   — leaving its banners and this companion’s audio unchanged. Wording and
   placement vary by macOS version.
4. If no notification entry exists for that sender, the sound is generated by
   the application itself rather than by Notification Center. Use only a
   documented sound preference in that application’s own settings. Do not
   invent an undocumented `defaults write` key for it.
5. Record the application name, the setting you changed, and the listening
   result. This external setup and its evidence remain **pending** until
   actually performed.

This repository adds no upstream preference key, changes no private
configuration, and makes no assumption that muting one sender alone proves the
companion cue is fixed. The companion changes documented here stand on their
own: submission, startup, history, and replay are silent, and genuine
completion requests exactly one companion cue.

## Distribution and compatibility

The signed Mac update feed installs only the Mac app. It does not configure
upstream Herdr and does not install or restart companion server packages
anywhere. The companion cue uses existing Pi semantic, fleet, alert, and
headless-agent APIs; an older or unchanged companion server keeps working, and
no server capability is added or required. iOS, iPad, and the web client are
unchanged, and First Mate's chat window keeps its phase-specific behavior.

There is no new user-facing enable, disable, or volume setting in this change.
The cue stays the quiet system “Glass” sound behind the existing companion
feedback sink.

## Verification status

- Automated playback-request evidence: covered by the suites named above; no
  real sound is played in tests.
- Public-source scan: run `python3 scripts/check-public-source.py` (and
  `python3 -m unittest tests.test_public_source`) before publishing.
- Installed listening matrix: **pending** — not performed for this source
  revision.
- Independent upstream Herdr notification-sound setting: **pending** — not
  performed for this source revision.
