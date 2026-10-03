# First Mate Home and four-tab shell: implementation plan

**Status:** Reviewed and approved on October 3, 2026. Ready to implement, starting with the pre-flight steps in section 0 and PR 1 in section 12.

**Date:** October 3, 2026.

**Source baseline:** `origin/main` at `82cbb05dc98a8b33c004016125b89c0b762ec3b4` when reviewed. The plan was first drafted against `9291a0a9`; re-fetch and rebase before starting, and treat whatever `origin/main` is then as the baseline.

**Design authority:** The locked [First Mate Home design specification](../design/first-mate-home-2026-10-03/DESIGN-SPEC.md), its `reference.html`, stylesheet, and four synthetic moments. The rendered reference wins if a written measurement disagrees with it. These design files are untracked in the main checkout and must be committed to the feature branch before work starts (section 0).

This document describes the proposed finished implementation, its integration requirements, and its acceptance criteria. It does not claim these changes are complete. A small, uncommitted scaffold (about 550 lines) exists in the `codex/first-mate-home` worktree, including initial Home models, visual primitives, and partial route changes. That scaffold has not been compiled or validated. The user's original working checkout has been preserved.

## 0. Review layer: October 3, 2026

This section records a review of the plan against the source at `82cbb05d`. It is a dated findings layer: the facts were true at that revision and should be re-checked if the source has moved. The decisions below are folded into the sections they affect.

### Pre-flight, before any code

1. Rebase the `codex/first-mate-home` worktree onto current `origin/main`. It sits six commits behind (the archive cleanup work) and has uncommitted edits to `AppRootView.swift`, `NavigationHistory.swift`, and `AgentControlController.swift`.
2. Commit `design/first-mate-home-2026-10-03/` to the feature branch after running `scripts/check-public-source.py`. Other design folders are already tracked, and the worktree cannot see the reference otherwise.
3. Compile the scaffold once so later failures are attributable to new work.

### What the review found

| Finding | Evidence at `82cbb05d` | Decision |
|---|---|---|
| Watchers and PR Review fleet polling are owned by a view | `.task` modifiers on `WorkspaceNavigationView`; the PR fleet loop also exits unless its rail is visible | Hoist both loops to the shell before the tab strip lands (section 4, PR 1). |
| The First Mate window is off by default | `FirstMateChatPreferences.defaultWindowEnabled = false`; the Window menu item is conditional | Remove the preference and make the window always available (section 5, PR 2). |
| Shortcuts collide | ⌘J is Jump to Pane, ⌘2 Focus Chat, ⌘3 Focus Terminal, ⌘5/7/8/9 Activity, Fleet, PR Review, Watchers, ⌘F belongs to `DashboardView` | Use the table in section 5. |
| Quick replies exist on main | `SkimReplyAction` in `FirstMateSkim.swift` and `FirstMateSkimReader.swift` | Hydration in section 6 is buildable as written. |
| Drafts are not shared between surfaces | `FirstMateChatWindowSession`, the HUD, and `AppRootView` each create their own `FirstMateStore`, and `composerDrafts` lives on the store | Keep a handoff, but the simplified one in section 7. |
| Both lifecycle bugs in section 4 are real | `refreshActivityFeed()` publishes after its awaits with no generation check; `WorkInboxStore.refresh()` replaces the whole response with no identity guard | Fix in PR 1. |
| The minimum window size is known | Main window is `minWidth: 1000, minHeight: 680` | Stated in section 8. |
| History records already tolerate unknown kinds | `HerdrDestinationRecord.kind` is a string and unknown kinds decode to nil | Migration is a small mapping (section 5). |
| The agent control schema names `activity` | `AgentControlRegistry` `segment` enum | Keep it as an alias and add `home` (section 10). |
| Several spec behaviors were silently changed | "Ask about this", the opener, the confirmation bubble, suggestion pills, Esc order, the 86-point offset | Listed in section 9. |
| No performance criterion, no iOS statement | Earlier First Mate lag came from polling plus redraw cost | Added to sections 10 and 11. |
| One branch with removal at the end | Section 12 as drafted | Replaced with five landable PRs. |

## 1. Intended outcome and scope

Opening Herdr should land on a native Home screen that closely matches the approved reference. Home should explain the current state of the user's work, surface one actionable item at a time, expose chats needing attention, show a concise activity recap, and provide a compact conversation with the existing lead First Mate.

The main window will have four persistent tabs, in this order:

1. **Home**
2. **PR Review**
3. **Watchers**
4. **Chats**

The PR Review, Watchers, and Chats content keeps its existing design and functionality. Changes to those destinations are limited to placement beneath the new shell, route handling, and the scroll/highlight behavior needed when arriving from Home. Their individual redesigns remain separate work.

### Replace

