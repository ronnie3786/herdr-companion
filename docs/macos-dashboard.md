# Mac Dashboard and Agent view

The Mac app opens on Dashboard. It uses the existing purple Herdr theme and has
three sections: active First Mates across connected machines, PR Reviews, and
recent chats. The screens follow calm-UI rules: status colors match the agent
session HUD (red blocked, green waiting for you, yellow working), other states
are a glyph plus a word, previews are plain text, loading states are static
placeholders, and nothing animates or ticks faster than once a minute.

## Dashboard

First Mate cards are ordered by requests for direction, blocked work, working
features, then paused or ready work, and within each group by the latest
conversation or journal activity (not Pi telemetry). Completed, cancelled, and
archived features are excluded. Cards size to the window: three wide cards with
the next one peeking in, two on narrow windows, four on very wide ones. Each card
shows its status, machine and ticket, title, current stage ("Now"), the latest
reply as plain text, and either what it needs from you or how many agents are
running.

A First Mate that finished its turn and is parked until you reply shows **Your
turn** and counts as needing you on these screens (companion 0.45 or newer). The
sidebar's First Mate badge still counts only features that are awaiting
direction or blocked.

Status pills use the same semantic colors as the agent session HUD, and so do
the First Mate badges on Overview, saved sessions, the fleet sidebar, Agents,
Workflow, and Chat: **Blocked** is red, **Needs you** and **Your turn** are
green like an unread HUD result, and **Working** is yellow. An explicit blocked
status stays red even if a contradictory payload also sets the parked-turn flag,
and every other status keeps its previous quiet or done treatment. This is
presentation only: attention counting, the orange sidebar attention badge,
non-status banners, filtering, and execution behavior are unchanged, and no
server update is needed because the statuses already arrive in the existing
`first-mate-v1` responses. The dark appearance uses the HUD tokens themselves;
the First Mate light appearance deepens the same hues so badge captions and
icons stay readable.

PR Reviews and Recent chats sit side by side when there are reviews to show.
Otherwise PR Reviews collapses to one line. If no review host is chosen, the
line offers a menu to choose one; the choice is the same saved setting as
**Settings → Machines**. Recent chats are the sidebar's recents without PR
Review worker sessions (they have their own section) and plain shells, eight at
a time with **Show more**. The machine filter is independent of the sidebar and
persists on this Mac.

**Focus mode** (Dashboard only) shows just the work waiting on you: First Mates
that need direction, are blocked, or are waiting for your turn; reviews with
pending drafts or re-review requests; and chats that need input. Focus filters
before the recent-chat limit. It persists on this Mac and never changes work
execution. Press ⌘F to search all three sections; Esc clears the search.

Card and row clicks open the existing First Mate, PR Review, and chat screens;
section headings open those screens directly.

## Builds

Herdr can read a Mobile App Hub: a private, tailnet-only web app where agents
publish installable iOS builds. Set its address and the apps to feature in
**Settings → General → Builds** (bundle IDs, separated by commas). Both are
saved on this Mac only; with no address, nothing about builds appears.

- **Dashboard:** below the First Mates, the newest builds of the listed apps,
  with ticket, feature, version, building machine, and age. Search and Focus
  mode apply (Focus keeps builds from the last day). Clicking a build opens its
  hub page; the heading opens the app's page in the hub.
- **First Mate Overview:** under Pull requests, the builds that First Mate's
  agents published, with the assignment that made each one. The hub's publish
  command tags a build with its First Mate automatically when it runs inside a
  First Mate session, so this needs no companion change.

Herdr only reads the hub (`GET /api/v1/builds` with `bundle_id` or
`first_mate_feature` filters), refreshes once a minute while visible, and keeps
the last good list when the hub is unreachable. Full history, installs, and
cleanup live in the hub's own web app.

## Agent view

Agent view (**Agent view** on the Dashboard, **Navigate → Agent View**, or
⇧⌘A) shows one column per active First Mate with Chat, Overview, Agents, and
Workflow tabs. Columns fill the window when they fit and otherwise show whole
columns with the next one peeking in. The **All / Needs you / Working** filter
replaces Focus mode here. Column order stays still while you are on the screen;
new features join at the end, and the order is refreshed on your next visit.

Each column shows its status, machine, ticket, title, and current stage. A
feature that needs you gets one amber banner with its question and **Reply**,
which switches to Chat and focuses the composer. Chat shows the recent
conversation with compact type and milestone notes from the journal (stage and
assignment changes, recovery, blocking). Pi telemetry is never shown. Long
replies fold behind **Show more**; older messages are one click away in the full
view. Overview shows the goal, the three most relevant agents (running first),
and the latest journal notes. Agents lists every agent in one line each, with
role and verdict in the tooltip, plus the saved First Mate sessions. Workflow
shows the stages of the current plan.

Each column keeps its tab and unfinished reply when filtered out, when you visit
another screen, or when its feature leaves the list, until the reply is sent or
cleared. Replies go to the column's owning host and feature and can be typed
before the conversation finishes loading; failed requests keep their draft and
retry identity. A changed host identity clears the column rather than sending to
a different companion.

## Data and performance

Only visible columns poll, and only while the app is active. With companion
0.45 or newer, a column asks for a bounded board (recent messages, recent journal
notes, stages, agents, and their latest sessions) every four seconds and sends
the version it already has; an unchanged board costs one small response and
changes nothing on screen. Everything a column displays is prepared off the main
thread. Older companions fall back to a journal-only or full snapshot every 15
seconds, converted off the main thread. Failures back off to 30 seconds and keep
the last content on screen with a "Last seen" note.

The Dashboard reads the fleet list every 10 seconds and re-renders only when a
host's features or status actually change. PR Reviews read the companion's
cached review states every 30 seconds; the Dashboard asks GitHub for fresh states
when it opens (at most once a minute) and when you choose Refresh. The full First
Mate view requests journal-only snapshots from companions that support them.

[Dashboard API](dashboard-api.md) describes the additive companion fields, the
board endpoint, and the cached GitHub review-state worker. A separately
installed companion update is required for the board, activity ordering, and
**Your turn**; building or releasing the Mac app does not deploy it.

## Navigation

The toolbar's grid button, the sidebar entry, and **Navigate → Dashboard**
(⇧⌘D) go home. Returning home from a screen opened on the Dashboard steps back
instead of stacking history, so Back and Forward stay useful. Dashboard and
Agent view open without the sidebar and other screens open with it; if you show
or hide it yourself, each of those two contexts remembers your choice. Existing
deep links still open their requested destinations.

## Verification

Use the README's native build/test command, selecting DashboardTests,
AgentBoardStateTests, DashboardRenderTests, FirstMateFleetIndexTests,
FirstMateStatusColorTests, FirstMateStatusColorRenderTests, and the navigation
history suites for focused coverage. Render fixtures are entirely synthetic and
include thousands of Pi telemetry events, markdown, and escaped text to prove
none of it reaches the screen. The status-color suites compare mapped dark
colors with the HUD tokens, check the light appearance's hue and composited
contrast, and assert the rendered foreground pixels of production badges and
pills beside synthetic HUD session bubbles. HerdrDashboardUITests covers home
navigation, Focus mode, and the Agent view filter in demo mode.
