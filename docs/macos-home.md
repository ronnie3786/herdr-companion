# Home and the four-tab Mac shell

Herdr opens on **Home**, followed by **PR Review**, **Watchers**, and **Chats**. Home presents
confirmed work, one focus item at a time, waiting chats, and recent activity. PR Review,
Watchers, and Chats retain their existing content and controls beneath the shared tab strip.
Home has no sidebar. Fleet and First Mate management remain utilities associated with Chats.

## Find your work and tools

Use the **Chat tools** overflow beside Chats for Fleet, First Mate management, Work inbox,
Ask Agent, Settings, New Note, HUD, and Herd Pulse. First Mate projects, sessions, inspectors,
Git/worktrees, documents, feature-associated Mobile App Hub builds, and simulator checkpoints
remain available. The Dashboard-only build shelf and its configuration are retired.
**Window → First Mate** is always available, without a preview preference.

| Shortcut | Action |
| --- | --- |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 | Home / PR Review / Watchers / Chats |
| ⌘F | Search the active surface; Home search filters its visible evidence |
| ⌘J | Open Home's lead First Mate tray |
| ⇧⌘J | Jump to an exact pane reference |
| ⌥⌘1 / ⌥⌘2 | Focus Chat / Focus Terminal |
| ⇧⌘F | Open the standalone First Mate window |
| ⌘7 | Open Fleet |
| Escape | Close Home search first, then the tray |

The First Mate window closes with ⌘W. Existing Back/Forward, Open Chat, local tool shortcuts,
and pane deep links remain available. Saved retired destinations map to Home, and agent
control accepts both `home` and the compatible `activity` alias for Home.

## What Home reports

Home projects existing lightweight stores into factual text and typed entity chips. It does
not request a generated fleet briefing on each visit. Machine outages come first, then blocked
First Mates, decisions, failed review preparation, ready reviews, and incoming review requests.
Stable machine-scoped identities break ties. The stack always shows that order, including for
work that loads later, and the front card follows it until you choose one. Closed, archived,
and lead conversations do not inflate the ordinary feature count; unknown review attention
stays unknown.

Prepared reviews cover the configured fleet independently of the selected detail host.
Incoming GitHub requests come from the configured primary companion only. Each inbox load makes
that companion run a GitHub search and a Jira query, so automatic loads wait 60 seconds after
the last one; review events refresh only prepared reviews, and the Work inbox sheet's refresh
always loads. Home validates
repository host, repository, and PR number before deduplicating an incoming request against
prepared work. Separate prepared reviews retain their operational owners. Work inbox continues
to expose the configured GitHub and Jira providers.

Waiting chat counts include actual blocked/input state. Unread completed replies can also
appear, labeled separately. Reserved shells and explicitly identified review/First Mate
workers are excluded. Chat title, location, and tab color come from existing pane data.
The recap merges dated current and historical alerts, preferring current evidence. History is
read at most once a minute per connection, when alerts join or leave. Its previous-visit
cutoff stays fixed for that visit; it is bounded history, not a complete audit.

**All clear** requires current source coverage and no outstanding input or unknown work state.
Loading, no machines, disconnected sources, unsupported capabilities, and stale information
remain explicit. Failed sources preserve usable rows while successful machines keep rendering.
Search and local hiding never change global badges or establish completion. Showing Home does
not mark conversations read.

## Local actions and exact destinations

**Skip for now** moves to the next card in priority order and the counter advances; the
skipped card comes around again after the rest. **Then** links jump to a card. **Later**
snoozes a non-idea item on this Mac for one hour and offers **Undo snooze** above the Ask bar
for a few seconds; Undo returns the card to its priority place. Status notes dismiss
themselves. New evidence can resurface a snoozed item immediately.
**Dismiss** hides a radar note until its evidence changes. Home explains when work is
snoozed locally. Preferences store versioned presentation metadata, scoped identifiers,
fingerprints, and visit/disclosure state. Expired and long-absent choices are pruned.

Each chip retains its actual owner. First Mate features open the exact machine/feature in
the standalone window. Prepared reviews select and reveal the exact host/review; watchers
scroll to the exact watcher; chat links open the machine-scoped pane even if already selected.
Machine links reveal the machine in Settings. An unprepared PR enters the existing creation
flow with a validated URL and an explicit host choice when needed. It does not automatically
start preparation. Missing targets remain unavailable without substituting another owner.

Quick replies hydrate the selected eligible focus card and up to three waiting chat cards
actually in the viewport, with at most two hydration reads active. Hiding or deactivating Home
cancels unnecessary work. Choices come from the shared validated skim reader, never from
parsing preview text. Submission rechecks the owner, connection, exact message/session, and
pending work. Real Pi permission interactions require opening the conversation; text resembling
a permission choice cannot approve one. Unsupported choices leave **Open conversation** available.

First Mate retries retain the original request identity and frozen label. Pi's ordinary prompt
endpoint has no caller-owned retry identity, so unconfirmed delivery has no blind Retry button.
Pending and unresolved Home replies survive presentation changes. A replacement connection
cannot receive the old reply or hide its unresolved outcome.
For an outcome without a safe retry, **Checked in conversation** hides its Home notice after
you inspect it. This does not confirm delivery or allow the same quick reply to be sent again.