- The old Dashboard presentation and its dedicated state, preferences, and polling.
- The multi-column Agent View and its Mac-only presentation machinery.
- The old standalone Activity Feed destination, with Home's recap taking over its user-facing role.
- Any remaining Attention destination or entry points, with Home's focus stack and waiting-chat section providing the replacement.
- Obsolete navigation buttons, shortcuts, and menu entries for those destinations.

### Preserve and make discoverable

- First Mate conversations, project/session creation, workflow and agent inspection, Git/worktrees, documents, and feature-associated builds.
- PR Review preparation, comments, walkthroughs, skills, documents, Ask AI, and pop-out windows.
- Chats, terminal, Git, attachments, permission interactions, model controls, voice, and workspace organization.
- Fleet inventory and management, Agent Profiles, Settings/Machines, and the standalone Ask Agent capability.
- HUDs, Notes, Herd Pulse, notifications, updater, diagnostics, feedback, deep links, and external agent control.
- Existing GitHub/Jira inbox functionality where the configured companion supports it.

A **Chats overflow menu** will provide a stable home for retained utilities. It will include Fleet and the existing First Mate management surface, plus appropriate entries for the inbox, Ask Agent, Settings, and desktop tools. Existing tool-specific commands remain available in their current surfaces.

### Baseline correction

The earlier removal audit examined an older checkout. Latest main already contains a native Watchers screen and has removed Active Work. This implementation must use the current source graph, rather than repeating obsolete removal work or reintroducing code from the older checkout. Backend retirement is outside this Mac Home change.

## 2. Proposed architecture and ownership

Home will be a native SwiftUI surface. The reference HTML serves as the visual specification and comparison target.

```text
Existing server connections and authoritative stores
    FirstMateFleetIndex / FirstMateFleetDriver
    PRReviewFleetIndex / PRReviewStore
    WatchersStore
    HerdrAppModel: panes, machines, alerts, read state
    Guarded GitHub request-feed adapter
                       |
                       v
              Immutable HomeInput
                       |
                       v
         HomeProjection(input, now, calendar)
                       |
                       v
                 HomeSnapshot
                       |
              HomeStore presentation state
                       |
                       v
                HomeContentView
                       |
                  HomeCommand
                       |
                       v
             HomeHost / shell coordinator
              /                     \
     Existing destination       Existing operation owner
```

### Responsibilities

| Component | Responsibility |
|---|---|
| `HomeInput` | Immutable source facts, freshness, errors, and capability information assembled from existing stores. |
| `HomeProjection` | Pure transformation into narrative fragments, focus items, radar notes, chat cards, recap rows, counts, and mood. Takes explicit time and calendar for deterministic behavior. |
| `HomeSnapshot` | Render-ready value types. Contains no network clients, credentials, or mutation closures. |
| `HomeStore` | Local focus selection/order, snoozes, radar dismissals, recap disclosure, and visit metadata. |
| `HomeHostView` | Connects the snapshot to presentation and sends user commands to the shell or the appropriate existing operation owner. |
| `HomeContentView` | Layout and rendering of the Home sections. No network requests or source mutations from view evaluation. |
| Shell coordinator | Tab selection, utilities, typed routing, search requests, and window presentation. |
| `HomeChatController` | Lead-chat presentation, composer lifecycle, and explicit transfer to the existing First Mate window. |

The Home chat controller and presentation state need an owner that survives tray dismissal and tab changes. A process-owned or stable root-owned coordinator will provide that lifetime. Creating them inside a conditional Home detail view would lose drafts when switching tabs.

Existing server stores remain authoritative. Home will not take over their selected feature or review merely to build its summary. It will consume lightweight fleet data and hydrate detail only when a visible interaction needs it.

### Structured text and routes

Narrative text will use typed runs: plain text plus entity chips. Each chip contains a display label, icon/avatar, semantic tone, and an exact route. Rendering arbitrary prose will not create actionable identities by matching names.

Routes retain their owners:

- First Mate: machine ID and feature ID.
- Prepared review: machine ID and review ID.
- Watcher: machine ID and watcher ID.
- Chat: existing machine-scoped pane ID.
- Machine: machine ID.
- Unprepared review request: validated canonical pull-request identity and URL.

Names, emoji, list position, and a PR number alone are never routing keys.

## 3. Data sources and projection rules

