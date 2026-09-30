# First Mate for iPhone: end-to-end implementation plan

**Updated:** 2026-09-29 · **Historical research baseline (2026-09-28):** `origin/main` at `30627dc` (companion 0.64.1b1, macOS 0.64.1-beta.1, iOS release/ios.json 0.16.0 build 39) · **Implementation status:** Phases 0–3 implemented (theme, shared/mobile data, conversations, feature chat/composer v1, pushed Info and briefing/readouts). Phases 4–6 remain planned. The old detail/chat/message/composer and inspector-sheet host are removed; existing inspector/resource content remains for Phase 6 polish. My First Mate is still an explicit client-built briefing, not a real lead chat. Phase 7 is deferred and outside this delivery.

**Current delivery decisions (supersede the original kickoff):**
- Selected and pressed conversation rows use `rowHighlightFill` = `codeFill` (6% ink) and a 10 pt row radius. Bubbles keep their 18 pt radius; no Mac token or view changes.
- New First Mate chrome caps Dynamic Type at `.xxxLarge`; Phase 6 applies the same cap app-wide. This limits **text scaling, not message length**: complete messages remain readable and scrollable, never ellipsized to enforce the cap. Controls keep at least 44 pt hit targets.
- Working passive Reduce Motion / Reduce Transparency fallbacks remain supported. They are not separate workstreams or independent release gates; no dedicated reduction-settings matrix is required.
- Phases 0–6 retain one branch/PR per phase and their automated verification, review, privacy and landing gates. The first-push approval gate is removed; there are no per-phase push-permission or phone-test pauses.
- Deliver **one final signed iOS build after Phase 6** for device testing, not seven intermediate phone builds. Final release metadata belongs to that delivery. No Phase 7, Mac release, server deployment or companion package publication is included.

**What this folder holds**