## Lead conversation and draft continuity

The Ask bar opens the existing lead conversation using the configured lead-host policy.
**Ask about this** freezes the displayed evidence in a context card and appends a drafted
question. Suggestions also append to the composer; sending stays explicit. The transcript
contains real server messages, without a fabricated First Mate opener.

The stable Home controller owns drafts, attachments, quotes, dictation, and outgoing operations
through dismissal and tab changes. Submitted material freezes once, newer edits survive late
failures, and retries retain the original payload. Dismissal stops recording and invalidates
pending dictation submission. Read acknowledgements require the current owner, a key window,
and the latest content visible.

**Open in First Mate** transfers unsent text, context, and fully uploaded attachments once to
the exact lead. It appends beneath an existing window draft. Home clears only the material
acknowledged by the receiving window and then closes. Uploads, sends, and uncertain delivery
keep their operation on Home until resolved. A missing machine, replaced connection, or changed
lead cannot redirect the draft. With nothing held, the tray re-resolves the current lead instead
of staying on the old connection. Selecting another feature in the window does not retarget Home.
Draft retention covers this app session; relaunch and crash durability are not promised.

## Compatibility and source limits

This is a Mac presentation change. iOS retains its own navigation and Activity presentation.
Existing companion contracts, authorization, permission checks, and submission paths remain.
`dashboard_summary`, `FirstMateDashboardSummary`, and the compatible board endpoint are
retained despite the retirement of the Mac Dashboard and Agent view. See the
[API reference](dashboard-api.md). The signed Mac updater installs only the app; companion
packages require a separate installation. Missing lead support leaves the factual Home usable
and explains why its chat cannot open.

The GitHub request model has no head SHA or request timestamp. Its snooze fingerprint uses
canonical PR identity, open state, title, and author, so an otherwise identical new request
cannot resurface independently before the snooze expires. Waiting-chat evidence uses the
existing pane episode key; exact message/session checks happen during quick-reply hydration.
Section 6 of the [approved plan](first-mate-home-implementation-plan.md) records these fallbacks.
Home does not expose speculative disk cleanup or work migration.

## Synthetic verification and acceptance traceability

Use synthetic fixtures only. Launch a debug app with `-HerdrDemoMode -HerdrHomeMoment morning`;
other moments are `afternoon`, `clear`, `trouble`, `loading`, `disconnected`, and `stale`.
The moment hook isolates Home's preferences and bypasses production hydration. It does not
capture an operator's machines or sessions.

Run focused tests from the repository root, for example:

```sh
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' test \
  -only-testing:herdr-harness-macTests/HomeProjectionTests \
  -only-testing:herdr-harness-macTests/HomeStoreTests \
  -only-testing:herdr-harness-macTests/HomeRoutingTests \
  -only-testing:herdr-harness-macTests/HomeQuickReplyTests \
  -only-testing:herdr-harness-macTests/HomeActionContextTests \
  -only-testing:herdr-harness-macTests/HomeChatTests \
  -only-testing:herdr-harness-macTests/HomeChatPresentationTests
```

Select `HomeRenderTests` for the synthetic native image matrix: 1600×1000, 1280×900,
1000×680, Morning and Something broke accessibility variants, and expanded/scaled content.
ImageRenderer uses the shared production grid. Inspect its images against the locked design;
image generation alone does not establish a visual match. Run
`-only-testing:herdr-harness-macUITests/HomeUITests` for native window and interaction checks
from a Mac session with the required Automation permissions.

| Required observable outcome | Focused evidence |
| --- | --- |
| Owner separation, stable priorities, PR deduplication, honest all-clear, recap, representative fleet performance | `HomeProjectionTests` |
| Search preserves badges, stable skip order, snooze/Undo and changed evidence | `HomeStoreTests`, `HomeActionContextTests` |
| Exact destinations, explicit review host, one-time reveal and missing targets | `HomeRoutingTests`, `HomeRevealTests`, `HomeUITests` |
| Removed/reconfigured sources cannot publish late results; provider failure retains useful rows | `ShellRefreshLifecycleTests`, `WorkInboxTests`, `PRReviewFleetIndexTests` |
| Bounded hydration, stale-choice rejection, permission separation, duplicate prevention and retry ownership | `HomeQuickReplyTests` |
| Frozen context, newer drafts, attachment transfer, exact lead and read-state ownership | `HomeChatTests`, existing composer and dictation suites |
| Four tabs, compatible history/control routes, retained utility discovery | `HomeShellTests`, navigation suites, agent-control suites, `HomeUITests` |
| Native geometry, rich text, accessibility appearance and window interactions | `HomeRenderTests`, `HomeChatPresentationTests`, `HomeUITests`, inspected reference comparisons |

Test presence is not a passing result. Before each delivery, run
`scripts/check-public-source.py`, inspect visual and native interaction evidence, and use
`scripts/local-verify.py` for the exact committed revision as described in
[Mac releases](macos-releases.md). That workflow owns the full Mac suite and required shared
iOS checks; do not duplicate the full suite manually immediately before it. Record the tested
revision and actual results in the delivery record.