| Home element | Existing source | Integration requirement |
|---|---|---|
| First Mate status, focus items, moving work | `FirstMateFleetIndex` hosts, feature summaries, latest-message metadata, and established attention predicates | Reuse fleet observation and preserve exact host ownership. Exclude the lead conversation from ordinary feature counts. |
| Prepared reviews | `PRReviewFleetIndex.active` and existing review state | Keep preparation failures, ready reviews, and unknown state distinct. |
| Unprepared review requests | GitHub section of `fetchWorkInbox()` | Add a guarded owner and deduplicate against prepared PR identities. |
| Watcher notes and attention | `WatchersStore.entries`, attention, live/state fields, notices | Reuse existing watcher artwork and control paths. |
| Waiting chats | Scoped panes, real blocked/input state, unread IDs, and conversation evidence | Separate waiting-for-input from unread completion. Exclude reserved shells and explicitly identified worker sessions. |
| Chat title, location, and color | Existing pane/workspace presentation, machine roster, and tab-color store | Preserve the same identity and appearance as Chats. |
| Recap | Current alerts, fetched alert history, and trustworthy dated source records | Merge and deduplicate without implying complete historical coverage. |
| Machine issues | Actual connection state and available health evidence | Report only measured or observed facts. |
| Home conversation | Existing lead First Mate conversation | Use existing transport, conversation persistence, and configured host policy. |

### Attention and ordering

The initial deterministic priority policy will place actionable machine outages first, followed by blocked First Mates, explicit user decisions, failed review preparation, ready reviews, and outstanding unprepared review requests. Within a priority, use meaningful activity time and a stable scoped ID as tie-breakers.

The implementation will reuse established status interpretation wherever possible. Unknown status must remain unknown. Archived, cancelled, and completed features do not enter the actionable stack simply because their last message is still present.

A prepared review and an incoming GitHub request for the same PR should not appear as two separate tasks. Deduplication uses verified repository host, repository identity, and PR identity. Prepared reviews on separate machines retain their separate operational ownership even when the presentation groups related evidence.

Opening or rendering Home does not mark conversations read. Read markers continue to depend on the existing visibility and active-window rules in the actual conversation surface.

### Summary and proactive copy

There is no dedicated Home narrative endpoint in the inspected baseline. The recommended first implementation constructs concise, factual prose and smart chips from existing summaries and source state. This renders immediately and remains usable without a model request.

Examples of acceptable derived copy include a named feature needing a decision, a named review ready to open, or a machine currently unreachable. Claims such as “I handled this for you,” “nothing is lost,” or “the rest paused safely” require explicit supporting evidence.

Richer questions use the real lead conversation. If the desired first release requires newly generated cross-machine narrative and proactive offers on every Home visit, that needs a separate, versioned briefing capability. Its contract, freshness, cost, cancellation, and factual grounding should be reviewed before adding it to scope.

## 4. Refresh ownership, freshness, and race protection

Home and the tab badges must remain current without mounting every full detail screen.

- Keep First Mate fleet observation under the existing process-owned driver.
- Move the Watchers loop out of `WorkspaceNavigationView` into a shell-owned refresh coordinator. It keeps the same source configuration, connection identity, `watchersRefreshTick` trigger, and activity-sensitive `pollingInterval`. The `-HerdrWatchersDemo` launch hook and the PR Review open-request handling that sit beside it move with it or stay reachable from every tab.
- Move the PR Review fleet loop to the same coordinator. Replace the "rail is visible" condition with "the main window is visible and the app is active", so Home and the tab badges stay current on any tab. Keep `setSources` reconciliation running while hidden, as it does today. Preserve the distinction between fetching cached summaries and requesting an upstream GitHub status refresh.
- The coordinator must survive tab changes and must not depend on any destination view being mounted. Land it before the tab strip, with no visible change (PR 1).
- Refresh recap and GitHub request data on initial use, relevant source events, and app activation, with coalescing and conservative fallback polling.
- Pause unnecessary presentation work while hidden or inactive. An outstanding send retains its own operation lifecycle.
- Avoid fetching every feature transcript or review detail to render the Home page.

Two existing gaps need explicit fixes before connecting the new presentation:

1. `HerdrAppModel.refreshActivityFeed()` currently lacks sufficient captured-connection and cancellation checks before publishing collected responses. Add generation/source validation so a delayed response cannot restore a removed host or replace data from a new configuration.
2. `WorkInboxStore.refresh()` lacks a connection identity guard and can replace the whole response after a provider-level failure. Harden it or introduce a narrowly scoped request-feed adapter that retains the last successful GitHub result with an error indication.

`fetchWorkInbox()` currently uses the primary companion. The initial plan preserves that configured source. It must not be described as a fleet-wide GitHub inbox unless aggregation is explicitly implemented with account-aware deduplication.

Every asynchronous response must validate its captured owner and connection generation before publishing. Changes to credentials, roster, demo mode, or selected target invalidate dependent requests. Cancellation should not produce a spurious failure banner.

Successful hosts continue rendering if another host fails. Last usable rows can remain visible with stale status. Missing or unreachable sources must not turn outstanding work into “all clear.”

## 5. Shell, navigation, shortcuts, and retained tools

### Global tab strip