| File | What it is |
|---|---|
| `IMPLEMENTATION-PLAN.md` | This plan: as-is findings, the target design, the theme port, architecture, phases, verification, decisions |
| Original kickoff prompts (not included) | Historical planning inputs; current delivery decisions above take precedence |
| `research/mac-chat-window.md` | Exhaustive inventory of the Mac chat window (the port's source of truth: every view, size, color, rule, test) |
| `research/ios-app.md` | The iOS app as it stands: project settings, tabs, First Mate tab, theme, reusable pieces, networking, push, tests, CI |
| `research/server-contract.md` | Every First Mate route, the fleet and lead contracts, the shared Swift client, demo data, gotchas |
| `asis/*.png` (not included) | Local historical captures, excluded from this source copy |

The Mac design reference is unchanged: `docs/first-mate/chat-window/reference.html` (the approved v8 prototype) and `docs/first-mate/chat-window/BUILD-SPEC.md`. **Where the Mac code and its spec disagree, port the code** (`research/mac-chat-window.md` §0 lists the ten differences, e.g. the breathing floor is 0.75, not 0.4).

---

## 0. Summary

**The ask.** Bring the Mac's standalone First Mate chat app to the iPhone with the layout of the Grok Bot app (Telegram/iMessage-style): a compact bar, a row of big pinned avatars with "My First Mate" first, two-line conversation rows with a one-line preview of the last message and unread dots; tapping a conversation opens the chat; a further screen holds the inspector detail (Overview, Agents, Documents, Workflow). Keep Herdr's dark "dusk glass" theme, and port the full First Mate (lead) functionality and the per-feature "second mate" chats, all inside the First Mates tab.

**The approach, in one paragraph.** The Mac chat window is built from three kinds of code: pure rules (dot, badge, sorting, preview text, time labels, transcript grouping, briefing text, lead machine choice, mention linking), platform views (SwiftUI over AppKit hover/keyboard/window chrome), and a theme (`HerdrTheme` + `HerdrGlass` + `HerdrRecipes`). Phase 1 moves the shared rules and fleet index into `HerdrFirstMateShared/` so the Mac and iPhone run the same logic (retaining the Mac's existing assertions and platform wrappers), ports the theme to UIKit-backed SwiftUI, and writes touch-first views that reproduce the Mac look and numbers. The server needs **no change for Phases 0–6** (push and app badge belong to the deferred Phase 7); every route the phone needs already exists behind `first-mate-fleet-v1` and `first-mate-lead-v1`, and the iOS client already decodes the fleet types. The current iOS First Mate tab is **replaced**, not kept beside the new one; its stores, create sheet, archive sheet, inspector, resource sheets and tests are reused and restyled.

**Phases at a glance** (details in §5)

| Phase | Delivers | Server change | Size |
|---|---|---|---|
| 0 | Theme foundation on iOS: Mono generator tokens, dusk + haze glass, recipes, type ramp, contrast tests | none | M |
| 1 | Shared chat logic (moved out of the Mac target), iOS fleet index with read state and badge, client gaps (lead, attachments, voice, journal-only fetch), deep links | none | L |
| 2 | Conversations screen: compact bar, pinned avatar row with My First Mate, two-line rows, search, archive, create, tab badge | none | M |
| 3 | Chat screen for second mates: grouped bubbles, skims, mentions, file cards, suggested replies, notices, read markers, text composer with drafts | none | L |
| 4 | My First Mate: real lead chat, machine choice and failover, lead context, briefing fallback, lead Overview | none | M |
| 5 | Composer parity: attachments, hold-to-talk voice, model + thinking pill, context line, @ picker, rate/copy | none | M |
| 6 | Info screen restyle, iPad three-column layout, app-wide dusk and text-scaling cap, accessibility polish | none | M |
| 7 (deferred) | Freshness: app icon badge, background refresh, First Mate push (separate future authorization) | yes | M |

**Assumptions (say so if any is wrong)**
1. **Confirmed 2026-09-29:** the layout reference is the Grok Bot iPhone app (App Store id6794501026). §2.0 lists what is borrowed from its five store screenshots. Only the layout; the theme stays Herdr's dusk glass.
2. **Dark only.** The First Mate tab's System/Light/Dark option goes away (the user has said twice that Herdr is dark-only). The rest of the iOS app is already forced dark.
3. "Second mates" are each feature's own First Mate (the coordinator behind a feature chat), the term the runtime and HUD spec use.
4. iPhone first; iPad gets the three-column layout in Phase 6 with the same views.
5. The Mac app keeps working exactly as today. Moving pure logic into the shared folder is a refactor guarded by the Mac's existing tests.

---

## 1. Historical as-is findings (2026-09-28)

This section and `research/` preserve the pre-implementation inventory, including its version numbers, counts and source locations. They are historical facts, not the current implementation status. Phase 0 now provides the theme foundation described in §3 and Phase 1 provides the data layer in §4. Phase 2 now supplies the conversations list. Phase 3 now supplies feature chat, composer v1, pushed Info and briefing/readouts. Real lead chat, composer parity and Info/iPad polish remain Phases 4–6.

### 1.1 The Mac First Mate chat window (the source)

Shipped between 2026-09-27 and 2026-09-28 across PRs #83, #84, #88, #92 and #96, with follow-ups since (macOS 0.54 → 0.64.1, companion 0.54b1 → 0.64.1b1). It lives in `herdr-harness-mac/herdr-harness-mac/FirstMate/ChatWindow/` (19 files, 5,204 lines) plus `FirstMateFleetIndex.swift`, `FirstMateLeadMachine.swift`, `FirstMatePromptComposer.swift`, `FirstMateComposerModelControls.swift`, `FirstMateStatusColors.swift`, and app-level `State/FirstMateFleetDriver.swift`, `State/FirstMateDockBadgeController.swift`, `State/FirstMateChatDemoSource.swift`. `research/mac-chat-window.md` inventories all of it. The facts that shape the port:

- **Layout.** Sidebar 320 pt (76 pt avatar rail below 760 pt), chat column, inspector 360 pt (inline at ≥ 1140 pt, overlay below, auto-open at ≥ 1280 decided once). Dusk backdrop behind everything; sidebar and pane glass at 0.80; Haze band (280 pt, 6%) at the top of the chat.
- **Rows.** 10 pt dot column, 48 pt emoji disc (violet `#2A2244`, radial lavender highlight, 1 pt lavender edge at 20%, emoji at 50% of the diameter), name 13.5 semibold + time 11, one-line preview 12 ("You: " prefix; skim sentence for First Mate; "typing…" in accent while a reply is being written), status word 11.5 in its status color (working rows show the step: Planning, Building, In review, In QA, PR open, Merging, and breathe between 1.0 and 0.75 over 2.4 s). Dot = 9 pt flat, only when `needsYou && isUnread`, colored by the reason (blocked `alert` #E2A7B6, your turn `attentionBadge` #FF9F0A, ready for review `signal` #9CCDB9). Hairline divider from the text column. Sorted by `activityAt` descending across all machines, de-duplicated by (machine, feature), archived rows dropped. Time labels: `HH:mm` today, "Yesterday", weekday within a week, else "Sep 3".
- **My First Mate.** Always the first row, no "Pinned" label: face orb 48, accent dot when the lead has an unread reply, preview = the lead's latest message ("You: " for yours) or the briefing text, status line "N features need you" in secondary text. Header subtitle "3 need you, 3 moving, 1 done" and a machine menu (Automatic / pinned) when more than one machine has a lead; "‹machine› is offline" in `warning` when a stand-in is in use.
- **Chat.** Groups of consecutive same-speaker, same-day messages; speaker name on the first bubble, avatar (26 pt) and 5 pt tail corner on the last; bubbles radius 17 (yours accent at 20% with a 26% accent edge; theirs ink 6% with a hairline); day pills; typing row (three 6 pt dots, 1.1 s); file cards on the first reply naming a document; mention runs (bold, emoji-prefixed, tint at 22%) from `herdr://first-mate?feature_id=…` links and plain-name matches; `SkimmableReply` around Markdown; meta line (Skimming…, Queued, Sent by voice, HH:mm); "Decision needed" label on the pending checkpoint; execution-state notice band above the composer; suggested-reply chips only from the newest skim's `reply` blocks; closed features replace the composer with a line of text. Read marking when the window is key, scrolled to the bottom and the conversation is unread; optimistic local state with rollback and backoff.
- **Composer.** Feature chats and the real lead use the shared `FirstMatePromptComposer` (a `PromptComposerView` card: context ring + line, attach, dictation, voice note, model + thinking pill, "Use host default", send; attachments become "Attachment: `path`" lines; dictation adds a transcription caveat). The 22 pt pill composer with hold-to-talk and the @ picker exists only on the Phase 1 briefing screen (`FirstMateChatComposer(.lead)`), where sending opens the create sheet with the text as the goal. @ picks insert plain `@Name ` and are serialized to Markdown links at send.
- **Inspector.** The native `FirstMateInspectorView` (underline tabs Overview/Agents/Documents/Workflow, 32 pt sync footer) bound to the window's own store; for the lead, `FirstMateLeadOverviewView` (Goal line, then Needs you / Moving / Done groups, native status wording).
- **Data.** One `FirstMateStore` per machine owned by the window (never the main window's instance, because the store mixes selection and data); the selected store refreshes every 2 s while a chat is open; the app-level fleet index polls every host every 10 s (30 s in the background) with `GET /features` + capability probe + `GET /lead` + `GET /fleet`, keeps a failed host's last data, and publishes only real changes. Lead machine: pinned → this Mac's own machine (if it supports peers) → a machine that already has a lead → the busiest; offline after 2 failed polls, stand-in chosen by the same rules. The Dock badge is `FirstMateBadge.count`.

### 1.2 The iOS app today

**Project.** `herdr-harness-ios/herdr-harness-ios.xcodeproj`, iOS 26.0 deployment target, iPhone + iPad, Swift 6.0 with `SWIFT_STRICT_CONCURRENCY = complete` and approachable concurrency (default isolation is nonisolated; code marks `@MainActor` explicitly). Every target uses folder references (`PBXFileSystemSynchronizedRootGroup`), so a new `.swift` file under `herdr-harness-ios/herdr-harness-ios/` compiles without touching the pbxproj. `HerdrFirstMateShared/` is compiled into the iOS app as source (same for the Mac), so anything added there must build on both platforms (`#if os(macOS)` is the existing pattern, e.g. `FirstMatePalette.swift`). Bundle IDs `org.herdr.companion.ios` (+ `.widgets`); `release/ios.json` is at version 0.16.0, build 39. Xcode 26.2 is installed here; the project's last upgrade check is 26.4.

**Tabs** (`Views/Root/AppRootView.swift:114-138`, iOS 18 `Tab` API): First Mate (`sailboat`) → `FirstMateWorkspaceView`; Agents; Attention (the only tab with a badge, `model.unreadAlertCount`); Notes; Settings. `AppTab` is in-memory only (`HerdrAppModel.selectedTab`, default `.workspaces`); `-HerdrFirstMateDemo` / `-HerdrOpenFirstMate` select First Mate.

**Appearance.** The app is forced dark except the First Mate tab, which follows `@AppStorage("herdr.firstMate.appearance")` (System/Light/Dark, `FirstMateAppearance.swift`) and paints itself with the 7-token iOS branch of `FirstMatePalette` (dark background #1A1C26, surface #242633, accent #B3ABFF…). The rest of the app uses the fixed charcoal `HerdrTheme` (ink #191A23, graphite #20212C, surface #353747, text #E4E5ED, accent #AAA6F4, same pastel status colors, `attention` #FF9F0A). `HerdrBackground` is a flat ink fill; `GlassCard` is opaque graphite with a 1 pt outline. There is no dusk, no haze, no `glassEffect`, no Mono generator, and no `HerdrRecipes` on iOS. Fonts: `HerdrProse` scales system fonts from Dynamic Type anchors (body 15, h1 20, h2 17); Inter is bundled but unused for chat.

**First Mate tab today** (`Views/FirstMate/`, `FirstMate/`):
- Compact width: `NavigationStack(path: [FirstMateFeatureTarget])`; regular width: `NavigationSplitView` with a 280–380 pt feature column and a trailing `.inspector`.
- `FirstMateMobileFleetStore` (@MainActor @Observable) owns one shared `FirstMateStore` per machine, a `FirstMateMachineScope` (`.all` or `.machine(id)`, persisted as `herdr.firstMate.scope.v1`), and flattens rows across hosts in **roster order, then each host's own order** (no cross-host recency sort). `waitingRows` = `awaiting_direction` or `blocked`; `attentionCount` exists and is tested but is not shown anywhere.
- Polling: `fleet.observe(sources:connectionGeneration:)` refreshes every host every 10 s **only while the First Mate tab is selected and the scene is active**. Each refresh = capabilities + `GET /features?view=` + the selected feature's snapshot. No SSE, no background refresh, no First Mate push.
- List (`FirstMateFeatureListView`): a `ScrollView` of `FirstMateFeatureCard`s (radius 20, status pill, ticket, cost, title, two-line goal, host label, current step) under section headers "Needs your direction" / "Your features" / "Archived", with a search field, a host menu, an options menu (Appearance, Refresh, Show archived, Next demo scenario) and "New feature". Context menu: Archive… / Unarchive (`FirstMateMobileArchiveSheet` → `POST /features/{id}/actions`).
- Feature screen (`FirstMateFeatureDetailView` → `FirstMateChatView`): a capsule row (Workflow, Agents · n, Docs · n, Overview) above the transcript. Your messages are accent-tinted bubbles (radius 18, accent at 13%); First Mate replies are **unbubbled** prose under a `sailboat.fill` + "First Mate" header, wrapped in `SkimmableReply(style: .firstMate)`. The composer (`FirstMateComposerView`) is **text only**: a 1–6 line field and a 44 pt send circle; no attach, voice, model or context controls. It sits in `.safeAreaInset(.bottom)` over `.background(.bar)`. The tab bar stays visible in the chat (pane chats hide it).
- Inspector (`FirstMateInspectorPresentation`): iPhone `.sheet` at `.large`; iPad `.inspector` 320–460 pt. Tabs Overview / Agents / Documents / Workflow come from the shared `FirstMateInspector`.
- Create sheet with destination machine, title, goal, folder; `POST /first-mate/features`.
- Demo: `-HerdrDemoMode -HerdrFirstMateDemo` seeds machines `demo1` "desktop" and `demo2` "laptop" with `FirstMateDemo.features(step:)` plus the iOS-only `demo2-release-checklist`. Appearance can be forced with `-herdr.firstMate.appearance dark`.

**Already compiled into iOS but unused (all in `HerdrFirstMateShared/`):** `FirstMateFleetEntry` / `FirstMateFleetResponse` (label, emoji, `hudStatus`, `stepIndex`, `now`, `latestMessage` with `skimSay`, `readThroughMessageID`, `unread`, `workingOnReply`, `activityAt`), `FirstMateHudStatus.needsYou`, `FirstMateDefaultEmoji`, `FirstMateChatSteps`, `FirstMateLeadSummary`, `FirstMateMention`, and the chat-window demo data `FirstMateDemo.chatWindowFeatures` / `chatWindowLead` / `chatWindowFleet`. `HerdrAPIClient` already implements `fetchFirstMateFleet`, `markFirstMateRead` and `updateFirstMateHud` with no callers. **Not implemented on iOS** (the protocol defaults throw): `uploadFirstMateAttachment`, `transcribeFirstMateVoice`, `fetchFirstMateLead`, `ensureFirstMateLead`, the link routes; `sendFirstMateMessage(context:)` falls back to a plain send.

**Reusable pieces on iOS:** the pane `PromptComposerView` (tied to a `HerdrPane`/workspace; its attachment tray, `ComposerAuxiliaryBar`, `AttachmentPolicy`, photo preparation and code-block paste can be lifted), `HerdrQuickVoiceCapture` (hold to dictate, phases idle/recording/locked/transcribing, `endHold(transcribe:)`), `HerdrVoiceRecorder` (16 kHz WAV, 10-minute cap), `HerdrAppModel.transcribeVoiceNote(at:)` (Parakeet on the first machine, then `AppleVoiceTranscriber`), `SkimmableReply` / `SkimReadingState` / `SkimExcerptView`, `FirstMateDocumentContentView` (scheme-aware markdown), `PiMarkdownText`, `ToastView`, `HerdrHaptic` (16 cases, unused by First Mate today).

**Networking.** `actor HerdrAPIClient: FirstMateClient`, bearer token per machine from the Keychain (`api-token.<machineID>`), 15 s timeout for every First Mate call (attachments 90 s, voice 120 s), capabilities probed per refresh (`GET /first-mate/capabilities`; the iOS host mirror currently omits the fleet and lead flags). Machines: `HerdrMachine {id, name, urlString}` under `herdr.machines`, https or loopback http only, managed in Settings → Machines.

**Push and background.** APNs registration exists for pane alerts (`/api/v1/push/devices`, payload `pane_id` + `machine_id`), plus local fallback alerts and Herd Pulse Live Activities. `NotificationManager.setBadge` counts pane alerts only. No `UIBackgroundModes`, no background tasks, no notification categories, and nothing First Mate related.

**Tests and CI.** Swift Testing for First Mate mobile logic (`FirstMateMobileFleetTests`, `…LifecycleTests`, `…RoutingTests` with fake `FirstMateClient` actors, isolated `UserDefaults(suiteName:)`); XCTest render tests through `IOSNativeRenderHarness` (hosts a view in a `UIWindow`, **forces dark and fills with `HerdrTheme.ink`**, widths 320/375/402/430, Dynamic Type default + accessibility3, PNGs to `$HERDR_IOS_RENDER_DIR` or a temp dir). UI tests exist (`HerdrFirstMate*UITests`, screenshots to `/tmp/herdr-first-mate-ios-screens/`) but **CI runs only `herdr-harness-iosTests`** on `macos-26` (`.github/workflows/verify.yml:94-108`, gated by `scripts/ci-plan.py` on changes under `herdr-harness-ios/`, `HerdrFirstMateShared/`, `HerdrFirstMateSharedTests/`).

Captures of the current tab in demo mode are in `asis/` (the list in light and dark, and a feature chat). They show the shape of what is being replaced: a card list under a large title, an unbubbled First Mate reply, a text-only composer, and the tab bar still visible inside the chat.

### 1.3 Server and shared contract (what the phone can rely on)

`research/server-contract.md` has the full route table; the port depends on these facts:

- **Everything needed exists on the companion today.** Capabilities are advertised by `GET /api/v1/first-mate/capabilities` (the server does not enforce them; clients check the strings). Relevant: `first-mate-fleet-v1` (`GET /fleet`, `POST /features/{id}/read`, `POST /features/{id}/hud`), `first-mate-lead-v1` (`GET/POST /lead`, `context` on lead messages), `first-mate-lead-peers-v1` (server-to-server relay; the client only reads `peers`), `first-mate-skim-v1` (skims embedded in messages), `first-mate-attachments-v1` (`POST /features/{id}/attachments`, JSON base64, response is **camelCase**), `first-mate-model-settings-v1` / `-safe-model-settings-v1`, `first-mate-archive-v1`, `first-mate-feedback-v1`, `first-mate-journal-events-v1` (`?events=journal`), `first-mate-board-v1` (bounded `GET /board` with `if_version`).
- **Fleet entry** fields: `feature_id, title, label (≤24, word-boundary clip), emoji (user or FNV-1a default from a 16-emoji palette), hud_status (blocked|turn|ready|working|idle|done), step_index (0–5) / step_fraction / percent (null when unknown), now (≤120), latest_message {id, role, text ≤200, created_at, skim_say?}, latest_first_mate_message_id, read_through_message_id, unread, working_on_reply, activity_at, updated_at, archived_at`. Sorted by `activity_at` desc; the lead is never in it; no `if_version` (only `/board` has one). `unread` = newest conversation-visible assistant message is after the read marker (no marker → unread; your own messages never make it unread).
- **Lead summary** (`GET /lead`): `{feature (full row + model_selection…), unread, working_on_reply, latest_message, machine {id, name}, peers [{id, name, url}]}`. Context usage and cost come only from `GET /features/{lead_id}` or `/board`. Swift's `FirstMateLeadSummary` does not decode `machine` yet.
- **Messages** are posted with `POST /features/{id}/messages {text, request_id[, context]}` → 202 partial acknowledgement; idempotent per `request_id`. Suggested replies have no field of their own: they are the newest First Mate message's skim `reply` blocks. Mentions travel as Markdown `[Name](herdr://first-mate?feature_id=…[&assignment_id=…])`. Attachments go up first, then `Attachment: `path`` lines in the text. Voice is `POST /api/v1/voice/transcriptions` (no First Mate-specific route). Actions: pause, resume, cancel, archive (with reason), unarchive; nothing else.
- **No First Mate push and no SSE worth listening to.** `first_mate.updated` fires only on client-made mutations and skim settlement; coordinator replies publish nothing. Polling is required. APNs exists for pane alerts only; First Mate has an optional Message Hub webhook. `/fleet` is per machine; **all cross-machine aggregation is client side**.
- **Demo data** for the new UI already exists in the shared folder: `FirstMateDemo.chatWindowFeatures(now:)` (seven features covering every status, three unread, three with suggested replies), `chatWindowLead`, `chatWindowFleet`.
- **Gotchas the plan fixes:** iOS `UploadedAttachment` decodes snake_case only (the attachment route returns camelCase); iOS has no journal-only fetch, so each poll downloads all `pi.*` telemetry; `APIError.server` drops the error `code`; the HUD spec's fleet section is stale (trust `docs/first-mate/build-contract.md` and `herdr_harness/first_mate_fleet.py`); `scripts/first-mate-ios-fixture.py` probably 500s on `/features` because its `FixtureRuntime` lacks `health()`/`lead()` (verify before relying on it).

### 1.4 Gaps to close

| Area | Mac chat window | iPhone today | Plan |
|---|---|---|---|
| Theme | Mono generator + dusk glass + haze + recipes | 48-line charcoal palette, flat backgrounds | Phase 0 |
| Conversation rows, dots, badge | `FirstMateConversation`, `FirstMateBadge`, `FirstMateReadState` | none (fleet types decoded but unused) | Phases 1–2 |
| Fleet polling across machines | `FirstMateFleetIndex` + driver (10 s / 30 s, all windows closed) | `FirstMateMobileFleetStore` polls `GET /features` only, only on the tab | Phase 1 |
| Lead | real lead chat, machine choice, failover, context, briefing fallback | client cannot even fetch the lead | Phases 1, 4 |
| Transcript | grouped bubbles, mentions, file cards, typing, skims, notices | flat rows, unbubbled replies, skims present | Phase 3 |
| Composer | attach, dictation, voice note, model + thinking, context line, @ picker | text field + send | Phases 3, 5 |
| Read markers | optimistic, rolled back, backoff | none | Phase 3 |
| Inspector | native tabs + sync footer, lead Overview | native tabs in a `.large` sheet | Phase 6 (restyle), Phase 4 (lead) |
| Deep links | `herdr://first-mate?feature_id=` opens the chat | not routed | Phase 1 |
| Badge | Dock badge, Dock menu | Attention tab only | Phase 2 (tab), Phase 7 (app icon) |
| Freshness off screen | app-level driver | none | Phase 7 |

---

## 2. Target design for iPhone

### 2.0 The layout reference: Grok Bot

The layout reference is the **Grok Bot** iPhone app ([App Store, id6794501026](https://apps.apple.com/us/app/grok-bot/id6794501026)), a Telegram/iMessage-style messenger for AI agents. Its five store screenshots ("Your team of always-on agents", "Work with many at once", "Signs in to your tools", "Works everywhere you do", "Comes back finished") show the structure we adopt. **Only the layout is borrowed; the theme stays Herdr's dusk glass** (no white surfaces, no black user bubbles, no colored blob avatars).

What Grok Bot does, screen by screen, and what we take from it:

| Grok Bot | We take | We keep ours |
|---|---|---|
| **Home:** no large title; a compact bar with a round profile button on the left and a pill on the right holding search and ＋ | the compact bar: our companion-host button on the left (the current tab already has it), a glass pill on the right with search, ＋ and ⋯ | glass surfaces over the dusk |
| **Home:** a row of three big avatars with names underneath ("Chief of Staff", "EA", "Inbox Manager"), the bots you message most | the **pinned avatar row**: My First Mate first, then the conversations that need you, with unread dots | face orb and violet emoji discs |
| **Home:** two-line rows: avatar, bold name, time on the right, one-line preview; generous spacing | two-line rows with the status word trailing on the preview line | hairline dividers from the text column, status colors, breathing working labels |
| **Chat:** a back circle, a title pill with the bot's small avatar and name, two circle buttons on the right (live screen, ⋯) | the same bar: back, title pill (avatar 24 + name, tap for details), ⓘ and ⋯ circles | glass pill and circles |
| **Chat:** plain left bubbles with no avatar or name for the bot, dark right bubbles for you, a "Today 8:00 AM" pill, short "Done" / "Sent" acknowledgments | no avatar or speaker line on First Mate's own bubbles (1:1 feel); day pill with the time | ink 6% bubbles for First Mate, accent 20% for you, tails on the last bubble of a group; agents keep their speaker line and disc |
| **Chat:** action cards inside the bot's bubble ("New email" with Send email / Discard), document cards as their own bubbles, a 👍 reaction under a bubble | suggested replies as buttons **inside** the First Mate bubble that offers them; file and PR cards as bubbles; ratings shown as a reaction badge | our tokens and the skim body |
| **Composer:** a round ＋ outside the field, a pill field "Ask Chief of staff" with the mic inside | the same arrangement: ＋ circle, pill, mic that becomes send | hold-to-talk, hint row, context and model accessories |

### 2.1 Information architecture

```
First Mates tab (NavigationStack, tab bar visible)
└─ Conversations screen ............ compact bar: [host ◯]            [🔍  ＋  ⋯]
   ├─ pinned avatar row ............. My First Mate, then needs-you features, big orbs with names and dots
   ├─ conversation rows ............. every non-archived feature across all machines, newest activity first
   └─ tap an orb or a row ─▶ Chat screen (pushed, tab bar hidden)
        ├─ bar: [‹] [◯ Name ▾]                              [ⓘ] [⋯]
        ├─ transcript: day pills, bubbles, inline action buttons, file cards, notices
        ├─ composer: [＋] [ Message Receipt export …  🎙 ] with the context/model line above
        ├─ tap ⓘ or the title pill ─▶ Info screen (pushed): Overview · Agents · Documents · Workflow, sync footer
        │            └─ documents and sessions open as sheets (as today)
        └─ tap a capsule ─▶ readout popover ─▶ "Open chat" pushes that feature's chat
```

iPad (Phase 6): `NavigationSplitView` with the same three screens as columns (sidebar 320, content, inspector 360), matching the Mac window.

### 2.2 Conversations screen

**Bar.** No large title (Grok Bot). A 44 pt bar in the safe area with the tab's name only in the tab bar ("First Mates"). Left: a 40 pt glass circle with the companion-host glyph (`desktop.and.arrow.down` today) opening the existing **Companion host** menu (All Machines / each machine; the scope is documented and tested). Right: a glass pill with three 40 pt circles: `magnifyingglass` (reveals a search field that slides in under the bar; filters title, label, preview and machine name; the lead stays only when the query is empty or matches "My First Mate"), `plus` ("New feature", identifier `first-mate-chat-new-feature`, opens the existing `FirstMateCreateSheet`), and `ellipsis` (**Show archived**, **Refresh**, in demo **Next scenario**). The circles and the pill are `HerdrGlassBackground(level: .80)` with a hairline edge; glyphs in `iconTint`.

**Background.** The dusk backdrop (whole region) under `HerdrGlassBackground(level: 0.80, base: railBackground)`; the tab bar keeps its iOS 26 glass and picks up the purple from underneath.

**Pinned avatar row** (the Grok Bot row of big bots). A horizontally scrolling `ScrollView` of orbs, 24 pt below the bar, leading inset 20, spacing 24:
- **My First Mate** first, always: `FirstMateFaceOrb(88)` with the outer ring, "My First Mate" underneath at 13 medium `secondaryText`; an accent 12 pt dot at the orb's top-trailing when the lead has an unread reply.
- Then every conversation that **needs you** (blocked, your turn, ready for review), ordered blocked → your turn → ready, then by activity (the HUD rule): `FirstMateEmojiDisc(88)` with the emoji at 44, the label underneath (one line, 13 medium, tail-truncated at 96 pt), and the 12 pt flat unread dot in the reason color at the top-trailing when unread. At most 6; a 7th "+N" disc (`inkFill(0.08)`, "+3" at 20 semibold) opens the list scrolled to the first hidden one.
- When nothing needs you the row holds My First Mate alone, leading-aligned, with "Nothing needs you" as its caption line.
- Tap opens the chat; long-press opens the context menu (Open info, Archive…). VoiceOver: "My First Mate, unread reply" / "Receipt export, Blocked, new message".
- Alternative (decision 14): user-pinned conversations via long-press → Pin, stored per phone. Not the default: the server has no pin field and needs-you is what the user opens most.

**Rows.** Below the pinned row, without a section label: every non-archived feature across all machines, newest activity first (the Mac sort, de-duplicated by machine and feature, archived dropped). Empty states use the Mac strings ("No features yet. Press ＋ and tell First Mate what to build.", "No conversations match “q”.", "Loading conversations…"). The list is a `List` with `.listStyle(.plain)`, clear row backgrounds and custom dividers; pull to refresh refreshes every host.

**Row anatomy** (two lines, like Grok Bot; Mac values in `research/mac-chat-window.md` §3)

| Element | iPhone | Mac |
|---|---|---|
| Dot column | 12 pt wide, dot 10 pt flat, no glow | 10 / 9 |
| Avatar | `FirstMateEmojiDisc(52)`, emoji at 26 | 48 |
| Line 1 | shared `conversation.name` (honoring user presentation metadata) 16 semibold, tracking −0.2, one line · time 13 `tertiaryText` monospaced digits, trailing | 13.5 · 11 |
| Line 2 | preview 15 `tertiaryText`, one line, truncating ("You: " prefix; skim sentence for First Mate; "typing…" in `accent` while `workingOnReply`) · **status word** 12 semibold in its status color, trailing, fixed (Blocked, Your turn, Ready for review, Planning…Merging, Ready to plan, Complete); working words breathe 1.0→0.75 over 2.4 s, static under Reduce Motion | preview 12; status on a third line at 11.5 |
| Padding | 12 top/bottom, 8 leading, 16 trailing; spacing 12 | 10 / 4 / 10 / 10; spacing 9 |
| Divider | 1 pt `hairline` from x = 84 (8 + 12 + 52 + 12) to the trailing edge | from x = 80 |
| Row height | ≈ 76 pt | 79 pt |

Rules (unchanged from the Mac, all in shared code): dot only when `hudStatus.needsYou && isUnread`; dot color = reason (blocked `alert` #E2A7B6, your turn `attentionBadge` #FF9F0A, ready for review `signal` #9CCDB9); preview text rules; machines are one flat list with no group labels (the machine name shows in the chat bar's subtitle and matches search). The lead is **not** repeated as a row; it lives in the pinned row (decision 15).

**Touch interactions.** Tap opens the chat. Swipe trailing: **Archive…** (the existing archive-reason sheet; `POST /actions {archive, reason}`; the row leaves the list locally first). Long-press context menu: Open info, Archive…, Copy feature ID. Selected and pressed rows share `rowHighlightFill` (`codeFill`, 6% ink) with `Radius.row` (10 pt), through `herdrRowBackground` / the row button recipe; no hover states. Phase 2 reuses this quiet highlight rather than the 10% generic `selectedFill`.

**Reply progress and tab badge.** Read existing stores outside the cached base projection and apply shared `FirstMateReplyProgress`: pending local/server replies show working/typing and suppress needs-you dots/pins, while failed/unconfirmed sends and newer activity/replies retire the local bridge. Preserve done/native feature status. `.badge(fleet.badgeCount)` counts these same projected feature dots globally, independent of host/search and lead unread; do not copy the Mac's separate window/Dock badge distinction. The Attention tab keeps its own badge.

**Accessibility.** Row label "Title, Status[, new message]"; identifiers `first-mate-chat-row-<featureID>`, `first-mate-chat-pinned-lead`, `first-mate-chat-pinned-<featureID>`, `first-mate-chat-search`.

### 2.3 Chat screen (a second mate)

- `.toolbarVisibility(.hidden, for: .tabBar)` like pane chats; `.toolbarColorScheme(.dark, for: .navigationBar)`; the system navigation bar is hidden and replaced by Herdr's own 44 pt bar so the pill and circles can be glass over the dusk (Grok Bot).
- **Bar.** Left: a 40 pt glass circle with `chevron.left` (pops; the interactive swipe-back gesture stays enabled). Center-left: the **title pill** (glass, height 40, radius 20): `FirstMateEmojiDisc(24)` + name 16 semibold + `chevron.down` at 10; tapping it opens the Info screen; for the lead it opens the machine menu (§2.6). Under the name, when there is room, a 12 pt status line in the status color ("Blocked", or "In QA · Step 4 of 6", or "Building · DevBox" when there are several machines); at narrow widths the status line moves into the pill's second line. Right: two 40 pt glass circles: `info.circle` (identifier `first-mate-chat-inspector-toggle`, pushes the Info screen) and `ellipsis` (Archive…, Pause / Resume, Cancel… with confirmation; the actions the current detail menu already has).
- **Background:** pane glass 0.80 over the dusk; `HerdrHazeBand` (280 pt, 6%) pinned to the top of the transcript, under the bar.
- **Transcript** (`ScrollView` + `LazyVStack`, `defaultScrollAnchor(.bottom)`, follows the newest message while within 40 pt of the bottom, `scrollDismissesKeyboard(.interactively)`):
  - content max width 720 (iPad), horizontal gutter 16 on iPhone; bubble max width `min(round((width − 32) × 0.82), 560)`;
  - grouping, day pills, the checkpoint "Additional response from this turn" disclosure: from the shared `FirstMateTranscriptLayout`;
  - **day pill** "Today 8:00" / "Yesterday 17:12" / weekday / "Sep 3" (the Mac label plus the first message's time, as Grok Bot and iMessage do);
  - bubble shape radius 18 `.continuous`, padding 10/14/8; yours accent at 20% with a 1 pt accent edge at 26%, right-aligned; First Mate's `inkFill(0.06)` with a hairline edge, left-aligned, **no avatar and no speaker line** (Grok Bot's 1:1 feel; decision 16); a 5 pt tail corner on the last bubble of a group; **agent** messages keep the speaker line (title 13 semibold `secondaryText` + role 13 `tertiaryText`) and their `FirstMateEmojiDisc(24)` with the status edge, because who spoke matters there;
  - body: `SkimmableReply(style: .bubble)` (new iOS style: sentence 16/24, lines 15/22) around `FirstMateDocumentContentView`/`PiMarkdownText` with the mention linker applied (bold emoji-prefixed runs on tint at 22%); attachment chips (paperclip capsule) in your bubbles; the dictation suffix is hidden and shown as "Sent by voice" in the meta line;
  - **inline actions** (Grok Bot's "Send email / Discard"): when the newest First Mate message carries skim `reply` blocks and the chat needs you, the replies render as buttons **inside that bubble**, under the text: `HerdrButtonStyle(.outline, height: 36)` with 14 semibold `accent` labels in a wrapping row, the first one `.primary`; tapping sends the text and the buttons collapse to a "You chose: …" caption (decision 17). Never invented on the client; nothing while typing;
  - **cards as bubbles:** file cards (`doc.text` tile, title 15 semibold, "From Agent", opens Documents) and saved PR links (`arrow.up.right.square`, title, `github.com`) render as their own `inkFill(0.06)` bubbles right after the message that names them, the way Grok Bot shows "Q3 board deck v4 · docs.google.com";
  - meta line 11 `tertiaryText`, right-aligned: Skimming… · Queued · Sent by voice (`accent`) · HH:mm;
  - **reactions:** a rated reply shows a 22 pt 👍 or 👎 badge at its bottom-leading corner (Grok Bot's reaction), from the feedback routes; long-press a First Mate bubble: **Copy**, and (Phase 5) **Rate up / Rate down** when the host supports feedback; your bubbles: Copy;
  - "Decision needed" (`hand.raised`, 13 medium, `warning`) on the pending checkpoint bubble; the execution-state notice band (8% `warning` fill, hairline top) between transcript and composer; store errors under the transcript; closed features show "This feature is closed. Its conversation and evidence remain available." instead of the composer;
  - the typing row (three 6 pt dots, 1.1 s, static at 0.6 under Reduce Motion) as a small left bubble, no avatar.
- **Read marking:** requires `scenePhase == .active`, this screen on top of the stack, and a current bottom/layout observation of the displayed server reply. Fleet-only newer IDs and collapsed additional replies are not read authority. Content, disclosure projection and store lifecycle fence old geometry; the ScrollGeometry container already excludes composer safe-area insets. Unread is attempt eligibility, not a task identity that cancels its own optimistic clear. Local override first, `POST /read` after, rollback with a visibility/source-fenced 8 s → 180 s retry deadline, independent of unchanged healthy polls. The phone-owned `FirstMateMobileChatState.markRead` provides this behavior for features and the lead, fencing delayed success/failure to the saved connection and preserving newer unread replies. The mechanically shared Mac lead-read implementation is not changed.
- **Haptics:** `HerdrHaptic` light tap on send, success when an inline action is sent, warning when a send fails.

### 2.4 Composer

One composer for features and the lead, `FirstMateMessageComposer`, laid out like Grok Bot's (＋ outside, a pill with the mic inside) and built for touch rather than lifting the pane `PromptComposerView` (which is bound to a `HerdrPane`, a workspace and Pi model catalogs). It reuses the pane composer's parts: `ComposerAttachmentTray`, `ComposerPhotoPreparationState`, `ComposerCodeBlockPaste`, `AttachmentPolicy`, `HerdrQuickVoiceCapture`, `HerdrVoiceNoteRecorderSheet`, `HerdrVoiceWaveform`.

Layout, bottom to top, inside `.safeAreaInset(edge: .bottom)` over the pane glass, 16 pt gutters, 12 pt above the home indicator:
1. **Row:** a 40 pt glass circle **＋** on the left (attachments menu, Phase 5), then the **pill** (radius 24, min height 48, fill `inkFill(0.05)`, edge `inkFill(0.10)`; `accent` at 65% when focused; `alert` at 70% while listening) holding a `TextEditor` 1–7 lines at 16 with line spacing 4, placeholder "Message Receipt export" / "Ask First Mate about any feature, or tell it what to pass on…" / "Describe a new feature", and a trailing 36 pt circle inside the pill that is **send** (`arrow.up`, `onPrimary` on `accent`) when there is text and **mic** (`mic.fill`, `inkFill(0.08)`) otherwise. Every control sits in a 44 pt hit target.
2. **Hint row** (12, `tertiaryText`): "Type @ to tag a feature. Hold the mic to talk." / "Listening. Let go to send." / "Transcribing…" / "Nothing heard." / errors in `warning`.
3. **Accessory line** above the pill (Phase 5): the context ring + one-line context text (`FirstMateCoordinatorContextView` port; `warning` when pressure is reached; the `info` button opens the context sheet) and the model + thinking pill (`PiModelEffortPill` port over `/first-mate/models` and `/model-settings`, with "Use host default" and the "Change this coordinator session?" confirmation). Collapsible with a chevron so the chat keeps its space.
4. The attachment tray (Phase 5) above the row while files are attached.

Behavior:
- **Send (new Phase 3 composer):** follow the shipped Mac contract: synchronously reserve with `beginOutgoingMessage`, detach only the exact submitted draft/attachments/picks, then `completeOutgoingMessage` and notify `didMutate(machineID)`. Freeze owner, store lifecycle, request ID, payload and lead context (including nil). Failed/unconfirmed sends offer explicit Retry/Copy; retry reuses that frozen submission, never automatically resends or migrates it after failover. Phase 3 now uses that reservation boundary; its plus menu opens Documents, while attachment/voice/model controls remain Phase 5. Return inserts a newline; the button sends. On iPad hardware ⌘↩ sends.
- **Attachments (Phase 5):** ＋ opens a menu: Photos (`PhotosPicker`, `AttachmentPolicy.maximumCount`), Files, Paste code. Uploads go to `POST /features/{id}/attachments` on the feature's machine; uploaded paths become "Attachment: `path`" lines at send; the tray shows progress, retry and remove. Hidden when the host lacks `first-mate-attachments-v1` (hint: "Update this machine's companion server to attach files.").
- **Hold-to-talk (Phase 5):** press and hold the mic 300 ms (`DragGesture(minimumDistance: 0)` works on touch); the editor area shows the waveform and "Listening…"; letting go transcribes on **the feature's machine** (`POST /voice/transcriptions` there, falling back to `AppleVoiceTranscriber`) and sends with the dictation caveat suffix; a quick tap shows "Hold the mic to talk."; sliding off cancels. Haptic on start and on send. VoiceOver: one activation records, the next sends. Also keep the pane app's locked dictation after 2.65 s.
- **@ picker (Phase 5):** the trailing `@query` of the draft (Mac trigger rules: at the start or after whitespace/"(", ≤ 24 chars, no newline) shows a horizontally scrolling strip above the pill: up to 5 features, then the current feature's crew, each as `FirstMateEmojiDisc(24)` + name; tapping inserts `@Name `; at send `FirstMateMention.serializeComposer` turns picks into `herdr://first-mate` links. Only features on one machine can be tagged (the chat's machine).
- **Drafts:** per (machine, feature), in memory for the app's life, with attachments and picks (`FirstMateComposerDraftStore` is macOS-only today; add an iOS equivalent). Not persisted, not synced, same as the Mac.
- **Closed features:** the composer is replaced by the closed line; **no control:** the pill is disabled with the existing "read-only host" reason.

### 2.5 Info screen (the inspector)

A pushed `FirstMateInfoScreen(target)` replaces today's `.large` sheet on iPhone (documents and sessions still open as sheets from it, avoiding sheet-on-sheet nesting). It is the slot Grok Bot uses for its "live screen" button. It wraps the existing iOS `FirstMateInspectorView` (Overview, Agents, Documents, Workflow from the shared `FirstMateInspector`) and restyles it in Phase 6: `HerdrTabs(style: .underline)` (44 pt bar, 2 pt ink underline, 16 pt apart) under the bar, scrolling body with 16 pt padding, and the 36 pt sync footer (`checkmark.circle` "Synced with companion" / `exclamationmark.circle` "Connection needs attention" / "Synthetic data · no agents launched" + "Revision N"). Rules from the Mac: opening a different feature resets the tab to Overview; a file card opens Documents; an agent mention opens Agents with the row highlighted. On iPad it is the trailing inspector column.

### 2.6 My First Mate (the lead) and the briefing fallback

- **Pinned orb:** first in the pinned row, always; `FirstMateFaceOrb(88)`; accent dot when `lead.unread`; caption "My First Mate", and under it "3 need you" in `secondaryText` when something does.
- **Chat, with a lead machine** (a host advertising `first-mate-lead-v1`): a real conversation through the ordinary feature routes on `lead.feature.id`: `POST /lead` once (`ensureFirstMateLead`), then the snapshot and messages like any feature. The composer sends `context` built from the hosts the lead cannot reach itself (`FirstMateLeadMachine.context`: every host not in `peers`, with its non-archived features, marked offline when appropriate); retries reuse the same `request_id` and context. The title pill reads "My First Mate" with the face orb at 24 and the subtitle "3 need you, 3 moving, 1 done"; tapping the pill opens a `Menu` when more than one machine has a lead (Automatic (Machine) ✓ / each machine ✓ when pinned; key `herdr.ios.firstMate.lead.pinned`); "‹Preferred› is offline" in `warning` replaces the subtitle while a stand-in answers.
- **Machine choice** (shared rules, iPhone has no local machine): pinned if still capable → a machine that already has a lead conversation → the busiest (most non-done, non-archived features; roster order breaks ties). Offline = 2 consecutive failed polls (capped at 3); the stand-in is chosen by the same rules over reachable machines; the phone moves back when the preferred machine answers.
- **Chat, without a lead machine** (older companions): the client-built briefing (shared wording in Phase 1; screen in Phases 2–3): a "Today" pill, the **Summary card** ("Built from your features. Not a message from an agent.", `Updated HH:mm`) holding the briefing flow ("Good morning. 3 features need you: 🧾 Receipt export is blocked in QA, …", then "X and Y are moving", "Z shipped yesterday"), the line "Describe a new feature below, and First Mate starts it for you.", and the composer whose send opens the create sheet with the text as the goal ("Add a machine to start a feature." when no host can create).
- **Info screen for the lead:** the Overview only: "Your features at a glance", GOAL micro label, groups Needs you / Moving / Done with count badges, rows (emoji, title, native status label, "Machine · now"), footer "Synced with companion" + "N features".

### 2.7 Capsules, mentions and readouts

- **Capsules** appear in the briefing flow and the lead Summary (inline pills: 20 pt disc + name 14 semibold + 6 pt status dot, height 26, fill `inkFill(0.06)` + tint 11%, edge tint 36%). In messages, mentions are **tinted runs**, as on the Mac.
- **Touch behavior:** tapping a capsule opens its **readout** as a popover (`.popover` + `.presentationCompactAdaptation(.popover)`, 300 pt wide: `FirstMateEmojiDisc(32)`, title 16 semibold, status word 13, the `now` line 15, six 3 pt step bars, "Step n of 6, Name", **Open chat**). Tapping a mention run in a message opens the chat directly (a feature) or the Info screen on Agents with the row highlighted (an agent); long-press shows the readout. This replaces hover.
- **Routing:** in-chat `herdr://first-mate?feature_id=…&assignment_id=…` links use the captured owning machine. External links follow §4.5's exact-origin/unique-owner policy, never the Mac's first-match fallback; assignment ownership is validated before opening Agents.

### 2.8 Text scaling and accessibility

- Dynamic Type: every size above is relative to a text style (see §3.3), capped at `.xxxLarge` by new First Mate chrome now and app-wide in Phase 6. Requests such as accessibility3 resolve to that cap. Layout must still wrap or scroll as needed at the cap, without clipped controls; retain 44 pt targets. The cap does **not** shorten messages or add a transcript line limit. List previews remain deliberately one-line summaries; opening a chat exposes the full message.
- Passive OS fallbacks remain: the existing breathing and face primitives stop animating under Reduce Motion; glass becomes opaque `base` under Reduce Transparency without discarding preferences. Existing typing/mic fallback behavior should be preserved when those components are reused. This support is not a separate delivery work item or reduction-settings release matrix.
- VoiceOver: labels as in §2.2; capsule "Title, Status. Opens its readout."; the dot is never announced alone; the typing row "First Mate is working on a reply"; the mic "Hold to talk" with the two-activation fallback; inline action buttons read as "Reply: Ship iPhone-only".
- Landscape iPhone: the same stack; the pinned row shrinks its orbs to 64 pt; the composer keeps its 44 pt targets.

---

## 3. Theme port: Mono × Herdr dusk glass on iOS

### 3.1 Historical theme comparison (before Phase 0)

| | Mac (origin/main) | iOS (origin/main) |
|---|---|---|
| Token file | `herdr-harness-mac/.../Design/HerdrTheme.swift` (490 lines): two-color generator (`base` #151519, `foreground` #E9E9EC), ink-alpha fills/lines, opaque composited text levels, lavender accent, pastel status, Radius/ControlHeight/TextSize ramps, `Glass` levels | `herdr-harness-ios/.../Design/HerdrTheme.swift` (52 lines): fixed charcoal palette (`ink` #191A23, `graphite` #20212C, `elevated` #292B39, `surface` #353747, `text` #E4E5ED, `mist`, `muted`), accent #AAA6F4, same pastel status colors, `attention` #FF9F0A |
| Backdrop | `HerdrGlass.swift`: `HerdrDusk` (640×400 cached CGImage: sky gradient #2A1D4A → #171A36 @55% → #0F1226, four radial glows, Gaussian blur σ=24·w/1336, saturation 1.1, then ×0.80 brightness), `HerdrHazeBand` (480×180, three blobs, σ=18, drawn at 6% with a top-to-bottom mask, 280 pt tall), `HerdrGlassBackground(level:)` = darkened `base` at 0.80 over the dusk | `HerdrBackground` = flat `HerdrTheme.ink`; `GlassCard` = flat graphite + 1 pt surface outline. No dusk, no haze, no glass |
| Recipes | `HerdrRecipes.swift`: `herdrCard`, `herdrField`, `herdrHairline`, `herdrRowBackground`, `herdrPill`, `HerdrMicroLabel`, `HerdrCountBadge`, `HerdrTabs` (segments/underline), `HerdrIconButtonStyle`, `HerdrButtonStyle` (primary/outline/ghost), `HerdrPrimarySquareButtonStyle`, `.herdrPlain` | none of these; views style ad hoc |
| Fonts | `herdrFont(.style)` → MonoCode ramp (10/11/12/13/14/18) × `HerdrFontScale`; `HerdrProse` 14/24 body, 18/26 headings | `HerdrProse` on Dynamic Type anchors (body 15, headings 20/17/15…), Inter bundled but chat prose is system |
| Appearance | dark only in practice; `.preferredColorScheme(.dark)` on new windows; glass/haze toggles `herdr.mac.appearance.glass` / `.haze`, Reduce Transparency wins | `FirstMateAppearance` offers System/Light/Dark for the First Mate tab; rest follows system |

### 3.2 What to build on iOS (Phase 0)

All new files go under `herdr-harness-ios/herdr-harness-ios/Design/` (folder references, no pbxproj edits).

1. **`HerdrTheme.swift` rewrite: the Mono generator, dark only.** Port the Mac's roles with fixed dark values (no adaptive providers, no light branch, no Increase Contrast switch beyond `colorSchemeContrast` for the 16% rules):
   - generator: `base` #151519, `foreground` #E9E9EC, `inkFill(α)` (translucent), `inkSolid(α)` (composited over base);
   - surfaces: `windowBackground` = base, `railBackground` #131317;
   - fills: `cardFill` .03, `fieldFill` .04, `insetFill` .05, `hoverFill` .05 (generic control press), `codeFill` .06, `chipFill` .08, `selectedFill` .10; iOS `rowHighlightFill` aliases `codeFill` for both selected and pressed rows;
   - lines: `hairline` .07, `rowDivider` .05, `outline` .10, `strongOutline` .15, `focusOutline` .20 (all .16 when `colorSchemeContrast == .increased`);
   - text: `primaryText`, `proseText` (78%), `secondaryText` (70%), `tertiaryText` (70%), `iconTint` (50%);
   - accent and actions: `accent` #AAA6F4, `primaryAction`, `onPrimary` (= base), `primaryDisabled` (.28), `controlAccent` #5E59A8, `badgeFill`, `onBadge`, `attentionBadge` #FF9F0A (keep `attention` as an alias for the iOS skim code), `firstMateAvatarFill` #2A2244, `folder` #B9A7DF, `brandBlue` #A6BAFF;
   - status: `signal` #9CCDB9, `success` #A3CBA7, `working` #E4C386, `alert` #E2A7B6, `warning` #DFB38E; diff and `Syntax` palettes as on the Mac;
   - **aliases** so every existing iOS view compiles and moves onto the new palette without edits: `ink` → `railBackground`, `graphite` → `windowBackground`, `elevated` → `inkSolid(.03)`, `input` → `inkSolid(.04)`, `surface`/`selection` → `inkSolid(.10)`, `separator` → `outline`, `subtleSeparator` → `hairline`, `text` → `primaryText`, `mist` → `secondaryText`, `muted` → `tertiaryText`, `mauve` → `folder`, `code` → `primaryText`, `crust` → black 22% over base, `diffAdd/diffRemove/diffHunk` → the Mac values;
   - sizes: `Radius` (control 6, composer 8, row 10, card 12, panel 16, plus `bubble` 18 and `pill` 24 for the chat), `ControlHeight` (mini 20 … bar 44 on iOS), `Glass` (sidebar .80, pane .80, hud .78), `minHitTarget` **44**, and the type ramp in §3.3. The old `cardRadius` 16 / `compactRadius` 10 / `pagePadding` 18 stay as aliases for the untouched tabs.
2. **`HerdrGlass.swift` port.** The dusk and haze artwork render identically with `CGContext` + Core Image (both available on iOS): `HerdrDusk.sky/glows/blurSigma/saturation`, `HerdrHaze.base/blobs`, the one-time ×0.80 brightness (`herdrDarkened`), cached as `UIImage` (`@MainActor static let`). `HerdrDuskBackdrop(region:)` becomes `Image(uiImage:)` `.resizable().interpolation(.high)`; `HerdrGlassBackground(level:base:cornerRadius:drawsDusk:)`, `HerdrHazeBand(height: 280)` at 6%, `herdrPaneBackground()` and the environment keys `herdrGlassActive` / `herdrHazeActive` port as they are. `HerdrGlass.isActive(enabled:reduceTransparency:colorScheme:)` reads `@Environment(\.accessibilityReduceTransparency)`. Preferences: `herdr.ios.appearance.glass` and `.haze`, both default on, exposed in Settings → Appearance. **No live blur anywhere** (`glassEffect` is not used on custom surfaces; the system bars keep their own Liquid Glass).
   - One `HerdrDuskBackdrop` is drawn once per screen behind the glass levels (not per row); the artwork is 640×400 and stretched, exactly as the Mac does. On an iPhone the trailing-half crop is not needed.
3. **`HerdrRecipes.swift` port** with touch defaults: `herdrCard`, `herdrPanel`, `herdrField(focused:)`, `herdrPlaceholder`, `herdrHairline(edge)`, `herdrRowBackground(selected:pressed:)` (no hover), `herdrPill`, `HerdrMicroLabel`, `HerdrCountBadge`, `HerdrTabs` (segments/underline, 44 pt tall), `HerdrIconButtonStyle` (glyph box 28–32 in a 44 hit area, pressed fill instead of hover), `HerdrButtonStyle` (primary/outline/ghost, height 36/44), `HerdrPrimarySquareButtonStyle`, `HerdrRowButtonStyle`, `.herdrPlain` (iOS `.plain` has no press fade, but the name keeps call sites identical across platforms).
4. **Fonts.** `herdrFont(size:weight:monospaced:relativeTo:)` scales through `UIFontMetrics(forTextStyle:)`; `herdrFont(_ style:)` maps to the iOS ramp below. `HerdrProse` adds `.bubble` (16/22) and keeps existing roles; Inter stays bundled but unused (system SF, like the Mac). `HerdrTheme.maximumDynamicTypeSize` is `.xxxLarge`, applied at the new chrome boundary so metric fonts, semantic prose and inline code resolve consistently in UIKit-hosted Markdown. Existing screens remain uncapped until Phase 6.
5. **Backgrounds.** `HerdrBackground` keeps drawing opaque `ink` for existing screens in Phase 0. `HerdrFirstMateChromeModifier` draws one dusk, sets glass/haze environments, forces dark and caps Dynamic Type. Phase 2 adopts it on the conversations screen, client-built briefing and create/archive sheets; the retained First Mate navigation/detail also inherits the text cap. Phase 6 moves the dusk and text-scaling cap under the whole `TabView` after the other tabs pass the contrast sweep.
6. **Avatars.** `FirstMateEmojiDisc` and `FirstMateFaceOrb` / `FirstMateFace` / `FirstMateBlinkSchedule` live in `Views/FirstMateChat/` (highlight, edge and glow numbers in `research/mac-chat-window.md` §8). The iOS face uses a cached 31-frame Core Graphics raster bank; SwiftUI controls blink timing. Live simulator glyph coverage supplements offscreen renders.

### 3.3 Type ramp: Mac → iPhone

The Mac ramp is compact (body 13); the iPhone ramp follows iOS reading sizes and Dynamic Type up to `.xxxLarge` in new First Mate chrome. Every value is "at 100%" and relative to the text style in the last column. The cap limits scale only; prose remains complete and scrollable.

| Use | Mac | iPhone | Relative to |
|---|---|---|---|
| micro labels (GOAL, counts) | 10 semibold | 11 semibold, tracking 0.6 | caption2 |
| meta line, time in bubbles | 10 | 11 | caption2 |
| caption (speaker line, day pill, section label) | 11 | 12–13 | caption / footnote |
| status word, header subtitle, hints | 11.5 / 10.5 | 13 / 12 | footnote |
| row preview, readout "now", capsule name | 12 | 15 / 15 / 14 | subheadline |
| row name, header title, readout title | 13.5 / 14.5 / 13 | 16 semibold | callout |
| bubble text, composer text, briefing | 13.5 (line spacing 3.5) | 16 (line spacing 4–5) | body |
| prose in bubbles (`HerdrProse.bubble`) | 14/24 | 16/22 | body |
| inspector heading | 15 semibold | 17 semibold | headline |
| screen title | — | large navigation title | largeTitle |

### 3.4 Application order

Phase 0 lands the tokens, glass and recipes, plus Settings → Appearance and a DEBUG theme sample, with **no layout change** to existing screens beyond the alias remap (base shifts from #191A23 to #151519; text from #E4E5ED to #E9E9EC). The First Mates tab is the first surface drawn on the dusk (Phases 2–5). Phase 6 puts the dusk under the whole app and sweeps the Agents, Attention, Notes and Settings tabs, using the Mac's lesson: check every translucent stack and transient state (pressed, selected, disabled, menu open) over the dusk's brightest point.

### 3.5 Contrast and tests

- Port `HerdrThemeAccessibilityTests` to iOS: render the cached dusk, find its brightest point under the pane glass (base at 0.80 × 0.80 brightness), and assert 4.5:1 for `primaryText`, `proseText`, `secondaryText`, `tertiaryText`, every status color used as text, the breathing label at its floor (0.75), capsule names on their tints, and the suggested-reply chip text. The artwork and numbers are the Mac's, so the results should match; the test protects the port from drifting.
- Pin the dusk and haze bitmaps with a hash test (the Mac pins `baselineImage`), so a Core Image difference on iOS shows up as a test failure rather than a subtly different purple.
- Render tests draw over the glass rather than the flat ink fill: `IOSNativeRenderHarness` gets a `background: .dusk | .ink` option (default stays `ink` for existing tests).

---

## 4. Architecture and data flow on iOS

### 4.1 Share the logic, port the views

The Mac window's pure rules move into `HerdrFirstMateShared/` (compiled into both apps as source; anything there must build on both platforms, `#if os(macOS)` where a platform type leaks in). The Mac views keep calling the same names, so the Mac's behavior and its tests do not change. The iPhone gets one source of truth for every rule the user will compare between the two apps (dots, badge, order, previews, times, briefing wording).

| Moves to shared (new file name) | From (Mac) | Notes |
|---|---|---|
| `FirstMateFleetHost`, `FirstMateFleetFeatureID`, `FirstMateFleetSource` | `FirstMateFleetIndex.swift:10-40`, `FirstMateMachineScope.swift:13-16` | plain data; `FirstMateFleetSource` uses `HerdrMachine` + `ServerConfiguration`, which both apps define |
| `FirstMateFleetIndex` (polling, capability probing, read marking with rollback and backoff, `badgeCount`, `attentionCount`, change filtering) | `FirstMateFleetIndex.swift` | keep the Mac driver (`FirstMateFleetDriver`, NSApplication) in the Mac target; iOS gets its own `scenePhase` driver |
| `FirstMateReadState`, `FirstMateBadge` | `ChatWindow/FirstMateReadState.swift`, `FirstMateBadge.swift` | pure |
| `FirstMateConversation`, `FirstMateConversationList`, `FirstMateChatPreview` | `ChatWindow/FirstMateConversation.swift` | pure; the Markdown-to-one-line rules included |
| `FirstMateChatTime` | `ChatWindow/FirstMateChatTime.swift` | pure |
| `FirstMateLeadBriefing` (text and segments) | `ChatWindow/FirstMateLeadBriefing.swift` | the flow layout view stays per platform |
| `FirstMateTranscriptLayout`, `FirstMateMessageDisplay` | Pure declarations from `ChatWindow/FirstMateChatTranscript.swift` | Includes current optimistic outgoing ordering, partial-reply and send-resolution rules; no view moves |
| `FirstMateMentionCatalog`, `FirstMateMentionLinker`, `FirstMateCrewStyle` (emoji + status mapping) | `ChatWindow/FirstMateMentionLinker.swift` | Preserve SwiftUI/AttributedString styling and target-local `HerdrTheme`; not a Foundation-only rewrite |
| `FirstMateMentionTrigger`, `FirstMateMentionOption` | `ChatWindow/FirstMateMentionPicker.swift:5-…` | the picker view stays per platform |
| `FirstMateLeadMachine` (choice, offline stand-in, `context`) | `FirstMateLeadMachine.swift` | `choose(...local:)` already accepts nil. Mac preference/local-host wrapper stays in `FirstMateLeadMachine+Mac.swift`; phone choice passes nil and owns its pin key |
| `FirstMateChatStatusStyle` | Pure enum in `ChatWindow/FirstMateChatPrimitives.swift` | Whole enum retained, including target-local theme colors; `FirstMateChatSteps` was already shared |
| `FirstMateAttention` | `FirstMate/FirstMateAttention.swift` | Required dependency of index attention counting |
| `FirstMateCoordinatorContextPresentation` | Same-named Mac file | Foundation-only presentation and corresponding parity tests |
| `HerdrMachine.normalizedOrigin` | Mac machine model | Unchanged method in shared `HerdrMachineOrigin.swift`; platform machine models stay separate |
| `FirstMateOpenRequest` | Mac request parser declaration | Strict Mac external grammar unchanged; its navigation identity stays Mac-local |
| `FirstMateChatDemoProjection` | Mac session's `demoHost` projection | Shared projection with explicit machine ID/name; Mac session keeps a thin forwarder and its app-owned demo source |

Stays per platform: every SwiftUI view (hover vs touch, `NSPasteboard` vs `UIPasteboard`, window chrome vs navigation), the fleet driver, the Dock badge, `FirstMateComposerDraftStore` (add an iOS twin), `SkimmableReply` (each app has its own).

Move tests with the code: conversation, badge, attention, read state/fleet/backoff, briefing/time, lead/store/context, transcript/partial-reply, mention and trigger cases now live in `HerdrFirstMateSharedTests/*`. Platform-specific pinning/sidebar/mic/readout assertions remain in Mac extensions, with distinct `+Mac` filenames to avoid Xcode output collisions. Shared synthetic helpers retain current send/ensure gates and request-ID recording; only Mac app/shell constructors remain local. Existing outgoing tests remain shared. Platform-neutral lifecycle/model-proposal/context and HTTP attachment/link cases are deliberately enabled on iOS; genuinely Mac-only quote/composer cases remain guarded. Mac window/session/shell/render tests stay local.

### 4.2 iOS stores

- **`FirstMateFleetIndex` (shared) + `FirstMateFleetDriver` (iOS).** One app-active summary loop polls every 10 s, independent of selected tab; suspension cancels it and foregrounding refreshes immediately. A second structured child loop refreshes only the selected store every 3 s while its chat is visible, 60 s otherwise, waking when selection/visibility changes. Demo never networks. Initial refresh populates existing inspector/capability mirrors once; the former all-host observer is not also run. Visible archive browsing explicitly keeps its full-list host-store path because the active shared projection excludes archives.
- **`FirstMateMobileFleetStore` + `FirstMateMobileChatState`.** The fleet remains the sole owner of each machine's store, scope, create/archive paths and conversation list. Its chat state wraps the shared index, cached conversation projection, phone-owned optimistic feature/lead reads and backoff, feature-only global badge, lead choice/pin/context, and machine-qualified selection/navigation (`FirstMateChatRoute`). Scope/search/lead unread do not alter the badge. Older list-only hosts retain attention dots, not invented read-marker capability. Phone read and lead/assignment-loading callbacks are fenced to connection and target; a late reply cannot clear a newer unread marker or select over a newer feature. `didMutate` refreshes the global projection after local mutations. Existing mobile tests remain in place.
- **Store/control ownership.** Keep existing `OperationContext` and store retirement. The shared store only exposes its journal capability read-only for exact-host fetches; no Mac behavior changes. The mobile detail owns a `FirstMateWorkspaceControlLease`, updates it for the selected host's actual control state, and releases it with stale-cleanup fencing. Future feedback/model/link UI must use this lease and include pending outgoing submissions in enablement. New Phase 3 sends use the frozen optimistic API above, not async-clear-after-send.

### 4.3 Client gaps (`Infrastructure/HerdrAPIClient.swift`)

Phase 1 implements concrete protocol witnesses for lead fetch/ensure, context-bearing send, feature attachment upload, First Mate voice transcription, journal-only feature fetch, and link save/visibility. Attachment JSON remains `{filename, content_type, data_base64}`; decoding accepts both feature camelCase and workspace snake_case, while workspace encoding stays unchanged. Resource IDs cannot escape endpoint paths; requests keep the exact host bearer token.

**Timeout correction:** normal First Mate POSTs use the shipped long-running **86,400 s** mutation budget, not the original plan's 30 s. Feature uploads explicitly use **90 s before** that broad rule; voice uses **120 s**; First Mate reads use **15 s**, including IDs ending in `events`. Mac timeout behavior is unchanged. Tests call through `any FirstMateClient` to verify dispatch, bodies and actual request timeouts.

`APIError.server` keeps its two-value status catch shape. The iOS message envelope additively retains `text` and optional `code`, exposed as `serverCode`; existing unsupported/conflict/outgoing status classification still matches the same case. Shared stores primarily branch on HTTP status, not all named codes as the original plan claimed. `FirstMateLeadSummary.machine` decodes absent/null/present metadata but never replaces the phone's saved owner ID, URL or credentials. No board polling is added; journal snapshots retain complete inspector data.

### 4.4 Polling and freshness

| Loop | iPhone | Mac | Notes |
|---|---|---|---|
| Fleet index (`GET /features` + probe + `GET /lead` + `GET /fleet`, per host in parallel) | 10 s while active; paused in background; immediate on foreground | 10 s / 30 s | starts at launch; publishes only real changes |
| Selected store (`capabilities`, `GET /features`, `GET /features/{id}?events=journal`) | 3 s while a chat screen is on top; 60 s otherwise | 2 s / 60 s | measure payload size on real features; switch the transcript to `/board?if_version=` if a snapshot exceeds ~150 KB |
| Capability re-probe of an unsupported host | 5 min | 5 min | shared |
| Read marker retry | 8 s doubling to 180 s | same | shared |
| Lead poll | inside the index | same | 2 failed polls = offline |

No SSE and no push until Phase 7; the `first_mate.updated` event is not useful (it fires only on the client's own mutations).

### 4.5 Deep links and routing

`FirstMateMobileOpenRequest` additively parses `herdr://first-mate?feature_id=…[&assignment_id=…][&server_url=…]` and `/lead`, while shared `FirstMateOpenRequest` preserves the Mac's strict external grammar. Reject duplicate/unknown/security-bearing fields, credentials, fragments and invalid IDs. A supplied normalized origin must match exactly one configured machine; unknown or ambiguous origins fail **without fallback**. An unqualified in-chat link uses its captured owner; otherwise require one uniquely listed owner or an explicit machine choice, never roster order or display labels. Server-provided lead metadata is not identity.

Phase 1 routes validated targets into the existing workspace/detail, carries assignment IDs in the info route, validates assignment ownership before opening Agents, and retains pane/car routing. Phase 3 pushes Info and expands/highlights validated assignments. Mention/capsule taps use the captured-owner adapter; retained readouts lose authority after newer navigation or owner replacement. Navigation never sends a prompt or changes credentials; opening a supported lead may ensure its empty conversation only with control on that exact host.

### 4.6 Demo mode

`-HerdrDemoMode -HerdrFirstMateDemo` now seeds `demo1` "desktop" with the chat-window fleet, seven feature snapshots and the lead. Legacy synthetic snapshots/identifiers are retained through the list/detail transition so existing automation and retained chat flows stay testable. `demo2` "laptop" keeps `features(step:)` plus `demo2-release-checklist`. The shared projection incorporates each store's latest local messages. Reads and sends remain local demo operations; no agents or network requests run. The list's "Next scenario" advances `demo2`. Keep every fixture synthetic.

### 4.7 File map

New iOS files (`herdr-harness-ios/herdr-harness-ios/`):

```
Design/HerdrTheme.swift               rewritten (Mono generator, dark only, aliases)
Design/HerdrGlass.swift               new (dusk, haze, glass backgrounds, environment keys)
Design/HerdrRecipes.swift             new (cards, fields, hairlines, tabs, buttons, badges)
Design/HerdrFontModifier.swift        new (herdrFont(size:relativeTo:) via UIFontMetrics)
Design/HerdrAppearancePreferences.swift  new (glass / haze keys)
FirstMate/FirstMateFleetDriver.swift  new (scenePhase-driven index polling)
FirstMate/FirstMateMobileFleetStore.swift  extended (hosts from the index, read state, badge, selection, path, lead machine)
FirstMate/FirstMateChatRoute.swift    new (machine-qualified navigation routes)
FirstMate/FirstMateMobileChatState.swift  new (phone read/lead fencing, selection and route adapter)
FirstMate/FirstMateMobileOpenRequest.swift new (additive strict phone parser and owner resolution)
FirstMate/FirstMateComposerDraftStore.swift  new (iOS twin)
Views/FirstMateChat/FirstMateConversationsScreen.swift   list, search, empty states, toolbar
Views/FirstMateChat/FirstMateConversationRow.swift       row chrome, feature row, lead row, status word
Views/FirstMateChat/FirstMateChatScreen.swift            nav bar, transcript, notices, composer host
Views/FirstMateChat/FirstMateChatTranscriptView.swift    grouped bubbles, day pills, typing, file cards
Views/FirstMateChat/FirstMateChatBubbleView.swift        bubble shapes, meta line, context menu
Views/FirstMateChat/FirstMateMessageComposer.swift       pill, hint row, hold-to-talk, @ strip, accessories
Views/FirstMateChat/FirstMateSuggestedReplies.swift
Views/FirstMateChat/FirstMateCapsuleView.swift           capsule, readout popover, briefing flow
Views/FirstMateChat/FirstMateLeadBriefingView.swift      summary card + fallback screen
Views/FirstMateChat/FirstMateLeadOverviewView.swift
Views/FirstMateChat/FirstMateInfoScreen.swift            pushed inspector host
Views/FirstMateChat/FirstMateAvatars.swift               emoji disc, face orb, blink schedule
Views/FirstMateChat/FirstMateChatChrome.swift            HerdrFirstMateChromeModifier
```

Changed iOS files: `Views/Root/AppRootView.swift` (tab root, badge, driver start), `App/HerdrHarnessApp.swift` (drop the First Mate appearance switch), `State/HerdrAppModel.swift` (router, session ownership), `Infrastructure/HerdrAPIClient.swift` (§4.3), `Models/WorkspaceToolModels.swift` (`UploadedAttachment` camelCase), `Views/FirstMate/FirstMateInspectorView.swift` and the resource sheets (Phase 6 restyle), `Views/FirstMate/FirstMateCreateSheet.swift` and the archive sheet (restyle), `Views/Settings/SettingsView.swift` (Appearance section), the tests listed per phase, `herdr-harness-ios/README.md`, `docs/first-mate/ios.md`, `README.md` (First Mate section). Phase 2 replaces the old list/card/appearance and adapts the workspace root after extracting a reusable archive sheet with a captured store/operation context. Phase 3 installs `FirstMateChatScreen`, `FirstMateChatTranscript`, `FirstMateChatBubble`, `FirstMateMessageComposer`, `FirstMateInfoScreen` and capsule/readout views. The old detail/chat/message/composer and inspector-sheet host are removed only after replacement workflow/resource UI checks; needed inspector/status/resource content remains.

Shared folder (`HerdrFirstMateShared/`): the files in §4.1 plus `FirstMateLeadSummary.machine`; Mac target: delete the moved originals, keep the views.

---

## 5. Phases

Each phase is one branch and one PR from the latest `origin/main`, landed after Verify, with the Mac app built and its First Mate tests run whenever shared files move. Sizes are relative (S < M < L).

### Phase 0: Theme foundation (M) — implemented
- **Built:** §3.2 items 1–6; Settings → Appearance with Glass and Haze toggles; the render harness `.dusk` background option; `HerdrProse.bubble`; cached face frames; quiet 6% selected/pressed row fill with a 10 pt radius; `.xxxLarge` cap on new First Mate chrome.
- **Kept:** existing iOS screen layouts and opaque backgrounds through the palette aliases; the legacy appearance menu remains until Phase 2. No Mac/shared/server changes.
- **Tests:** iOS `HerdrThemeAccessibilityTests` (4.5:1 over the brightest dusk point for every text level, status colors, breathing floor 0.75), dusk/haze bitmap pins, live glyph coverage, and `theme-dusk-sample` renders at 390/402 pt. UIKit-hosted tests compare UIFontMetrics and `HerdrProse` Markdown at `.xxxLarge` and an accessibility3 request; long messages remain fully laid out. UI tests check the effective cap, reachable controls and 44 pt hit targets.
- **Done when:** the iOS unit target is green, the sample render matches the Mac's look on screen (check on a simulator, not only the PNG), and the other tabs look the same as before apart from the deeper base.

### Phase 1: Shared logic and the iOS data layer (L) — implemented
- **Built:** the §4.1 moves (Mac first: move, build, run the Mac First Mate tests); the shared tests; iOS `HerdrAPIClient` gaps (§4.3); `FirstMateLeadSummary.machine`; `FirstMateFleetDriver`; `FirstMateMobileFleetStore` extended with hosts, read state, badge, selection, path, lead machine and the selected-store loop; the deep-link router (§4.5); demo wiring (§4.6); the tab badge (visible already, on the old list).
- **Tests (Swift Testing, fake `FirstMateClient` actors):** index polling per host and failure retention; read marking optimistic + rollback + backoff; badge across two demo hosts; lead choice without a local machine (pinned → existing → busiest; offline stand-in; return); deep-link resolution by `server_url` origin and by feature listing; client decoding (lead summary with `machine`, attachment camelCase, journal-only query); driver pause/resume on `scenePhase`.
- **Done when:** both CI jobs are green, the Mac app's chat window behaves exactly as before (existing assertions survive the moves and focused Mac regressions run before iOS behavior edits), and the old iOS list shows the global feature badge while other tabs keep the app-active fleet fresh. Phase 1 does not claim the Phase 2 list or Phase 3/4 chat UI.

### Phase 2: Conversations screen (M) — implemented
- **Built:** §2.2 compact host/search/new/More bar, 88pt lead/needs-you strip (64pt landscape), six features plus overflow, and 52pt two-line recency rows. The pinned lead opens an explicitly client-built briefing until real lead chat in Phase 4. New create/archive sheets use the recipes, exact owner/context capture, 44pt controls and capped text. Archive removal is optimistic with rollback; archived browsing/unarchive stays on host stores. Old list/card/appearance files are removed; existing detail/chat/Info helpers remain for later replacement.
- **Shared presentation:** honor `FirstMateConversation.name` and emoji provenance without adding a phone editor. Reuse `FirstMateReplyProgress` rather than copying heuristics; local pending/snapshot changes are read outside the fleet-row cache, and list/pins/preview/global badge agree. Preserve presentedDocuments filtering in reused detail/Info flows.
- **Tests:** native list/row renders at 320/375/402/430 and accessibility3 requests capped to `.xxxLarge`, control/label geometry and 44pt assertions, phone urgency/activity pin order and six-plus-overflow, composite IDs, name/title/preview/host/goal/ticket search, lead visibility, progress/cache/badge transitions, archive rollback/unarchive and stale sheet ownership. UI demo covers host scope, lead briefing/back, Receipt export's retained chat/back, search, capped create/archive and explicit destination behavior.
- **Performance evidence:** DEBUG-only `-HerdrFirstMateListPerformance` with demo mode supplies 100 synthetic rows; the real lazy List is observed through non-observing body/visibility counters and a scroll-to-end UI test. Report actual counts/gesture time, not an inferred FPS. Per-phase review/automated gates remain required.

### Phase 3: Chat screen for second mates (L) — implemented
- **Built:** §2.3 (the glass bar with the title pill and circles, avatar-less First Mate bubbles, inline action buttons, cards as bubbles); composer v1 (＋ circle, pill, text, send, drafts, closed state, hint row, haptics); read markers; the Info screen as a pushed host for the existing inspector (unstyled until Phase 6); the briefing fallback screen with the capsule flow and readout popover; `SkimmableReply(style: .bubble)`; mention runs from the shared linker; copy via long-press.
- **Tests:** shared transcript and mention tests already cover the rules; iOS: renders `fmchat-ios-chat-receipts`, `-lead-briefing`, `-composer-{idle,focused,closed}`, `-readout`; read-key gating with `scenePhase`; suggested replies only from skim `reply` blocks; UI tests: send in demo moves the row to the top; tap a file card opens Documents; tap a capsule opens the readout and "Open chat" navigates.
- **Verification:** `FirstMateReadHostTests` mounts the actual read-tracking chat with cancellation-aware held clients and an injected retry clock: delayed/failed selected fetch, equal-height content, real scrolling, optimistic transport lifetime, coverage/scene/tab/source changes, collapsed responses and retries through unchanged polls. `FirstMateMobileTranscriptTests` covers reservation/detachment, explicit frozen retry, observed-content/projection gates, readout supersession, exact-owner/ambiguous mention catalogs and authoritative resource association (explicit PR provenance before unique URL-only fallback). Existing shared conversation/mention/outgoing, mobile read rollback/backoff/new-reply and navigation/lifecycle suites remain. Native renders cover 320/402pt and accessibility3 requests capped at xxxLarge; actual controls and complete long messages are inspected. UI tests cover send, pushed Info/file→Documents, native swipe-back, capsule/readout/Open chat and cancelled creation draft retention. The DEBUG-only 200-message fixture records lazy body/visibility counts, complete-history reachability and gesture/settling duration—not full-FPS proof. Real companion/device acceptance is collected with the final Phase 6 Mobile App Hub build, not an intermediate phone-test gate.

### Phase 4: My First Mate (M)
- **Build:** §2.6: `openLead`, the lead chat on the same transcript and composer, `FirstMateLeadMachine` wiring with the header machine menu and the offline warning, the lead context provider, lead read marking, the lead Overview in the Info screen, the lead in demo (`chatWindowLead`).
- **Tests:** session tests for choice/failover/return and context contents (hosts not in `peers`, offline flags); render `fmchat-ios-chat-lead` and `fmchat-ios-info-lead`. Retain the final-device acceptance case: send one lead turn against a configured companion and confirm `fm_fleet` reaches the other companion through peers, using the final Phase 6 build.
- **Done when:** automated two-host coverage proves My First Mate opens on the preferred machine, survives one machine going offline, and falls back to the briefing without `first-mate-lead-v1`; repeat those observable outcomes on the final device build.

### Phase 5: Composer parity (M)
- **Build:** attachments (Photos, Files, paste code; upload on the feature's machine; tray; "Attachment:" lines), hold-to-talk with waveform and transcription on the feature's machine plus the Apple fallback, the model + thinking pill (`/first-mate/models`, `model-settings`, host default, confirmation dialog, "Update server for safe model changes"), the context line and sheet, the @ picker strip and serialization, Rate up / Rate down via the feedback routes (port `FirstMateFeedbackControls` and the editor as a sheet) shown as 👍/👎 reaction badges on the bubble.
- **Tests:** submission composition (attachment lines, dictation suffix, mention links), trigger cases (shared), model pill enablement matrix (control, context match, owner, queued, sending), renders `fmchat-ios-composer-{attachments,listening,model}`; UI test hold-to-talk in demo (canned transcript) sends with the caveat.
- **Done when:** automated composition and capability coverage verifies everything the Mac's shared composer does except quotes and drag-and-drop. Live companion/device confirmation belongs to the final build, without a Phase 5 phone-test pause.

### Phase 6: Info restyle, iPad, app-wide dusk, polish (M)
- **Build:** the Info screen per §2.5 (underline tabs, footer, restyled documents and sessions sheets, Agents row highlight); iPad `NavigationSplitView` with the inspector column; the dusk under the whole `TabView` with the contrast sweep of Agents, Attention, Notes, Settings (and `GlassCard` → `herdrCard`); apply the `.xxxLarge` text-scaling cap app-wide while keeping complete messages scrollable; preserve passive OS reduction fallbacks without separate gates; VoiceOver pass; optional `/board?if_version=` transcript polling; the widget palette left as is (out of scope, noted).
- **Tests:** renders for each Info tab, iPad 1024 and 1366 renders, the contrast test extended to the other tabs' fills; UI tests on an iPad simulator for the three columns.
- **Done when:** every tab reads at 4.5:1 over the dusk, the iPad layout matches the Mac window's three columns, and accessibility3 requests resolve to `.xxxLarge` app-wide with no clipped controls, at least 44 pt targets, and fully readable/scrollable message content.

### Phase 7: Deferred future scope — freshness: app badge, background refresh, push (M)

Not authorized or implemented in this Phases 0–6 delivery. Retained below as future design only; it would require separate authorization and a companion release.
- **iOS:** `UIBackgroundModes: fetch`, `BGTaskSchedulerPermittedIdentifiers` and a `BGAppRefreshTask` (`org.herdr.companion.ios.firstMate.refresh`, earliest 15 min) that runs one index poll and sets `UNUserNotificationCenter.setBadgeCount(badgeCount)`; the app icon badge follows the First Mate count when the new setting "Show First Mate count on the app icon" is on (default on, mirroring the Mac's Dock badge that takes over from alerts); notification tap → the deep-link router; foreground banner.
- **Server (`first-mate-push-v1`):** on a needs-you transition (`hud_status` becomes blocked, turn or ready, or the lead gets a reply), send one APNs alert per feature per transition after the same 60 s unread grace pane alerts use (`unread_notifications.py`), payload `{feature_id, machine_id, hud_status, badge}` plus `content-available: 1`; reuse the existing APNs configuration (`HERDR_APNS_*`), device registry and `/push/status`. Document setup; older phones ignore it. Publish as a companion package with its own release notes; the Mac app is unaffected.
- **Tests:** server route and notifier tests in `tests/`; iOS badge composition and refresh task scheduling; a device check that a blocked demo feature on a configured companion produces a banner and the badge.
- **Done when:** the icon badge is right within 15 minutes without opening the app, and immediately on a push.

---

## 6. Verification and delivery

**While building (every phase).**
- iOS: `xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj -scheme herdr-harness-ios -destination 'platform=iOS Simulator,id=<udid>' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test -only-testing:herdr-harness-iosTests/<Suite>` for the touched suites (Xcode 26.2 and an iOS 26 iPhone 17 simulator are installed on the reference development Mac; a full simulator build of `30627dc` took under three minutes here).
- Mac, whenever `HerdrFirstMateShared/` changes: `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` and the First Mate test suites (`FirstMateChatConversationTests`, `FirstMateChatWindowSessionTests`, `FirstMateConversationListTests`, `FirstMateBadgeTests`, `FirstMateReadStateTests`, `FirstMateLeadTests`, `FirstMateFleetIndexTests`, `FirstMateHudTests`, `HerdrThemeAccessibilityTests`).
- Renders: set `HERDR_IOS_RENDER_DIR` and look at the PNGs; then check the same screen on a simulator, because offscreen renders cannot show the system bars' glass over the dusk.
- Simulator QA, the way this plan's captures were made: build, `xcrun simctl install`, `xcrun simctl launch <udid> org.herdr.companion.ios -HerdrDemoMode -HerdrFirstMateDemo`, `xcrun simctl io <udid> screenshot`. Walk the list, the lead, a blocked feature, the readout, each Info tab, the composer states, and an accessibility3 request resolving to the `.xxxLarge` cap (new chrome now, app-wide in Phase 6). Preserve passive OS fallbacks; do not add a separate reduction-settings matrix.
- `.venv/bin/python scripts/check-public-source.py` before every commit. No AI attribution lines in commits.

**Once per reviewed candidate.** Required exact-source Verify on the pushed branch remains the authoritative full automated matrix (including iOS/Mac unit targets according to `scripts/ci-plan.py`). Run focused local regressions and a targeted build while implementing; additionally build Mac and run its First Mate tests whenever shared files move. Do not duplicate unchanged full suites by habit. Source corrections need fresh relevant checks and required exact-SHA Verify evidence. Preserve independent review, privacy and authentication checks. Land with `scripts/land-pr.py` only after the required gates pass. There is no first-push approval gate or per-phase push-permission pause.

**One final phone delivery.** After Phases 0–6 are complete, build one signed device `.ipa` from the reviewed, verified, landed source and publish through Mobile App Hub. The delivery owner sets `release/ios.json` version/build and final release notes then, not during Phase 0 refinements. No intermediate signed builds or per-phase device-test pauses are required. Collect final device acceptance for list/chat, lead failover and fallback, attachments/voice/model controls, and Info/iPad/app-wide appearance; test against two configured companions with fleet, lead and peers support. This does not authorize server mutation. No Mac app release is included.

**Docs.** Phase 0 copied this plan and the three historical research files into `docs/first-mate/ios-chat/` so the design travels with the code (synthetic data only; the as-is screenshots and original prompts are not included). Update `docs/first-mate/ios.md` (navigation, demo flags, verification), `herdr-harness-ios/README.md` (the First Mate section) and the README's First Mate paragraph about iPhone behavior as each phase lands. Add `release/notes` entries for the iOS builds if the release tooling wants them.

**Server.** No server deployment or companion package publication is part of this delivery. Deferred Phase 7 would require separate authorization, compatibility/setup instructions and publication; never infer a server cutover from an app build request (per `AGENTS.md`).

---

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Moving logic out of the Mac target breaks the shipped chat window or HUD | Mechanical moves only, Mac first, Mac tests run before any iOS work; the moved tests run in both CI jobs; no behavior edits in the same commit as a move |
| Swift 6 strict concurrency on moved types (both targets use `complete`) | The moved types are value types or `@MainActor @Observable`; annotate `Sendable` where the compiler asks; no `nonisolated(unsafe)` |
| Chat polling cost on a phone (3 s snapshot) | Journal-only fetch from Phase 1; measure real payloads on two configured companions; fall back to `/board?if_version=` (57-byte unchanged reply) in Phase 6 |
| iOS 26 Liquid Glass system bars tint unpredictably over the purple dusk | Check native simulator rendering in Phase 2 and the final device build after Phase 6; fall back to `.toolbarBackground(.visible)` with `railBackground` glass if the bars fail contrast |
| Contrast regressions when the dusk goes app-wide | Phase 6 only, behind the same accessibility test the Mac uses; other tabs stay opaque until then |
| `FirstMateStore.isSending` blocks all sends and actions on one host while one send is in flight | Accepted parity with the Mac; the UI disables the send button and shows Queued |
| Lead failover on a flaky cellular link (2 failed polls = 20 s) | Same rule as the Mac; the header says which machine answered; the user can pin |
| `navigationSubtitle` or `presentationCompactAdaptation` behave differently on iPhone | Both are available on iOS 26 / 16.4; keep a custom principal title view as the fallback |
| The older iOS UI-test fixture lacks `health()` / `ensure_lead()` and advertises routes its fake runtime cannot serve | Phase 1 uses bounded URLProtocol/fake-client tests and synthetic demo instead. Repair test support before relying on that fixture; do not weaken auth or start live agents |
| Xcode drift (project last upgraded with 26.4; this machine has 26.2; CI uses `macos-26`) | Builds today; keep `LastUpgradeCheck` as is; if CI's Xcode moves ahead, pin it in `verify.yml` |
| Long `AttributedString` mention linking per message on every poll | Cache runs per message id and catalog revision, as the transcript layout already caches rows |
| Deleting the old feature-card list removes a documented, tested UI | Git keeps it; docs and tests are updated in the same PR; the host filter and archive flows survive inside the new list |

---

## 8. Open decisions (defaults in bold; list which ones you assumed in the build report)

1. **Tab label:** **"First Mates"** (the brief's words) vs "First Mate". The screen itself has no large title (Grok Bot).
2. **Host filter menu:** **keep** the All Machines / per-machine scope in the … menu vs a flat list only (the Mac window).
3. **Capsule tap:** **readout popover with "Open chat"** vs opening the chat directly (long-press for the readout).
4. **Info screen:** **pushed** vs the current `.large` sheet.
5. **Chat poll on iPhone:** **3 s** vs the Mac's 2 s.
6. **Return key:** **newline; the button sends** vs return sends.
7. **Old First Mate tab code:** **list/card/appearance replaced in Phase 2; detail/chat/message/composer replaced in Phase 3**, not a second parallel tab or legacy release flag. Existing inspector/resource content stays until Phase 6 restyle.
8. **Appearance option:** **remove** (dark only) vs keep light for the tab.
9. **When a chat counts as read:** **visible, active and scrolled to the newest message** vs simply opened.
10. **App icon badge (Phase 7):** **First Mate count only when the setting is on, otherwise pane alerts** vs the sum.
11. **Push scope (Phase 7):** **needs-you transitions and lead replies** vs every First Mate reply.
12. **Store naming:** **extend `FirstMateMobileFleetStore` in place** vs renaming it `FirstMateChatSession`.
13. **Avatar size in rows:** **52 pt** (Grok Bot and iMessage) vs the Mac's 48 pt.
14. **Pinned row membership:** **My First Mate plus every conversation that needs you, capped at 6 + "+N"** vs user-pinned conversations (long-press → Pin, stored per phone).
15. **The lead in the list:** **only in the pinned row** vs also as the first row.
16. **First Mate's bubbles:** **no avatar and no speaker line** (Grok Bot, 1:1 feel; agents keep theirs) vs the Mac's avatar on the last bubble and name on the first.
17. **Suggested replies:** **buttons inside the First Mate bubble that offers them** (Grok Bot's inline actions) vs chips above the composer (the Mac).
18. **Rows:** **two lines with the status word trailing on the preview line** (Grok Bot) vs the Mac's third status line.

**Resolved 2026-09-29:** row highlight = 6% ink, radius 10; bubble radius stays 18. Dynamic Type caps at `.xxxLarge` without truncating messages. Keep passive OS reduction support without independent release gates. One final signed iOS delivery after Phase 6; no first-push or per-phase device-test approval gate.

---

## Appendix A: token mapping (Mac → iOS)

Shared semantic token names match the Mac after Phase 0; old iOS aliases change meaning. iOS additionally defines `rowHighlightFill` (6% ink), `Radius.row` (10 pt) and `maximumDynamicTypeSize` (`.xxxLarge`), without changing Mac tokens.

| Old iOS name | New role | Old hex → new |
|---|---|---|
| `ink` | `railBackground` | #191A23 → #131317 |
| `graphite` | `windowBackground` (base) | #20212C → #151519 |
| `elevated` | `inkSolid(0.03)` | #292B39 → #1B1B1F |
| `input` | `inkSolid(0.04)` | #2B2D3B → #1D1D21 |
| `surface`, `selection` | `inkSolid(0.10)` | #353747 / #353649 → #2A2A2E |
| `separator` | `outline` (ink 10%) | #343643 → translucent |
| `subtleSeparator` | `hairline` (ink 7%) | #2C2E3A → translucent |
| `text` | `primaryText` | #E4E5ED → #E9E9EC |
| `mist` | `secondaryText` (70%) | #B3B5C6 → #A9A9AD |
| `muted` | `tertiaryText` (70%) | #A0A3B4 → #A9A9AD |
| `accent` | `accent` | #AAA6F4 (same) |
| `primaryAction` | `primaryAction` (= accent) | #A6BAFF → #AAA6F4 (`brandBlue` keeps #A6BAFF) |
| `attention` | `attentionBadge` (alias kept) | #FF9F0A (same) |
| `signal`, `success`, `working`, `alert`, `warning` | same | same |
| `code` | `primaryText` on `chipFill` | #CFB8E8 → ink |
| `crust` | black 22% over base | #15161E → #101014 |
| `mauve` | `folder` | #B9A7DF (same) |
| `diffAdd`, `diffRemove`, `diffHunk` | Mac diff tokens | #83BC91 → #00D492, #D997A2 → #FF6467, hunk → tertiary |
| — | `firstMateAvatarFill` | new, #2A2244 |
| — | `cardFill`, `fieldFill`, `insetFill`, `hoverFill`, `codeFill`, `chipFill`, `selectedFill` | new, ink at 3/4/5/5/6/8/10% |
| — | `proseText`, `iconTint` | new, 78% / 50% |
| — | `rowHighlightFill` | `codeFill`, ink 6%, selected and pressed rows |
| `cardRadius` 16, `compactRadius` 10 | kept as aliases; new `Radius.card` 12, `.composer` 8, `.control` 6, `.row` 10, `.panel` 16, `.bubble` 18, `.pill` 24 | |

## Appendix B: API map by screen

| Screen | Calls (per machine) | Capability |
|---|---|---|
| Conversations | `GET /first-mate/features?view=`, `GET /first-mate/capabilities` (probe), `GET /first-mate/fleet`, `GET /first-mate/lead` | v1, fleet-v1, lead-v1 |
| Row swipe Archive | `POST /features/{id}/actions {archive, reason, request_id}` | archive-v1 |
| ＋ New feature | `POST /first-mate/features {title, goal, cwd, request_id}` | v1 |
| Chat | `GET /features/{id}?events=journal` (3 s), `POST /features/{id}/messages {text, request_id}` (202), `POST /features/{id}/read {through_message_id}` | v1, journal-events-v1, fleet-v1 |
| Chat (lead) | `POST /first-mate/lead`, `GET /features/{lead}`, `POST /features/{lead}/messages {text, request_id, context}` | lead-v1 |
| Composer (Phase 5) | `POST /features/{id}/attachments {filename, content_type, data_base64}`, `POST /api/v1/voice/transcriptions`, `GET /first-mate/models`, `POST /features/{id}/model-settings` | attachments-v1, model-settings-v1 / safe-model-settings-v1 |
| Rate a reply | `GET/POST /first-mate/feedback-categories`, `POST /features/{id}/messages/{mid}/feedback`, `GET /features/{id}/feedback` | feedback-v1 |
| Info | the same snapshot; `GET /first-mate/documents/{id}`, `GET /first-mate/sessions/{id}?before=&limit=` | v1 |
| Push (Phase 7) | `POST /api/v1/push/devices`, `GET /push/status`; server → APNs | first-mate-push-v1 (new) |

## Appendix C: accessibility identifiers to keep for UI-test parity with the Mac

On iOS, feature/pinned-row identifiers must be machine-qualified (or have a unique machine-qualified wrapper) because two hosts can share a feature ID. Preserve existing `first-mate-feature-<machineID>-<featureID>` identifiers through the old-list transition; the Mac's unqualified names below are a semantic parity reference, not permission to introduce collisions.

`first-mate-chat-search`, `first-mate-chat-new-feature`, `first-mate-chat-row-lead`, `first-mate-chat-row-<featureID>`, `first-mate-chat-inspector-toggle`, `first-mate-lead-tab-overview`, `first-mate-window-pending-decision-<id>`, `first-mate-window-additional-replies-<id>`, `skim-toggle-<id>` / `skim-sentence-<id>` / `skim-rest-<id>`, `first-mate-model-controls`, `first-mate-context`, `first-mate-execution-notice`, plus the existing iOS ones (`first-mate-machine-picker`, `first-mate-composer`, `first-mate-send`, `first-mate-message-<id>`, `first-mate-create-*`).