The strip is 64 points high and overlays the full window. Tabs are centered on the window, independent of any sidebar width. Home has no toolbar band or divider behind this strip. A soft scroll backdrop appears only as content passes beneath it.

Use the reference's 38-point tab height, 14-point horizontal padding, 15-point icons, 13-point labels, and accent underline. The Home icon uses the compact First Mate face and current mood.

Badge policy:

| Tab | Badge |
|---|---|
| Home | Unresolved actionable focus count; ideas do not contribute. |
| PR Review | Reviews waiting on the user, including unprepared requests; preparation failures affect its alert tone. |
| Watchers | An attention mark when watcher evidence requires a look. |
| Chats | Chats genuinely waiting for input. |

Search affects visible Home results, while badges continue describing the whole available fleet. Filtering or snoozing is not evidence that underlying work was resolved.

### Destination composition

- Home occupies the full content area and has no sidebar.
- PR Review retains its host/list rail and existing detail controls.
- Chats retains its navigator, pane content, and local tools.
- Watchers retains its existing content layout, without an unrelated Chats rail being introduced by tab selection.
- Fleet and other utilities open from Chats overflow and remain associated with Chats in the global tab selection.

Existing destination toolbars move below the global strip where necessary. The change will preserve their controls and hit targets. The reference's sketches of those tabs are not a mandate to rebuild their contents.

### Typed route behavior

| Home target | Result |
|---|---|
| First Mate feature chip | Open the existing First Mate window on the exact machine/feature conversation. |
| Open First Mate card | Open My First Mate in the existing window. |
| Prepared PR chip | Select PR Review, route to its exact host/review, and reveal the selection. |
| Unprepared review request | Enter the existing review-creation flow with the validated URL and explicit host selection where required. |
| Watcher chip | Select Watchers, scroll to the exact watcher, and briefly highlight it. |
| Chat chip or card | Select Chats and open the exact scoped pane, including when it was already selected. |
| Machine chip | Open Settings/Machines and reveal the exact machine. |
| Ask about this | Open the Home tray with context and a draft question; submission remains explicit. |

Watcher and review reveal requests need stable request IDs so repeated SwiftUI appearances do not replay the same highlight. If an entity disappears before navigation finishes, show a useful unavailable state while preserving its owner information.

The First Mate window becomes a permanent part of the app. Remove the `FirstMateChatPreferences` window preference, its Settings toggle, and the conditional menu item, so every First Mate route has a destination. Linked screens start 86 points from the window top, as the spec requires, so they clear the strip.

### Keyboard and history

| Shortcut | Today | After |
|---|---|---|
| ⌘1 | Unassigned | Home |
| ⌘2 | Focus Chat | PR Review |
| ⌘3 | Focus Terminal | Watchers |
| ⌘4 | Unassigned | Chats |
| ⌥⌘1 | Unassigned | Focus Chat |
| ⌥⌘2 | Unassigned | Focus Terminal |
| ⌘J | Jump to Pane | Ask First Mate, bringing Home forward if necessary |
| ⇧⌘J | Unassigned | Jump to Pane |
| ⌘F | Dashboard search | Home search on Home; other destinations keep their own find behavior |
| ⇧⌘F | First Mate window, when enabled | First Mate window, always |
| ⌘7 | Fleet | Fleet (unchanged) |
| ⌘5, ⌘8, ⌘9 | Activity Feed, PR Review, Watchers | Retired |
| ⇧⌘D, ⇧⌘A | Dashboard, Agent View | Retired |
| ⌘K, ⇧⌘K, ⌘[ , ⌘], ⇧⌘[ , ⇧⌘] | Open Chat, Reveal, Back, Forward, pane stepping | Unchanged |

- Escape closes one thing per press, in the spec's order: search, then the Home chat tray. Focus returns to whatever opened it. The First Mate window is a separate window and closes with its own ⌘W.
- Preserve Back/Forward for retained pane, Git, and destination navigation.
- Add a `home` destination kind. Map saved `dashboard`, `agentBoard`, and `activity` records to `home` on decode, then deduplicate adjacent entries. Unknown kinds already decode to nil, so an older build reading a newer snapshot drops `home` harmlessly.
- Update external-control discovery, validation, and execution together (section 10).

## 6. Focus stack, actions, snoozes, and recap

`HomeStore` owns a single selected focus ID. The visual layer must not keep a second independent index.

- **Skip for now:** advances to another eligible card without resolving or dismissing the current item.
- **Then links:** select the indicated card in the stack.
- **Later:** stores a local snooze with a visible expiry. The default is one hour, with an Undo affordance.
- **Radar dismissal:** hides that observation locally. It does not acknowledge server alerts, archive work, or mark a conversation read.
- **Open:** routes to the destination and leaves resolution to actual source state.
- **Send or another real mutation:** presents pending/failure state through the existing operation owner. Completion copy follows confirmed results.

Snoozes and dismissals are keyed by scoped identity and a meaningful evidence fingerprint. A new question, changed review revision, new outage episode, or new attention reason resurfaces the item. Ordinary polling timestamps do not invalidate a snooze.

| Item | Scoped identity | Fingerprint |
|---|---|---|
| First Mate feature | Machine ID + feature ID | Attention reason + ID of the latest message that needs the user |
| Prepared review | Machine ID + review ID | Review state + head revision |
| Unprepared review request | Repository host + repository + PR number | Head revision, or the request timestamp when no revision is available |
| Watcher note | Machine ID + watcher ID | Attention reason + ID of the latest run or notice |
| Machine issue | Machine ID | Issue kind + the time this outage episode began |
| Waiting chat | Scoped pane ID | Blocked or input state + ID of the latest message |

Use the field names the source types actually expose; if a listed field is missing, pick the nearest stable one and record it here. Store snoozes, dismissals, and visit metadata in one small versioned record in the app's local preferences, separate from server state. Prune expired snoozes on load, and drop entries whose identity has been absent from the fleet for seven days.

**Implementation fallback record (October 3, 2026):** `GitHubReviewRequest` supplies neither
a head SHA nor a request timestamp. Its local snooze fingerprint therefore uses the verified
canonical PR identity with open state, title, and author. A new head or repeated request with
identical available fields cannot be detected independently; the one-hour snooze still expires.
Waiting chats use the machine-scoped pane ID and `pane.episodeKey`, the existing episode
identity available without fetching every transcript. Quick-reply submission separately
rehydrates and validates the exact current message and session. These are source limitations,
not inferred message IDs or timestamps.

The stack must remain stable as unrelated data refreshes. If the selected item is removed by confirmed source changes, choose the next eligible item deterministically and preserve keyboard focus.

“Nice. You're clear.” is reserved for a verified cleared state. If every item is locally snoozed, explain that instead. Loading, stale, unsupported, disconnected, and empty states have distinct copy.

### Quick replies

The full First Mate conversation already exposes verified skim reply choices (`SkimReplyAction` in the shared package). Fleet summaries provide preview text and `skimSay`, but not those choices. Implement bounded detail hydration for the visible focus card and visible waiting-chat cards, with cancellation and a small concurrency limit.

A quick reply must validate the exact owner, current question/message, connection generation, and pending-send state. Reuse existing submission and permission handling. Generic text that resembles “Allow once” must never become an approval button by inference.

If valid choices are unavailable, show an Open conversation action. This preserves the interaction's intent without presenting an unsupported control.

### Recap

Capture the previous visit cutoff when Home opens and keep it stable for that visit. Use it to present source-backed updates since the prior visit. Persist only the minimal visit metadata needed for continuity.

Merge current and historical alerts by scoped identity, allowing fresher current state to win. Add other dated changes only when the underlying data supports them. The recap is a useful bounded summary, not a complete audit log.

Preserve disclosure state and provide links to surviving source entities. Do not erase alert history or change read state merely because the recap is expanded.

## 7. Inline First Mate chat and pop-out continuity

The tray is another presentation of the existing lead conversation. Its server conversation identity must be the same one opened in the First Mate window.

The tray and window retain independent navigation state. Selecting a feature in the standalone window must not silently retarget the Home composer.

### Composer and conversation reuse

Reuse the existing First Mate send and outgoing-message machinery, including request identity, optimistic rows, delivery receipts, retry, and draft revision protection. Reuse attachment policy, upload behavior, model controls, and dictation support.

- Freeze the submitted draft, attachments, and contextual snapshot once per send.
- Detach only the material actually submitted.
- A late failure must not overwrite text typed after submission.
- Retry keeps the original request identity and frozen payload.
- An uncertain delivery remains visibly uncertain until reconciled.
- Dismissing the tray stops recording and invalidates any pending dictation auto-submit.
- HTTP cancellation is not presented as stopping the agent. A Stop control requires an actual supported coordinator operation.
- Read markers apply only when the lead conversation is active and its latest content is visible.

The existing composer draft store is in-memory. The initial guarantee is preservation across tray dismissal, tab changes, and the explicit window transfer. Relaunch/crash durability would require additional private draft persistence and should be reviewed separately rather than assumed to exist.

Home context appears in a clearly identified context card. The UI does not insert a fabricated First Mate opener into the transcript. When the user submits a contextual question, include the relevant observed summary once in the submitted conversation context. Reopening Home does not repeatedly post it.

### Transfer protocol

The tray and the window each own a separate `FirstMateStore`, so drafts are not shared automatically. Open in First Mate therefore uses a one-time handoff carrying a transfer ID, the exact machine and lead identity, the Home context, and the unsent text.

1. Open the window on the exact lead conversation. If its machine or connection is gone, stay in the tray and say so.
2. Append the incoming text beneath any draft already in the window. Nothing is overwritten, and there is no merge dialog.
3. The window consumes the transfer ID once; the tray then clears the text it handed over and closes.

Fully uploaded attachments move with the text. While an upload or a send is still in flight, the tray stays open and the button explains why, so each operation keeps a single owner. Repeated appearance or observation callbacks must not duplicate text or attachments. A missing machine must not silently substitute another lead.

The destination shows a From Home context card. Sent conversation history remains server-backed and survives ordinary refreshes independently of the transient handoff.

## 8. Native visual implementation

Split presentation into focused components: First Mate column, summary balloon, focus stack/card, waiting chats, recap, Ask bar, rich text/chips, and the shared avatar. Keep palette, spacing, typography, and shape definitions centralized.

### Geometry to match

| Element | Reference target |
|---|---|
| Home content inset | 92 points from the window top; 116 points at the bottom. The 64-point strip is already accounted for in the top inset. |
| Wide grid | Left column 290 points, gap 44, content up to 780, side padding 40. Center the whole grid. |
| At or below 1360 points wide | Left column 250, gap 32, side padding 28. |
| Main avatar | 168-point frame, with ring art extending to approximately 208 points without changing layout. |
| Summary | Radius 24, padding 26/30/22, 30-point greeting, 16.5-point prose, 11 by 20-point left tail. |
| Focus card | Radius 16, 40-point leading mark, 16-point gap, reference padding, 17-point title, 15-point body. |
| Stack layers | Up to two layers at 10/20-point offsets, 96.5%/93% scale, 75%/45% opacity. |
| Chat cards | Adaptive columns with a 290-point minimum and 10-point gap. |
| Ask bar | 448 by 50 points, centered 22 points above the bottom. |
| Tray | 574 points wide, capped at 700 points and 78% of window height, 16 points above the bottom. |

Use the exact reference palette, SF Pro typography, controlled surface fills, border opacity, shadows, and dusk gradient. Native material alone will not reproduce the reference's layering. Reduced Transparency receives a deliberate opaque equivalent.

The avatar shares one vector implementation across its large and compact sizes. It includes the specified face geometry, five moods, 60 tick marks, breathing/float, blinking, pointer response, and thinking treatment. Animation runs within the avatar subtree and stops when hidden, inactive, or Reduce Motion is enabled.

Inline chips require careful native layout: preserve whitespace, punctuation, baselines, wrapping, and paragraph boundaries. Each chip remains keyboard-focusable and accessible as a link/button while the sentence remains understandable to VoiceOver.

The supported minimum stays at the main window's current 1000 by 680 points. At that width the narrow grid leaves about 662 points of content, which still fits two 290-point chat columns; the Ask bar and tray use the spec's narrow rules (window width minus 64 and minus 48). Herdr Mac is dark only, so no light variant is built. Keep operational text readable and actions reachable at the app's existing font-scale steps.

Entrance and success animations must follow real state transitions. Reduced Motion turns ambient and displacement animations off while retaining immediate, understandable state changes.

## 9. Existing capability gaps and proposed behavior

| Reference behavior | Proposed production treatment |
|---|---|
| Fresh AI-authored overview on every visit | Factual projection from current evidence initially. A dedicated briefing capability is a separate architecture decision. |
| “Clear 14 GB” and exact disk thresholds | Show only measured telemetry and verified cleanup estimates. Route to existing Machines/Cleanup flows until that evidence exists. |
| “Move this work to another machine” | Do not expose a migration action without a verified transfer/checkpoint operation. Offer existing diagnosis or navigation. |
| Inline reply choices from preview text | Hydrate validated conversation choices or open the conversation. |
| "Ask about this" asks the question immediately | Open the tray with the card's context and a drafted question. Sending stays an explicit press. |
| First Mate's opener at the top of the tray | Show the context pill only. No opener is invented; the transcript holds real messages. |
| "Sent. …" confirmation bubble after answering a card | Show a short confirmation built from the confirmed operation result, styled as a status line, not as a First Mate message. |
| Suggestion pills that change with the moment | Ship a fixed synthetic set per moment, taken from the spec. Tapping one fills the composer; sending stays explicit. |
| Esc closes search, the First Mate window, then the chat | Esc closes search, then the tray. The First Mate window is a real separate window and closes with ⌘W. |
| “Prepare this review” | Reuse the existing PR Review creation/preparation flow, retaining host selection and validation. |
| Complete overnight narrative | Display supported updates with honest coverage and timestamps. |
| Missing lead capability | Keep Home's factual snapshot usable and explain the chat capability requirement. Preserve access to the existing First Mate surface. |
| No machines or first use | Use a useful connection/start state, with no fabricated work or zero-data success message. |
| One source offline | Preserve successful sources and stale evidence with a clear notice and existing recovery entry point. |

These treatments were approved in the October 3 review. They determine how closely sample interactions translate into current production capabilities.

## 10. Removal and compatibility work

Delete obsolete presentation only after the replacement is integrated and its retained dependencies are accounted for.

| Area | Treatment |
|---|---|
| Dashboard views/state | Remove dedicated screens, old focus/search state, polling, and obsolete build shelf. |
| Agent View | Remove multi-column UI, column/session state, dedicated Mac client usage, fixtures, and tests that only serve that view. |
| Activity/Attention presentation | Remove retired destinations and their menu entries. Preserve alert transport, history, read-state, and notification behavior used elsewhere. |
| Shared Dashboard-named types | Move retained review wire types, age text, labels, and styles to appropriate shared or feature folders. Rename only where useful. |
| `FirstMateDashboardSummary` | Preserve the compatible API field and useful lightweight summary data. Its name is not a reason to remove it. |
| Builds | Preserve First Mate-associated Mobile App Hub and simulator builds. Remove only Dashboard-specific configuration and presentation. |
| Utilities | Keep Fleet, Ask Agent, profiles, inbox, HUD, Notes, Pulse, and operational tools accessible. |
| Routes and persistence | Migrate retired history records and update supported commands and identifiers together. |
| Agent control | Add `home` to the `segment` schema. Keep `activity` as an accepted alias that opens Home, so existing skills and external agents keep working. Update `AgentControlRegistry` and `AgentControlController` in the same change. |
| First Mate window preference | Remove the preference, its Settings toggle, and the conditional menu item. |
| iOS | Untouched. It keeps its own Activity views and `refreshActivityFeed()`. Any change to `HerdrFirstMateShared` must still compile and pass on iOS. |
| Server and other clients | Keep their contracts compatible. No server cutover or broad API retirement is included. |

Search production source, tests, fixtures, documentation, accessibility identifiers, launch flags, settings, and control schemas for retired references. Classify shared dependencies before deleting by filename or directory.

## 11. Verification and acceptance criteria

### Model and lifecycle tests

- Identical entity IDs on different machines remain distinct and route to the correct owner.
- Priority order is stable when dates tie or unrelated hosts refresh.
- Completed/archived features and the lead do not inflate attention counts.
- Unknown review state does not become a review request.
- Prepared and unprepared PR evidence deduplicates by verified identity.
- Provider failure preserves the last useful request result with a notice.
- Removed/reconfigured hosts cannot publish late results into Home or recap.
- Search changes visible results without changing global badges.
- Skip rotates only; snooze expires; changed evidence and new episodes reappear.
- Local hiding, disconnected sources, and initial loading cannot produce false completion.
- Recap merging prefers current evidence and uses deterministic time boundaries.

### Action and chat tests

- Every chip and action resolves to its intended destination, including already-selected panes.
- Watcher/review reveal requests apply once and handle missing targets.
- Stale quick replies, wrong owners, changed connections, and pending sends prevent invalid submission.
- Submission/retry does not duplicate messages or overwrite newer drafts.
- Dismissed dictation cannot submit later.
- Attachment completion cannot publish into a replacement owner.
- Pop-out opens the exact lead, preserves pre-existing drafts, and acknowledges each transfer once.
- Unresolved delivery is retained through presentation changes.
- Home rendering does not clear conversation unread state.

### Visual and interaction validation

Create entirely synthetic fixtures for Morning, Afternoon, All clear, Something broke, Loading, Disconnected, and Stale. Fixtures remain separate from production networking and storage.

Capture native renders at 1600 by 1000, 1280 by 900, and the 1000 by 680 minimum. Spot-check Morning and Something broke with Reduce Motion and Reduce Transparency. No light-mode or largest-text-scale matrix is required. Compare to reference crops at matching logical dimensions and backing scale.

### Performance

- `HomeSnapshot` and its parts are `Equatable`; an unchanged projection publishes nothing and redraws nothing.
- Projection runs from a coalesced input (at most a few times per second under churn), never from view evaluation.
- Opening Home triggers no transcript or review-detail fetches beyond the bounded hydration in section 6.
- Avatar animation invalidates only the avatar subtree and stops when Home is hidden or the app is inactive.
- Switching tabs and opening the tray stay responsive with a synthetic fleet of 4 machines, 40 features, 20 reviews, and 60 panes. A projection test over that fixture guards against regressions.

Check tab centering, top inset, avatar size, balloon edges/tail, stack offsets, chip baselines, chat columns, Ask bar, and tray geometry. Inspect real AppKit traffic lights, dragging, resizing, full screen, keyboard focus rings, and scrolling in the running app because offscreen rendering alone cannot validate those behaviors.

Exercise Command-1 through Command-4, Command-F, Command-J, Escape, tab focus, recap disclosure, focus rotation, contextual Ask, and all route types. Verify VoiceOver labels, reading order, selected state, and recovery from disappearing content.

Run regression checks for existing PR Review, Watchers, Chats, First Mate windows, Fleet, and desktop tools. A new Home must not weaken their authentication, confirmation, permission, or operation checks.

### Repository gates

Use the repository's documented Mac build commands and focused tests during development. Run `scripts/check-public-source.py` before committing. Keep all fixtures and screenshots synthetic, with private configuration and captured sessions outside the repository.

For a later authorized pushed delivery, run `scripts/local-verify.py` against that exact revision to produce the required Mac test status. Follow the current repository instruction not to duplicate the full Mac suite manually before that workflow. Broaden tests when shared contract changes require it.

This plan does not authorize or require a release. If delivery is later requested, Mac publication uses the signed release feed. Companion packages remain separate, and the user's working checkouts remain preserved.

## 12. Implementation sequence and review checkpoints

The work lands as five pull requests. Each one compiles, passes its focused tests, and leaves the app usable as a daily driver. Home stays behind a local preference (off by default) until PR 5, and the Dashboard stays reachable until then.

| PR | Contents | Done when |
|---|---|---|
| **1. Foundations** (no visible change) | Pre-flight from section 0. Generation guard for `refreshActivityFeed()`. Guarded GitHub request-feed adapter that keeps the last good result. Shell-owned refresh coordinator for Watchers and the PR Review fleet. `HomeInput`, `HomeSnapshot`, `HomeRoute`, and the pure `HomeProjection` with fingerprints. | Lifecycle and projection tests pass, including the performance fixture. Watchers and PR Review still refresh exactly as before. |
| **2. Four-tab shell** | Tab strip, badges, the shortcut table, Chats overflow, `home` destination and history mapping, agent-control `home` plus the `activity` alias, First Mate window preference removed. Home tab shows a plain placeholder behind the preference. | Every retained screen and tool is reachable by mouse and keyboard. Linked screens clear the strip. |
| **3. Read-only Home** | Avatar, summary balloon, chips, focus stack, waiting chats, recap, search, and the synthetic fixtures. Wired to the real projection. Chips and Open actions route; nothing mutates. | Renders match the reference at the three sizes. Loading, stale, disconnected, and empty states are distinct. |
| **4. Actions and tray** | Skip, Later with Undo, radar dismissal, bounded quick-reply hydration, the Ask bar and tray, suggestion pills, and the pop-out handoff. | Action and chat tests in section 11 pass. Drafts survive tab changes and the handoff. |
| **5. Switch over and remove** | Home on by default and the preference deleted. Dashboard, Agent View, Activity, and Attention presentation removed per section 10. Documentation updated. | Nothing references the retired screens. Full review, privacy scan, and `scripts/local-verify.py` on the exact revision. |

Each PR should leave clear evidence: tested data behavior, working navigation, comparison renders, verified action handling, or completed cleanup. Publish or release only under the applicable requested delivery workflow.

## 13. Decisions

Decided on October 3, 2026. These no longer block implementation.

| Decision | Outcome |
|---|---|
| First Mate window | Always available; the preview preference is removed. |
| Shortcuts | The table in section 5. |
| Refresh ownership | A shell-owned coordinator for Watchers and the PR Review fleet. |
| Pop-out | One-time handoff that appends to the window's draft. |
| Delivery shape | Five pull requests, Home behind a local preference until the last one. |
| Verification scope | Dark only, three window sizes, Reduce Motion and Reduce Transparency spot checks. |
| Home narrative generation | Ship factual, source-backed prose first. Add generated briefings only through an explicit capability with its own contract. |
| GitHub request coverage | Use the currently configured primary companion and describe that coverage accurately. |
| Focus ownership | One HomeStore-owned selection/order, stable across tab changes. |
| Snooze behavior | One-hour local snooze with Undo, scoped to evidence; changed evidence resurfaces. |
| Chat draft lifetime | Preserve through dismissal, navigation, and acknowledged pop-out. Treat relaunch durability as additional persistence work. |
| Search | Search the active surface; Home's query filters Home without altering global counts. |
| Missing action capabilities | Offer the existing supported destination or workflow and explain unavailable capabilities. |
| Existing destination designs | Preserve their contents; change shell placement and explicit reveal behavior only. |
| Release scope | Mac application implementation and verification. No inferred server deployment or broad backend retirement. |

The result is acceptable when Home matches the reference closely at its designed sizes, every visible action has a verified production path, asynchronous updates preserve owner identity, the lead conversation survives presentation changes, and all retained tools remain accessible through the four-tab shell and Chats overflow.
