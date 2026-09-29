# Research: Mac First Mate chat window inventory (origin/main 30627dc, 2026-09-28)

Read-only sweep made for the iPhone port. `<root>` was an export of origin/main at 30627dc; paths are relative to the repository root.

# First Mate chat window (macOS): reference for the iPhone port

I read all 19 ChatWindow files (5,204 lines), the 10 extra FirstMate files, BUILD-SPEC.md, the App/State wiring, the shared-package types the window calls, and the related tests. Nothing was modified.

## 0. Paths, and where the code differs from the spec

**Root:** `<repository-root>`

Below, `file:line` means one of these files:

- **ChatWindow:** `<root>/herdr-harness-mac/herdr-harness-mac/FirstMate/ChatWindow/`
  - `FirstMateChatWindowRoot.swift`, `FirstMateChatWindowSession.swift`, `FirstMateConversation.swift`
  - `FirstMateChatSidebar.swift`, `FirstMateChatHeader.swift`, `FirstMateChatConversationView.swift`
  - `FirstMateChatTranscript.swift`, `FirstMateChatBubble.swift`, `FirstMateChatComposer.swift`
  - `FirstMateChatInspectorColumn.swift`, `FirstMateLeadOverviewView.swift`, `FirstMateLeadBriefing.swift`
  - `FirstMateCapsuleView.swift`, `FirstMateMentionLinker.swift`, `FirstMateMentionPicker.swift`
  - `FirstMateChatPrimitives.swift`, `FirstMateChatTime.swift`, `FirstMateReadState.swift`, `FirstMateBadge.swift`
- **FirstMate:** `<root>/herdr-harness-mac/herdr-harness-mac/FirstMate/`
  - `FirstMateFleetIndex.swift`, `FirstMateLeadMachine.swift`, `FirstMatePromptComposer.swift`, `FirstMateComposerModelControls.swift`
  - `FirstMateStatusColors.swift`, `FirstMateStatusLabel.swift`, `FirstMateAttention.swift`, `FirstMateReadMarkerEnvironment.swift`
  - `Hud/FirstMateHudModel.swift`, `SkimmableReply.swift`, `FirstMateInspectorView.swift`
  - `FirstMateMachineScope.swift` (defines `FirstMateFleetFeatureID`, lines 13-16)
- **Shared package** (compiled into both Mac and iOS): `<root>/HerdrFirstMateShared/`
  - `FirstMateFleet.swift`, `FirstMateMention.swift`, `FirstMateClient.swift`, `FirstMateStore.swift`, `FirstMateChatDemo.swift`, `FirstMateConversationEntry.swift`
- **App and State:** `<root>/herdr-harness-mac/herdr-harness-mac/`
  - `App/HerdrHarnessMacApp.swift`, `App/FirstMateAppServicesModifier.swift`, `App/HerdrMacAppDelegate.swift`
  - `State/FirstMateDockBadgeController.swift`, `State/FirstMateFleetDriver.swift`, `State/FirstMateChatDemoSource.swift`
  - `Models/FirstMateChatPreferences.swift`, `Views/Root/AppRootView.swift` (`HerdrShellState`), `Views/Workspace/WorkspaceNavigationView.swift`, `Views/Settings/SettingsView.swift`
- **Spec:** `<root>/docs/first-mate/chat-window/BUILD-SPEC.md`. There is also a playable prototype, `reference.html`, in the same folder (106 KB).

**Where the code on main differs from BUILD-SPEC.** The code is what ships, so port from the code.

1. **Breathing label.** Code: opacity floor 0.75 (`FirstMateChatPrimitives.swift:223`), and `HerdrThemeAccessibilityTests` requires exactly 0.75. Spec: 0.4.
2. **Window size and shortcut.** Code: minimum 680×620 (`HerdrHarnessMacApp.swift:133`), shortcut ⇧⌘F (`:256-266`; ⌥⌘F is Report a Bug). Spec: 960×620 and ⌥⌘F.
3. **Search.** Code matches title, label, preview and machine name (`Session:125-134`). Spec: title and latest message only.
4. **Composer: two different ones.**
   - Feature chats and the real lead chat use the shared `FirstMatePromptComposer` → `PromptComposerView`. That is an 8 pt-radius card with a context line and a model pill. It has **no @ picker** and **no hold-to-talk**.
   - The spec's 22 pt pill (＋ / mic that becomes send / @ picker / hold 300 ms to talk) is `FirstMateChatComposer`. It is only used in `.lead` mode, on the Phase 1 briefing screen (`ConversationView.swift:97`). Its `.feature` mode is never created in production.
5. **@ picks are plain text.** A pick inserts `@Name ` as ordinary text and is turned into a Markdown link at send. The spec's uneditable token that Backspace removes whole does not exist.
6. **Lead inspector.** Code shows only the Goal line and the Needs you / Moving / Done groups. Pull requests, usage and journal are left as a follow-up (`FirstMateLeadOverviewView.swift:7-8`).
7. **Bubble avatar and name.** The speaker name is on the **first** bubble of a group and the avatar on the **last**. The spec says both sit on first and last.
8. **Capsule shape.** A full `Capsule()` at 21 pt tall (so radius 10.5), not the spec's 11 pt radius.
9. **Phase 2 lead is already in the code.** When a machine advertises `first-mate-lead-v1`, My First Mate is a real conversation (`FirstMateLeadChat`). The Phase 1 briefing is only the fallback.
10. **Possible bug.** The lead row's preview shows the lead's newest message as raw Markdown (`$0.text`), not through `FirstMateChatPreview.plainText` (`Sidebar.swift:462`).

## 1. Component inventory

| Type (file:line) | What it renders | Data it takes |
|---|---|---|
| `FirstMateChatWindowLayout` (Root:6-47) | Pure column rules: sidebar full or rail; inspector hidden, inline or overlay | width, `inspectorPreference: Bool?` |
| `FirstMateChatWindowRoot` (Root:50-254) | The window: sidebar, chat column, inspector. Also hidden ⌘K/⌘I buttons, sheets (create, archive), open requests, mention URL routing | `HerdrAppModel`, `HerdrShellState`, `ModelFavoritesStore`, or an existing session |
| `FirstMateChatWindowSession` (Session:17-536) | `@MainActor @Observable` state: selection, stores, polling, read marking, archive, create, lead machine | model, shell, config provider, client factory, fleet sources |
| `FirstMateConversation` / `FirstMateConversationList` / `FirstMateChatPreview` (Conversation:4-212) | Row model; builds and sorts the list; Markdown to one plain line | `[FirstMateFleetHost]`, `FirstMateReadState` |
| `FirstMateReadState` (ReadState:8-25) | Local read overrides: feature → newest First Mate message id seen | — |
| `FirstMateBadge` (Badge:5-17) | The one count: conversations showing a dot | hosts, read state |
| `FirstMateChatTime` (Time:4-46) | Time labels for rows, bubbles and day pills | date, now, calendar |
| `FirstMateChatSidebar` (Sidebar:8-263) | 40 pt drag band, brand, search, lead row, "Conversations" label, rows, empty states; rail mode | session, `isRail`, `searchFocusRequest`, `onNewFeature` |
| `FirstMateNewFeatureButton` (Sidebar:269-288) | The ＋ button, 30×30 | action |
| `FirstMateSidebarRowChrome` (Sidebar:292-332) | Row frame: 10 pt dot column, 48 pt avatar, text; hover/selection fill; divider | dotColor, isSelected, isHovered, showsDivider |
| `FirstMateConversationRow` (Sidebar:336-391) | Feature row | `FirstMateConversation` |
| `FirstMateRowTopLine` (Sidebar:396-422) | Name and time line | name, date |
| `FirstMateRowStatusWord` (Sidebar:425-436) | Colored status word, breathing while working | conversation |
| `FirstMateLeadRow` (Sidebar:440-492) | My First Mate row | conversations, `FirstMateLeadSummary?` |
| `FirstMateRailItem` (Sidebar:495-527) | Rail entry: dot and 48 pt avatar | title, a11y label, dotColor |
| `FirstMateChatHeader` (Header:5-120) | 60 pt chat header | session, inspectorVisible, toggle |
| `FirstMateInspectorToggle` (Header:124-147) | `sidebar.right` button, 30×30 | isOpen |
| `FirstMateChatConversationView` (ConversationView:7-158) | Chat column: lead / briefing / feature | session, model, favorites; `@State leadDraft`, `@State picks` |
| `FirstMateFeatureChat` (private, :161-244) | Feature transcript, notices, suggestions, shared composer | store, snapshot, id |
| `FirstMateLeadChat` (private, :249-335) | Real lead transcript or welcome, shared composer | store, snapshot, machineID |
| `FirstMateSuggestionRow` (private, :339-364) | Suggested-reply chips; tapping sends | suggestions, store, featureID |
| `FirstMateLeadSummaryCard` (:368-407) | "Summary" card holding the briefing flow | conversations, now, open |
| `FirstMateTranscriptLayout` (Transcript:8-152) | Pure rules: speakers, groups, day labels, file cards, suggestions, typing, read key | messages, documents |
| `FirstMateMessageDisplay` (Transcript:157-213) | Your bubble's text without the dictation suffix; `Attachment:` lines become chips | text |
| `FirstMateChatTranscript` (Transcript:219-432) | Scrolling grouped bubbles, typing row, read marking, feedback wiring | session, store, snapshot, conversationID, isTyping |
| `FirstMateChatBubbleRow` (Bubble:8-246) | One message (yours, or First Mate's / an agent's) | Row, agent, file cards, max width, feedback |
| `FirstMateBubbleStack` (Bubble:251-273) | Layout that hugs content; last child (the meta line) is right-aligned | — |
| `FirstMateDayPill` (Bubble:276-289) | "Today" separator | label |
| `FirstMateTypingRow` (Bubble:293-351) | Three animated dots | startsGroup |
| `FirstMateFileCard` (Bubble:354-403) | Document card; opens the Documents tab | document, from |
| `FirstMateAttachmentChips` (Bubble:406-424) | Paperclip chips inside your bubble | paths |
| `FirstMateCapsuleView` (Capsule:6-111) | Inline feature pill; hover or focus shows the readout popover | conversation, isCurrent, open |
| `FirstMateCapsuleReadout` (Capsule:115-212) | 280 pt card: avatar, status, "now", six step bars, "Open chat" | conversation |
| `FirstMateFlowLayout` / `FirstMateFlowGap` / `FirstMateBriefingFlow` (Capsule:216-331) | Word-wrapping layout for briefing words and pills | segments |
| `FirstMateChatComposer` (Composer:11-644) | 22 pt pill composer (briefing only, see §0.4) | mode, session, store?, draft/attachments/picks bindings, placeholder, features, crew |
| `FirstMateSuggestionChip` (Composer:647-668) | Reply chip | title |
| `FirstMateMicPulse` (Composer:671-689) | Pulsing ring around the mic while listening | reduceMotion |
| `FirstMateMentionTrigger` / `FirstMateMentionOption` / `FirstMateMentionPicker` (Picker:5-226) | `@` detection; picker options; floating picker | draft, features, crew |
| `FirstMateCrewStyle` / `FirstMateMentionCatalog` / `FirstMateMentionLinker` (Linker:5-167) | Agent emoji and status; name catalog; mention runs in text | conversations, snapshot |
| `FirstMateChatStatusStyle` (Primitives:8-69) | Status colors and words for the chat window | `FirstMateHudStatus` |
| `FirstMateEmojiDisc` (Primitives:74-102) | Emoji on the violet disc | emoji, size, edge? |
| `FirstMateFaceOrb` / `FirstMateFace` / `FirstMateBlinkSchedule` (Primitives:107-212) | First Mate's face; blinks every 5.2 s | size |
| `FirstMateBreathing` (Primitives:217-249) | Breathing opacity modifier | isActive |
| `FirstMateChatInspectorColumn` (Inspector:9-47) | Lead Overview, the native feature inspector, or a placeholder | session, topInset |
| `FirstMateChatFeatureInspector` (private, Inspector:51-71) | Wraps `FirstMateInspectorView` plus the resource sheet | store, snapshot, openCommit |
| `FirstMateInspectorPlaceholder` (private, :75-100) | Spinner or error | error? |
| `FirstMateLeadOverviewView` + row (LeadOverview:9-172) | Lead inspector: Overview tab only | session |
| `FirstMateLeadBriefing` (LeadBriefing:6-152) | Briefing text, lead row status line, header subtitle | conversations, now |

## 2. Window layout

**Scene** (`HerdrHarnessMacApp.swift:126-142`)
- `Window("First Mate", id: "herdr-first-mate-chat")`; the id is `HerdrWindowID.firstMateChat` (:15).
- Default size 1320×860; minimum 680×620.
- `.windowStyle(.hiddenTitleBar)`, `.windowResizability(.contentMinSize)`, `.commandsRemoved()`, `.handlesExternalEvents(matching: [])`.
- `.preferredColorScheme(.dark)`, `.tint(HerdrTheme.accent)`, `HerdrMainWindowChromeModifier` (draws the dusk and turns glass and haze on).

**Width rules** (Root:6-47)
- Sidebar: 320 pt, or a 76 pt rail below 760 pt.
- Inspector: 360 pt. Inline at 1140 pt and wider; below that it floats over the chat (overlay).
- With no preference, the inspector auto-opens at 1280 pt and wider. That is decided **once**, on the first layout (`settledInspectorPreference`, :41-44). After that only the ⌘I key or the header toggle changes it.
- Layout changes animate with `.snappy(duration: 0.24)` (:101). The inspector enters with move-from-trailing plus opacity.

**Sidebar column** (Root:79-87; Sidebar:22-52)
- Background: `HerdrGlassBackground(level: Glass.sidebar = 0.80, base: railBackground)`, with a hairline on the trailing edge.
- Top: a 40 pt `HerdrWindowDragArea` (`ControlHeight.titleBar`), clear for the traffic lights.
- Then the brand, then search (padding horizontal 12, bottom 6), then the scrolling list. In rail mode, brand and search are hidden.

**Chat column** (Root:146-179)
- Header (60 pt), then `FirstMateChatConversationView`.
- Background: `HerdrHazeBand` at the top (280 pt tall, 6% opacity, fades out downward), over `HerdrGlassBackground(level: Glass.pane = 0.80, base: windowBackground)`. Clipped.
- **Overlay inspector:** sits below the header (top padding 60). Width `min(360, columnWidth − 24)`. Fill `overlayFill` = rgba(23,22,29,0.97) (:72). Shadow black 0.4, radius 20, x −9. No scrim. Esc closes it (:103-107).

**Inline inspector** (Root:91-99)
- Width 360, `HerdrGlassBackground(Glass.pane, windowBackground)`.
- `topInset = 60 − ControlHeight.bar (36) = 24` pt of drag area (with a leading hairline), so the 36 pt tab bar ends exactly on the header's bottom edge.

**Header** (Header:10-31)
- 60 pt tall; padding leading 22, trailing 14; HStack spacing 12. The whole header is a drag area; hairline at the bottom.
- Avatar 38 pt, then a VStack (spacing 2): title at 14.5 semibold, tracking −0.15; subtitle HStack spacing 10, at 11.5 in `tertiaryText`, one line.
- Inspector toggle on the right.
- Context menu on a feature: "Archive feature…" (Root:151-155).

| | Lead ("My First Mate") | Feature |
|---|---|---|
| Avatar | `FirstMateFaceOrb(38)` | `FirstMateEmojiDisc(emoji, 38)` (emoji falls back to `FirstMateDefaultEmoji`) |
| Title | "My First Mate" | conversation title, else snapshot title, else "Loading…" |
| Subtitle | `headerSubtitle`, e.g. "3 need you, 3 moving, 1 done" or "No features yet" (all needs-you features, read or not). When more than one machine has a lead: a `Menu` with the machine name and an 8 pt semibold `chevron.down`. Items: "Automatic (Machine)" ✓ when not pinned, a Divider, then each machine ✓ when pinned. If the lead has fallen back to another machine (not demo): "‹Preferred› is offline" in `warning` (Header:94-100) | Status word (row weight and color; breathes while working), then `stepText` ("Step 4 of 6, QA", or "All six steps done", or nothing if the step is unknown), then the machine name when there is more than one machine |
| Chat body | With a lead machine: `FirstMateLeadChat` (transcript, or a welcome card when empty). Without one: the Phase 1 briefing ("Today" pill, Summary card, "Describe a new feature below, and First Mate starts it for you.", `FirstMateChatComposer(.lead)`) | `FirstMateFeatureChat` |
| Inspector | `FirstMateLeadOverviewView` | `FirstMateInspectorView` bound to the window's own store |

**Footers.** No column has a footer except the inspector's 32 pt sync footer (§6).

## 3. Sidebar

**Brand** (Sidebar:56-86)
- HStack spacing 11: `FirstMateFaceOrb(34)`; "First Mate" at 15 semibold, tracking −0.15, `text`; subtitle at 11 (caption) in `tertiaryText`, one line; spacer (min 8); ＋ button.
- Padding: leading 16, trailing 12, bottom 12.
- Subtitle: "N feature(s), M need(s) you". N = all non-archived conversations; M = `badgeCount` (dots only, so needs-you **and** unread). Examples: "7 features, 3 need you", "1 feature, 1 needs you".
- ＋ button: `plus` at 15 regular; `iconTint`, or `text` on hover; 30×30; hover fill `inkFill(0.08)`, radius 8. Tapping selects the lead and focuses its composer (Root:208-211).

**Search** (Sidebar:88-126)
- `magnifyingglass` at 13, `tertiaryText`; plain TextField at 13 with placeholder "Search conversations"; a `xmark.circle.fill` clear button (`HerdrIconButtonStyle(visualSize: 24)`) when there is text.
- Height 34; padding leading 11, trailing 5; fill `inkFill(0.05)`, radius 9; border 1 pt, `accent @0.65` when focused, else `inkFill(0.08)`.
- Keys: ⌘K focuses it; Esc clears it; ↑/↓ move the selection.
- It filters title, label, preview and machine name, case-insensitive (Session:125-134). The lead row shows only if the query is empty or matches "My First Mate".

**List** (Sidebar:141-181)
- `LazyVStack` spacing 0, padding top 4, horizontal 8, bottom 14.
- Order: lead row first (always, no "Pinned" label), then the "Conversations" label, then feature rows.
- "Conversations" label: caption semibold, `tertiaryText`, padding 12 / 20 / 4 / 20, hairline on top across the full width (horizontal −8), plus top 6 and bottom 2.
- There are **no machine groups or machine labels** in the list. Machines are one flat list.

**Row chrome** (Sidebar:292-332)
- HStack spacing 9: a 10 pt-wide dot column (flat 9×9 dot, no glow), a 48 pt avatar, then the text.
- Padding: top 10, leading 4, bottom 10, trailing 10.
- Fill: `inkFill(0.10)` when selected, `inkFill(0.05)` on hover; radius 10.
- Divider: 1 pt `hairline` along the top edge, from x = 80 (4 + 10 + 9 + 48 + 9) to 10 from the right. Shown when index > 0 and neither this row nor the row above is hovered or selected (:170).
- Row height works out to 79 pt: 10 + 20 (name line) + 1 + 18 (preview) + 3 + 17 (status) + 10 (:393-395).

**Feature row** (Sidebar:336-436)
- Avatar: `FirstMateEmojiDisc(48)`, emoji at 24 pt.
- Top line: name at 13.5 semibold, tracking −0.07, `text`, one line with tail truncation, minimum height 20. Time at 11, `tertiaryText`, monospaced digits.
- Preview (top 1):
  - If `isWorkingOnReply`: "typing…" at 12 in `accent`.
  - Otherwise `previewText` at 12, `tertiaryText`, one line, minimum height 18.
- Status word (top 3): 11.5; weight `.medium` if quiet, else `.semibold`; minimum height 17; breathes while working.
- a11y: "Title, Word[, new message]"; id `first-mate-chat-row-<featureID>`; context menu "Archive feature…".

**Dot rule** (Conversation:30)
- `showsDot = hudStatus.needsYou && isUnread`, where needsYou means blocked, turn or ready.
- Color comes from `dotColor`: blocked `alert` #E2A7B6; turn `attentionBadge` #FF9F0A; ready or done `signal` #9CCDB9; working `working` #E4C386; idle or unknown `idleTint` #8E8E96.
- In practice only alert, orange or green can appear, because only needs-you rows show a dot.

**Status word and color** (Primitives:13-68)
- Words: Blocked (`alert`), Your turn (`attentionBadge`), Ready for review (`signal`), Working (`working`), Ready to plan / Complete / Status unknown (`tertiaryText`, weight 500).
- A working feature with a known step shows the step instead: Planning, Building, In review, In QA, PR open, Merging (`FirstMateChatSteps.doing`).

**Lead row** (Sidebar:440-492)
- Chrome with no divider; dot in `accent` when `leadSummary.unread`; `FirstMateFaceOrb(48)`; name "My First Mate".
- Time: the lead's latest message `createdAt`, else the newest `activityAt` of any conversation.
- Preview:
  - With a lead summary: its latest message, prefixed "You: " when role is "user".
  - Otherwise the briefing text with the greeting and count cut off (text after " you: ", else after the first ". ").
- Status line: `leadRowPreview` ("Nothing needs you" / "1 feature needs you" / "N features need you") at 11.5 regular in `secondaryText` (not a status color).
- a11y: "My First Mate, [unread reply, ]status"; id `first-mate-chat-row-lead`.

**Preview text** (Conversation:79-94, 119-144; plain-text rules :148-212)
- Fleet entry with a latest message:
  - From you: "You: " + plain text.
  - From First Mate: the skim sentence (`skimSay`) if it has one, else plain text of the message.
- No latest message: plain text of `now`, or "".
- Older companion (no fleet support): plain text of `dashboardSummary.latestMessage`, or "".
- Plain text strips code fences, headings, quotes, list and task markers, rules and tables, images and links (keeps their text), `<url>`, code, `**`/`__`/`*`/`_`/`~~`, and `|`. Backslash escapes are honored, and the result is collapsed to one line.

**Time format** (Time:8-45)
- Same day: 24-hour "HH:mm" (`%02d:%02d`).
- 1 day ago: "Yesterday".
- 2-6 days ago: full weekday name.
- Otherwise, including dates in the future: short month and day, e.g. "Sep 3".

**Sorting** (Conversation:61-70)
- `activityAt` descending; dated rows before undated ones; ties by machineID, then featureID.
- `activityAt` comes from `entry.activityAt`, else `latestMessage.createdAt`, else `entry.updatedAt`, else `feature.updatedAt`. For older companions: `dashboardSummary.activityAt`, else `latestMessageAt`, else `updatedAt`.
- De-duplicated by (machineID, featureID); archived features are dropped.

**Empty states** (:217-235), at 12 in `tertiaryText`:
- "No conversations match “q”."
- A spinner with "Loading conversations…"
- "No features yet. Press ＋ and tell First Mate what to build."

**Keyboard** (:243-262)
- ↑/↓ move through [lead, …rows], clamped at the ends (no wrap). If nothing in the order is selected, ↓ goes to the first and ↑ to the last.
- A keyboard move never moves focus to the composer (`pendingComposerFocus = false`). A click does.

**Rail** (:183-215)
- LazyVStack spacing 4, padding 4 / 4 / 14 / 4.
- Item: 10 pt dot column plus 48 pt avatar; padding 7 / 0 / 7 / 4; same fills at radius 10; the name is a tooltip.
- The rail lists every conversation, ignoring search.

## 4. Transcript and bubbles

**Column**
- Maximum content width 720, gutter 24 (Transcript:234-235).
- Padding top 22, bottom 16, centered.
- Bubble maximum width = `min(clamp(width − 48, 200…720) × 0.86, 560)`, rounded (:239-242).

**Grouping** (:40-63)
- A group is consecutive messages from the same speaker on the same day. Speakers: user (roles "user" or "human"), `firstMate`, or `agent(assignmentID)`.
- `isFirstInGroup` shows the speaker name; `isLastInGroup` shows the avatar and the tail corner.
- When the typing row is showing, the last First Mate bubble gives its avatar and tail to the typing row.
- Messages go through `FirstMateConversationEntry.make` first, so closing replies to a checkpoint collapse into a "Additional response from this turn" disclosure (caption, `secondaryText`, leading inset 34) (:260-271).

**Spacing**
- Day pill: caption `tertiaryText`, padding vertical 3 / horizontal 11, fill `inkFill(0.05)`, radius 10, centered. Labels: "Today", "Yesterday", weekday, or "MMM d". Top 4, bottom 8.
- Top padding above a bubble: 14 for the first in a group (6 when a day pill sits above it); 3 otherwise.

**Bubble shape** (Bubble:228-238)
- `UnevenRoundedRectangle`, radius 17, `.continuous`.
- On the last bubble of a group, one corner becomes 5 pt: bottom-trailing on yours, bottom-leading on theirs.
- Padding: top 8, horizontal 13, bottom 6.

**Your bubble** (:32-59)
- Right-aligned; fill `accent @0.20`; border `accent @0.26`, 1 pt.
- Text: `PiMarkdownText` at 13.5 × font scale, line spacing 3.5 × font scale, full ink (`userPalette`).
- Mentions in your bubble come **only** from explicit links (the catalog's `withoutPlainNames`).
- Attachment chips: `paperclip` label, caption medium, padding 3 / 8, fill `inkFill(0.08)`, capsule, middle truncation.
- Context menu: "Copy". a11y: "You: text, attached a, b, queued, sent by voice".

**First Mate or agent bubble** (:63-123)
- Fill `inkFill(0.06)`; border `hairline`, 1 pt.
- Avatar 26 pt, gap 8: `FirstMateFaceOrb(26)`, or for an agent `FirstMateEmojiDisc(role emoji, 26, edge: status color)`.
- Speaker line: "First Mate" (caption semibold, `accent`), or the agent's title (caption semibold, `secondaryText`) followed by its role (caption medium, `tertiaryText`).
- Body: `SkimmableReply(style: .bubble)` (sentence 13.5 / line height 21.6; lines 13 / 20) wrapping `PiMarkdownMessageView`.
- File cards, then a meta line.
- Role emoji (Linker:6-16): planner 🗺️, designer 🎨, reviewer 🔎, researcher 📚, tester 🧪, builder 🛠️, anything else ✦.
- Agent status mapping (:19-27): blocked or failed → blocked; awaiting_direction → turn; running, coordinating, recovering or processing → working; completed, done or passed → done; else idle.

**Meta line** (:167-186)
- micro (10), `tertiaryText`, right-aligned at the bottom of the bubble.
- Contents, in order: "Skimming…" (pending skim), "Queued", "Sent by voice" (in `accent`), then the time as "HH:mm" (always 24-hour clock), monospaced digits.

**Hover footer** (:190-211)
- `FirstMateResponseFeedbackFooter`: rate up, edit (opens a sheet), remove, retry, resolve conflict, and copy. If feedback isn't available: `PiCopyButton` "Copy response".
- Shows on hover, or while a rating is saved, saving, failed or in conflict. Inset 34 on the leading side.
- Copy uses `NSPasteboard` (:213-218).

**"Needs you" signals.** There is no banner. What exists:
- **"Decision needed"** label (`hand.raised`, caption medium, `warning`) on the pending checkpoint bubble (`snapshot.pendingDecisionMessageID`: the current visit's checkpoint while status is `awaiting_direction`) (:88-94).
- **`FirstMateExecutionStateNotice`**, between the transcript and the composer: a `warning`-colored `exclamationmark.triangle` label on an 8% `warning` band with a hairline on top. Shown for runtime health warnings, blocked ("Work is blocked. Review the retained evidence…"), or recovery needing direction.
- **Store errors:** `exclamationmark.triangle`, 12 pt, `warning`, two lines, inset 36.
- **Closed features** (completed or cancelled) replace the composer with "This feature is closed. Its conversation and evidence remain available." (`archivebox`, 12 pt, `tertiaryText`).

**Typing row** (:293-351; `isTyping` rule at Transcript:147-151)
- Shown when a send is in flight, the chat is working on a reply, or one of your messages is queued or processing.
- `workingOnReply` comes from the fleet entry for a feature, and from `snapshot.feature.coordinatorOwner != nil` for the lead.
- Face orb 26 plus a tailed bubble; "First Mate" line only when it starts a group; padding vertical 9 (starts a group) or 13, horizontal 14.
- Dots: 6 pt, `tertiaryText`, spacing 4. Period 1.1 s, staggered 0.15 s. Each dot rises 2 pt and fades from 0.3 to 1.0, peaking at 30% of the cycle. Under Reduce Motion the dots are static at 0.6.
- a11y: "First Mate is working on a reply".

**File cards** (:354-403)
- Rule: shown once per document, on the earliest non-user reply that names the document's title as whole words (Transcript:106-133).
- Icon: `doc.text` at 15 in `accent`, in a 30×36 box, fill `accent @0.13`, radius 7, border `accent @0.32`.
- Text: title at 12.5 semibold; "From Agent" caption; `arrow.up.right` at 10.
- Card: padding 8 / 10; fill `windowBackground @0.45`; radius 11; border `hairline`, or `accent @0.55` on hover.
- Tapping shows the inspector on Documents.

**Mention runs** (Linker:98-167)
- Only in feature chats. The catalog is set at ConversationView:130-133; the lead chat and briefing do not set it.
- Explicit `herdr://first-mate?feature_id=…[&assignment_id=…]` links always become runs. In First Mate or agent bubbles, plain names also match: exact, case-sensitive, whole words, longest first, never inside code or links.
- Run = thin space + emoji + no-break space + name + thin space. Bold (`stronglyEmphasized`), `primaryText`, background `tint @0.22`, no underline.
- Tapping a mention goes to `openMention` (Root:229-253). The machine is the current chat's machine first, then any machine listing the feature. A feature mention opens that chat and focuses its composer. An agent mention opens the feature with the inspector on Agents and shown.

**Capsules** (briefing only; Capsule:6-111)
- Height 21. HStack spacing 5: a 17 pt disc (`firstMateAvatarFill` with a 10 pt emoji); name at 12 semibold, `primaryText`, max width 200; a 6 pt dot in the status tint. Padding leading 2, trailing 8.
- Fill `inkFill(0.06)` plus `tint @0.11` (0.22 when active). Border `tint @0.36` (1.0 when active). Continuous capsule.
- Readout after 200 ms of hover (hides 160 ms after leaving), or immediately when the capsule has keyboard focus. Shown as a `.popover` with `arrowEdge: .bottom`.
- **Readout** (:115-212): 280 wide.
  - `FirstMateEmojiDisc(32)`; title at 13 semibold; status word at 11.5.
  - The `now` line at 12 in `proseText`, line spacing 3.
  - Six step bars: 3 pt tall, spacing 3, track `inkFill(0.10)`, fill in the status color. Fill = step + fraction; all six when done.
  - "Step n of 6, Name" (or "Step unknown"), then "This chat" or an "Open chat" button (11.5 semibold, `accent`).
  - Padding 12 / 13 / 11. When drawn outside a popover: radius 12, `floatFill` #191820, shadow black 0.45 radius 20 y 18, `outline` border.
- a11y: "Title, Word. Opens its chat."

**Briefing** (LeadBriefing:42-85; flow at Capsule:312-318)
- Words at 13.5 in `proseText`; flow spacing 4, line spacing 5.
- Greeting by hour: 5-12 "Good morning", 12-17 "Good afternoon", otherwise "Good evening".
- "N feature(s) need(s) you: A is blocked in QA, B needs a call, and C is ready for review." Order: blocked, then your turn, then ready.
- Or: "Nothing needs you right now."
- Then "X and Y are moving" (working, idle or unknown) and "Z shipped today / yesterday / on September 3" (only the most recent done feature).
- Lists use the serial comma.
- **Summary card** (ConversationView:368-407):
  - Header: `list.bullet.rectangle` at 12 in `accent`, in a 24×24 box with fill `accent @0.13`, radius 7.
  - "Summary" (caption semibold, `accent`) and "Built from your features. Not a message from an agent." (10.5, `tertiaryText`).
  - "Updated HH:mm" (micro).
  - Card: fill `inkFill(0.06)`, radius 12, border `hairline`.

**Suggested replies** (Transcript:138-143; ConversationView:339-364)
- Shown only when the chat needs you, nothing is typing, the newest message is First Mate's, and its skim has `reply` choices. Never invented on the client.
- Chips: 12 semibold, `accent`, horizontal padding 12, height 28; fill `windowBackground @0.5` (`accent @0.16` on hover); border `accent @0.40`; capsule. Flow spacing 6 / 6; bottom 8.
- Tapping calls `store.sendPreparedMessage(text)` directly, then `didMutate`.

**Scrolling** (Transcript:292-306)
- `defaultScrollAnchor(.bottom)` for initial offset and size changes; `.top` for alignment (so a short chat starts at the top).
- `followsLatest` is true while within 40 pt of the bottom.
- When a new last message arrives, or typing starts, it scrolls to the end marker only if `followsLatest`.
- There is **no "jump to latest" button**.

**Read markers** (Transcript:308-333; Session:465-482)
- `markReadIfNeeded` runs on appear and whenever `ReadKey` changes (followsLatest, key window, newest message id, conversation `isUnread`, `latestFirstMateMessageID`).
- Requires: the window is key (`controlActiveState == .key`), scrolled to the bottom, and a newest message exists.
- Feature: only if the conversation `isUnread`. Marks through the newest assistant message (else the newest message) using `fleet.markRead`.
- Lead: only if `lead.unread`. Uses `fleet.markLeadRead`.
- The main window marks read too, through `FirstMateMarkReadAction` (ReadMarkerEnvironment:13-79; WorkspaceNavigationView:563-575).

## 5. Composer

### A) Shared composer: every feature chat and the real lead (`FirstMatePromptComposer` → `PromptComposerView`)

Destination wiring is `PromptComposerDestination.firstMate`, in `herdr-harness-mac/herdr-harness-mac/FirstMate/FirstMateChatView.swift:366-459`.

**Settings**
- `voicePolicy: .firstMateStopToSend`, `supportsVoice: true`, `supportsPaneTools: false`, `supportsAttachments: store.attachmentsSupported`.
- Controllable when `canControl` and the feature is not closed.
- Placeholders:
  - Feature: "Message ‹title›" (ConversationView:226).
  - Lead: "Ask First Mate about any feature, or tell it what to pass on…"
  - Default: "Give direction, ask a question, or change the plan…"

**Frame.** Card fill `cardFill` (`inkFill(0.03)`), radius 8 (`Radius.composer`). The composer zone has padding top 4, bottom 12, horizontal 24, and is centered at a maximum width of 720 + 48 (ConversationView:150-157).

**Context line (top)**
- `FirstMateCoordinatorContextView`: a 14 pt ring (`HerdrProgressRing`), then one line at 12 in `tertiaryText` (turns `warning` when context pressure is reached).
- An `info.circle` button opens a 310 pt popover: "Coordinator context" (or "First Mate context" for the lead), then summary, pressure, measurement and policy.
- When attachments aren't supported, it adds "Update this machine's companion server to attach files."

**Input.** `ComposerDraftEditor`.

**Tool row, left**
- `+` ("Add to prompt") popover: Attach files (if supported) and Paste code (`ComposerCodeBlockPaste`).
- Dictation mic: click to start, click Stop to transcribe **and submit**.
- `…` More popover: "Prompt tools", then "Record a voice note" (opens the recorder sheet).
- `FirstMateComposerModelControls` (the model pill).

**Tool row, right.** Primary send button.

**Also supported.** Dropping files (when attachments are supported) and quotes (`ChatQuote`).

**Model pill** (`FirstMateComposerModelControls.swift`)
- `PiModelEffortPill` holding `PiModelPickerChip` and `PiThinkingLevelChip` (segment style).
- "Next: Model · Thinking" when the configured model differs from what the session is running (a `clock.arrow.circlepath` glyph when narrow).
- "Use host default" ghost button, 26 pt.
- On an older server: "Update server for safe model changes".
- Confirmation dialog: "Change this coordinator session?" / "Apply for next coordinator turn".
- Enabled only when all of these hold: `canControl`, the store context still matches, settings are supported, no coordinator owner, no queued work, not sending, not loading, not saving (:134-143).

**Send path**
- `store.sendPreparedMessage(text, expectedContext:)` (Store:592-634) calls `client.sendFirstMateMessage`.
  - Features: `POST /api/v1/first-mate/features/{id}/messages` with `{text, request_id}`.
  - The lead: the same route with a `context: FirstMateLeadContext` body, supplied by `store.leadContextProvider` → `FirstMateLeadMachine.context(...)`.
  - A retry reuses the same request_id and the same context.
- Then `store.refresh()`, then `didSubmit` → `session.didMutate(machineID)`, which refreshes the main window's store and the fleet index.

**Drafts**
- Text: `store.composerDraft(for:)` / `setComposerDraft`. This is `store.draft` for the selected feature, or `drafts[featureID]` for others.
- Attachments, quotes and the dictation flag: `store.composerDrafts`, a `FirstMateComposerDraftStore` that exists on **macOS only** (Store:146-148).
- The window owns its own store per machine, so drafts are per window and per feature, survive switching chats, and are **not** shared with the main window (Session:4-10).

### B) Phase 1 briefing composer (`FirstMateChatComposer(mode: .lead)`)

**Pill** (Composer:186-205)
- HStack aligned to the bottom, spacing 6; padding 5; fill `inkFill(0.05)`; radius 22, continuous.
- Border: `alert @0.7` while listening, `accent @0.65` when focused, else `inkFill(0.10)`.
- Shadow: listening `alert @0.30` radius 11 y 0; focused `accent @0.20` radius 11 y 0; resting black 0.18 radius 14 y 10.

**Controls**
- ＋: 34 pt circle, fill `inkFill(0.08)`, `plus` at 16 medium in `secondaryText`. Disabled in lead mode (tooltip "Attach files in a feature's chat").
- Editor: `ComposerDraftEditor`, up to 7 lines, 13.5, line spacing 3.
- Trailing button:
  - With content: send, `arrow.up` at 15 bold in `onPrimary` on an `accent` circle (`primaryDisabled` when not ready), 34 pt.
  - Without content: mic, `mic.fill` at 15, fill `inkFill(0.08)` (0.15 while pressed). While listening: `alert` fill, glyph in `windowBackground`, and the pulse ring (1.1 s, scale 0.9 → 1.25, fade out, `alert @0.5`, 2 pt).

**Hold-to-talk**
- Hold 300 ms, via `DragGesture(minimumDistance: 0)` or holding Space while the mic has focus.
- While listening the editor area shows a waveform (max width 160) and "Listening…" in `alert`.
- Letting go transcribes and sends. It also works after the recorder's own 2.65 s auto-lock.
- A quick tap shows the hint "Hold the mic to talk."
- Esc cancels.
- VoiceOver: one activation records, the next sends.
- Transcription: `VoiceTranscriptionPipeline` (the companion's private transcription when preferred, else Apple's).

**Hint row** (10.5, `tertiaryText`, top 7, horizontal 12)
- Idle: "Type [@] to tag a feature. Hold the mic to talk." (feature mode) or "… Sending starts a new feature." (lead mode).
- Listening: "Listening. Let go to send, or press Esc to cancel." in `alert`.
- Transcribing: "Transcribing…". Nothing recognized: "Nothing heard." Errors in `warning`.
- Temporary hints clear after 2.5 s.

**@ picker** (Picker.swift)
- Trigger: the **trailing** `@query` of the draft. The `@` must start the draft or follow whitespace or "(". The query is at most 24 characters, with no newline, no leading space and no double spaces.
- Options: up to 5 features whose title or label matches, then the crew whose title matches. Only features on one machine can be tagged (for the briefing, the first machine that can create a feature).
- Size: width 320; height = rows × 34 + section labels × 24 + 12, capped at 320.
- Look: `floatFill` #191820, radius 12, `outline` border, shadow black 0.45 radius 20 y 18.
- Row: `FirstMateEmojiDisc(24, edge: status color)`, name at 12.5 semibold, detail (features: status word in status color; crew: role). Highlighted row `inkFill(0.10)`, radius 8.
- Section labels: "Features", "Crew on ‹title›".
- Keys: ↑/↓ wrap; Return or Tab picks; Esc closes. A pick inserts "@Name ".
- At send, `FirstMateMention.serializeComposer` turns picks into `[Name](herdr://first-mate?feature_id=…)` links (plus `&assignment_id=` for agents).

**Send** (lead mode). `session.beginCreate(goal:)` opens `FirstMateCreateSheet(store:initialGoal:)`. If no machine can create a feature, it shows "Add a machine to start a feature." and keeps the text. When the sheet closes, a newly created feature opens in the window (Root:282-291).

**Drafts.** Held in the view's `@State leadDraft`, with picks stored per draft key.

## 6. Inspector

**Feature** (Inspector:35-41)
- The native `FirstMateInspectorView(store, snapshot, openCommit)`, styled with the palette's foreground colors, `HerdrButtonStyle(.outline, height 26)` and the palette's accent tint, plus a `FirstMateResourceSheet`.
- Underline `HerdrTabs`: Overview, Agents, Documents, Workflow. Bar height 36, horizontal padding 16.
- Body: scrolling, padding 14 / 16 / 16.
- **Sync footer** (min height 32): `checkmark.circle` or `exclamationmark.circle` at 12, then "Synced with companion" / "Connection needs attention" / "Synthetic data · no agents launched", then "Revision N" (`FirstMateInspectorView.swift:45-60`).
- Workflow commits open a separate Git window (`HerdrWindowID.firstMateGit`).
- Tab rules: switching to a different feature resets the tab to Overview (Session:322-325); a file card sets Documents; an agent capsule sets Agents and shows the inspector.
- Before the snapshot loads: a spinner with "Loading the feature…", or the store error with `exclamationmark.circle` at 18.

**Lead** (`FirstMateLeadOverviewView`)
- A single "Overview" underline tab (id `first-mate-lead-tab-overview`).
- Heading "Your features at a glance" at 15 semibold.
- `HerdrMicroLabel` "GOAL" with "One place to ask about every feature and to start a new one." at 13 in `proseText`.
- Empty: "No features yet. Describe one in the chat to start it."
- Groups: Needs you, Moving, Done. Empty groups are left out. Each has a micro label with a count badge.
- Row: emoji at 13; title at 12 medium (`accent` on hover); `FirstMateStatusLabel(featureStatus)` at caption size.
  - The status label uses the **native** wording: "Your direction", "Working", "Complete", "Ready to plan", "Recovering", otherwise the status capitalized.
  - It uses `FirstMateStatusColors`: blocked `alert`, awaiting_direction **`signal` green**, running or coordinating `working`; paused, recovering or unverified `warning`; completed, complete or passed `success` #A3CBA7; failed, error or cancelled `alert`; anything else `tertiaryText`.
  - Detail line: "Machine · now", caption `tertiaryText`, two lines, inset 25.
  - Row padding vertical 6, minimum height 30; a `rowDivider` line under every row except the last.
  - Tapping opens that chat.
- Footer: "Synced with companion" / "A machine needs attention" (any host has an error) / the demo text, then "N feature(s)".

## 7. Data flow

**Row model** (Conversation:4-31)
- Fields: `id`, `machineID`, `machineName`, `featureID`, `title`, `label`, `emoji`, `hudStatus`, `featureStatus`, `stepIndex` (0…5 or nil), `stepFraction`, `now`, `previewText`, `previewIsFromUser`, `isWorkingOnReply`, `activityAt`, `latestFirstMateMessageID`, `isUnread`, `isArchived`.
- Built from `FirstMateFleetEntry` when the host supports the fleet summary. Otherwise it falls back:
  - `FirstMateHudStatus.fallback`: blocked → blocked; awaiting_direction → turn; running, coordinating, recovering or unverified → working; ready, paused or anything else → idle; completed → done.
  - Emoji from `FirstMateDefaultEmoji` (FNV-1a hash into a fixed 16-emoji palette).
  - Step unknown; `isUnread = needsYou`.

**Session** (Session.swift)
- One store **per machine, owned by the window**, created on first use (`configurationProvider` = `model.firstMateConfiguration(machineID:)`, client = `HerdrAPIClient`). It is rebuilt when `FirstMateConnectionIdentity` changes (configuration + `connectionGeneration` + demo flag), and a rebuilt store keeps the open chat selected (:147-176).
- Demo mode uses `shell.firstMateChatDemo.store`, shared with the Dock badge.
- `hosts` = `shell.firstMateFleet.hosts`, or the one demo host. `readState` = `fleet.readState`.
- The conversation list is cached until `hosts` or `readState` change.
- `run()` (:398-441) runs two tasks together:
  - **Selected-store refresh:** holds a `FirstMateWorkspaceControlLease` (this sets `controlAvailable`). If the lead is selected but not yet open, calls `store.openLead()`. Then `store.refresh()`. Repeats every **2 s**. With no store it waits **60 s** unless woken. `wakeRefresh()` cancels the wait whenever the selection changes.
  - **Fleet backstop:** every **2 s**, if nothing else is observing the fleet and not in demo mode, it starts `fleet.observe(sources:connectionGeneration:)` itself.
- **What `store.refresh()` calls:** `fetchFirstMateCapabilities` → `fetchFirstMateFeatures(scope: .active/.all)` → `fetchFirstMateFeature(selectedID, journalEventsOnly:)`.
- **What `openLead()` calls:** capabilities (first load only) → `ensureFirstMateLead` (`POST /api/v1/first-mate/lead {request_id}`) → `fetchFirstMateFeature(leadID)`.
- **After any mutation here** (send, archive, read, create), `didMutate` calls `shell.refreshFirstMateStore(machineID:)` and `firstMateFleet.refresh()` (:487-493).

**Fleet index** (FleetIndex.swift)
- Each poll, per host, in parallel:
  - `fetchFirstMateFeatures`.
  - The capability probe, alongside the list. Asked once per lifecycle; an unsupported host is asked again after 5 min (:137).
  - `fetchFirstMateLead` if the host supports the lead.
  - `fetchFirstMateFleet` (`GET /api/v1/first-mate/fleet`) if the host supports the fleet summary. A 404 or 501 drops back to the feature list.
- Interval: 10 s while the app is active, 30 s in the background (`FirstMateFleetDriver.swift:80-82`). The HUD can shorten it. The driver checks the machine roster every 1 s and starts from either window (`AppRootView.swift:263-280`).
- Nothing publishes unless displayed data changed (updates that only change `updated_at`, usage or context are ignored, :422-470).
- **Read marking** (:522-557):
  - The local override is set first, so the dot and badge clear at once.
  - Then `POST /api/v1/first-mate/features/{id}/read {through_message_id}`.
  - On failure: roll back, with a backoff of 8 s doubling to 180 s.
  - Posts nothing if the chat is already read through that message, in demo mode, or if the host lacks the fleet summary.
  - `markLeadRead` (:484-496) clears the lead's dot once the companion confirms.
- **Archive** (:82-109): check capabilities for archive support, then `setFirstMateArchived` (`POST …/actions {action: "archive", reason}`), then remove the row locally. Reasons: completed, test/synthetic, duplicate, no longer relevant, superseded, other.

**Combining machines**
- Hosts are in roster order (machines that have a First Mate configuration). They are flattened into one list, de-duplicated by (machineID, featureID), and sorted globally.
- Machine names appear only in the header subtitle and the lead Overview detail line, and only when there is more than one machine. Search also matches machine names.

**Lead machine** (LeadMachine:36-170)
- `capable` = hosts that support the lead, in roster order.
- **Preferred machine**, first match wins:
  1. The pinned machine, if it is still capable. Stored in UserDefaults `herdr.mac.firstMate.lead.pinned`; set from the header menu, cleared by "Automatic".
  2. This Mac's own machine (`localMachineID`, from the Mac's host identity), but only if its host supports `first-mate-lead-peers-v1`.
  3. The busiest machine, among those that already have a lead conversation if any do, else among all capable. "Busiest" = most non-done, non-archived features; ties go to the first in the roster.
- **Offline:** a machine with `failedPolls >= 2` counts as offline (the count is capped at 3). If the preferred machine is offline, the same rules run over the reachable machines, without the pin, to choose a stand-in. If no machine is reachable, it stays on the preferred one. `isFallback` = current ≠ preferred.
- **Nil** means no machine has a lead, so My First Mate shows the Phase 1 briefing.
- **Lead context sent with each lead message** (:138-170): every other machine the lead can't reach itself (not in the lead's `peers`). For each, its non-archived features sorted by activity: label, title (if different), status, step name, now, unread, latest message. Offline machines are marked `offline: true`.

**Offline and failure handling**
- A host whose refresh fails keeps its last features, fleet entries and lead summary, so dots and the badge persist. It records the error, a "last seen" time and `failedPolls`.
- A 404 or 501 reads as "This companion needs First Mate support."
- Store errors show under the transcript, in the lead's loading state, and in the inspector placeholder.
- An unreachable or unresolvable selection falls back to My First Mate (Root:137-139, 299-335).
- An open request that arrives before the list has loaded waits in `pendingOpen`.

**Opening the window from elsewhere**
- Setting `shell.firstMateChatOpenRequest` (Dock menu, HUD, "Open in window") or bumping `shell.firstMateChatOpenLeadRequest` (HUD) triggers `FirstMateChatWindowOpening.route` (`FirstMateAppServicesModifier.swift:46-103`).
- With the preview setting on (key `herdr.mac.firstMate.chatWindow`, default false), the request goes to this window. Otherwise it opens the main window's First Mate screen.

**Dock badge** (`FirstMateDockBadgeController.swift`)
- Writes `NSApp.dockTile.badgeLabel` = `fleet.badgeCount`, empty at zero.
- Controlled by the key `herdr.mac.firstMate.dockBadge`, default on. It takes the badge over from the alert count while on, re-writes the label 1 s after taking over and whenever the app activates, and keeps updating with every window closed.
- Dock menu: up to 5 dotted conversations titled "🧾 Receipt export: Blocked" (:178-197; `HerdrMacAppDelegate.swift:90-113`).

**HUD rules** (`FirstMateHudModel.swift`), reusing `FirstMateConversation`
- Order: blocked, then your turn, then ready (urgency 0/1/2); everything else after, in start order.
- Done features linger 120 s.
- At most 6 orbs or 6 rows, with the last slot becoming "+N" or a summary.
- Percent = round((step + fraction) / 6 × 100).
- The HUD also reuses `FirstMateChatBubbleRow`, `FirstMateTranscriptLayout.recentRows`, the emoji disc and the face orb (`Hud/FirstMateHudCards.swift:468-484`).

## 8. Theme usage (dark only)

**`HerdrTheme` color tokens**

| Token | Value |
|---|---|
| `text`, `primaryText` | `foreground` #E9E9EC |
| `proseText` | ink 78% over base |
| `secondaryText` | ink 70% over base |
| `tertiaryText` | ink 70% over base (light 76%) |
| `iconTint` | ink 50% over base |
| `inkFill(α)` | #E9E9EC at α. Used at 0.05, 0.06, 0.08, 0.10, 0.15 |
| `hairline` | line 0.07 (0.16 under Increase Contrast) |
| `rowDivider` | line 0.05 |
| `outline` | line 0.10 |
| `accent` | #AAA6F4, used at .13 / .16 / .20 / .22 / .26 / .30 / .32 / .40 / .55 / .60 / .65 / .80 |
| `onPrimary` | base #151519 |
| `primaryDisabled` | accent at 0.28 |
| `attentionBadge` | #FF9F0A |
| `firstMateAvatarFill` | #2A2244 |
| `signal` | #9CCDB9 |
| `working` | #E4C386 |
| `alert` | #E2A7B6 (also at .3 / .5 / .7) |
| `warning` | #DFB38E |
| `success` | #A3CBA7 (lead Overview status label) |
| `windowBackground` | base #151519 (also at .45 / .5) |
| `railBackground` | #131317 |
| `selectedFill` | 0.10 (status label pill) |
| `controlAccent` | #5E59A8 (Settings toggles) |

**`HerdrTheme` size tokens**
- `TextSize`: micro 10, caption 11, small 12, body 13.
- `ControlHeight`: small 24, regular 26, row 32, bar 36, titleBar 40.
- `Radius`: card 12, composer 8, control 6.
- `Glass`: sidebar 0.80, pane 0.80.
- `minHitTarget` 28.

**Glass**
- `HerdrGlassBackground(level:base:)`: the base color darkened by `HerdrGlass.backgroundBrightness` 0.80.
- `HerdrHazeBand`: opacity 0.06, height 280.
- `HerdrDuskBackdrop` (via `HerdrMainWindowChromeModifier`). Glass is on only when the Settings glass option is on, Reduce Transparency is off, and the scheme is dark.

**Modifiers and recipes**
- `herdrFont(size:weight:)`: size × `herdrFontScale`, used 71 times.
- `herdrHairline(edge)`, `herdrPlaceholder`, `.buttonStyle(.herdrPlain)` (plain style without the press fade).
- `HerdrIconButtonStyle(visualSize: 24)`, `HerdrButtonStyle(kind: .outline/.ghost, height: 26)`.
- `HerdrTabs(style: .underline)`: 2 pt ink underline, tabs 16 apart.
- `HerdrMicroLabel(text:count:)`: 10 semibold uppercase, tracking 0.6.
- `HerdrWindowDragArea`, `HerdrVoiceWaveform`, `HerdrProgressRing`, `herdrPaneBackground`.
- Markdown palette: `ChatProsePalette.firstMate(FirstMatePalette(scheme: .dark))`.

**Hard-coded values (not tokens)**
- **Colors:**
  - `idleTint` #8E8E96.
  - Face color #D9D6FF.
  - `overlayFill` rgba(23,22,29,0.97).
  - `floatFill` #191820, opaque.
- **Avatar and dot sizes:**
  - Face orb 34 (brand), 48 (rows and rail), 38 (header), 26 (bubbles and typing row).
  - Emoji disc 48, 38, 32 (readout), 26, 24 (picker), 17 (capsule). The emoji is drawn at 50% of the diameter.
  - Dots: 9 (rows), 6 (capsule and typing).
- **Emoji disc look:**
  - A radial `accent` highlight from 0.20 to 0, centered at (0.5, 0.26), end radius = size × 0.68 × hypot(0.5, 0.74).
  - Edge: `accent @0.20`, or the status edge at 0.55 with a 0.35 blurred glow (blur 3, padding 2).
- **Face orb look:**
  - Radial highlight `accent` 0.22 → 0, centered at (0.5, 0.34), end radius = size × 0.64 × hypot(0.5, 0.66).
  - Edge `accent @0.60`; glow `accent @0.30` blurred 7 with padding size × 0.08; an extra outer ring (`accent @0.32`, padding −3) when size > 26.
  - Face drawn at 62% of the orb, in a 48-unit coordinate space: eyes 8×12 at x −12.5 and 4.5; mouth a quadratic curve from (−5.5, 9.5) to (5.5, 9.5) with control (0, 13.5), stroke 2.2; face shadow `accent @0.8`, radius 2.
  - Blink: every 5.2 s the eyes close to 10% between 93% and 98% of the cycle (fully closed at 95.5%).
- **Radii:** bubbles 17 (tail 5); briefing composer 22; rows and day pill 10; search 9; buttons and picker rows 8; readout, picker and cards 12; file card 11; icon tiles 7.
- **Fonts:** 15 semibold (brand title), 14.5 semibold (header title), 13.5 (row name semibold, bubble text, briefing text, briefing composer), 13 semibold (readout title), 12.5 semibold (file card title, picker name), 11.5 (status and subtitles), 10.5 (hints), 8 (chevron). Tracking −0.15 and −0.07.
- **Animation timings:** breathing period 2.4 s, floor 0.75, cosine curve, 30 fps; typing dots and mic pulse 1.1 s; capsule highlight ease-out 0.12 s.

## 9. macOS-only behavior and touch equivalents

| Mac-specific | Where | Suggested iPhone equivalent |
|---|---|---|
| `Window` scene, hidden title bar, `contentMinSize`, `HerdrMainWindowChromeModifier` / `HerdrWindowChrome` (NSWindow), `HerdrWindowDragArea` (NSViewRepresentable) in the 40 pt band, header and inspector inset | App:126-142; Sidebar:24; Header:29; Inspector:17 | A `NavigationStack` (list → chat) or a tab. On iPad, a 3-column `NavigationSplitView`. Drop the drag areas; use safe areas |
| Width-driven columns, 76 pt rail, overlay inspector with Esc | Root:6-47, 103-107, 163-177 | List is the root; chat is pushed. Inspector in a sheet (`.presentationDetents([.medium, .large])`) opened from a toolbar button. No rail |
| Hover: row and button fills; capsule 200 ms hover readout; bubble footer on hover; file-card, chip, picker and overview hover states; skim rest-chip preview | throughout | Tap a capsule to show the readout (`.popover` with `.presentationCompactAdaptation(.popover)`, or a sheet). Long-press menu for Copy / Rate. A pressed state instead of hover. Show saved ratings persistently |
| `.help()` tooltips | throughout | Accessibility hints only |
| ⌘K search, ⌘I inspector (hidden zero-size buttons), ↑/↓ list, Esc (clear, close, cancel, dismiss), Return to send / Shift-Return for newline, Tab to pick, Space to hold the mic, `.focusable` list | Root:186-198; Sidebar; Composer | `.searchable` on the list; a toolbar button for the inspector; the keyboard's return key sends. Hardware-keyboard shortcuts optional (iPad) |
| Right-click context menus ("Archive feature…", "Copy") | Root:151; Sidebar:172, 207; ConversationView:192; Bubble:213 | `.contextMenu` via long-press; `.swipeActions` on rows to archive |
| `NSPasteboard` copy | Bubble:213-218 | `UIPasteboard.general.string` |
| `controlActiveState == .key` read gate | Transcript:226, 311 | `scenePhase == .active`, the chat is the visible screen, and scrolled to the bottom |
| Dock badge (`NSApp.dockTile.badgeLabel`), Dock menu (`applicationDockMenu`, 5 items), Window ▸ First Mate ⇧⌘F, `NSApp.activate`, `openWindow` / `dismissWindow`, preview-window setting | DockBadge:46; AppDelegate:90-113; App:256-266; AppServices | App icon badge via `UNUserNotificationCenter.setBadgeCount` (needs badge permission; staying current in the background needs push or `BGAppRefreshTask`); a tab bar `.badge()`; Home Screen quick actions (up to 4) or a widget for the Dock-menu list; no window setting |
| `openWindow(firstMateGit)` for commits | Inspector:36-41 | Push a view or present a sheet |
| Fleet driver uses `NSApplication` did-become / did-resign-active | FleetDriver:146-157 | `scenePhase` |
| `FirstMateLeadMachine.localMachineID` uses the Mac's host identity | LeadMachine:122-126 | No local machine on iPhone: `local` = nil, so the rule becomes pinned → existing lead conversation → busiest |
| `SkimViewProbe` (NSView / NSTextView selection) and `SkimInteraction` NSView-anchored popovers | SkimmableReply:342-364 | iOS already has its own `Views/Shared/SkimmableReply.swift` |
| `HerdrTheme` built on NSColor / NSAppearance; Increase Contrast via NSWorkspace; dusk and haze via `Image(nsImage:)` | Design/HerdrTheme.swift; HerdrGlass.swift | UIColor trait providers, `colorSchemeContrast`, UIImage |
| Hold-to-talk with `DragGesture(minimumDistance: 0)` | Composer:286-290 | Works on touch as is; add haptics |
| Menus and popovers (lead machine switcher, context details, model picker) | Header:58-93 | `Menu` works on iOS; popovers need compact adaptation |

**What iOS already has, and what it lacks**
- **Available:** the shared package is compiled into the iOS target (project.pbxproj references `../HerdrFirstMateShared`). So `FirstMateHudStatus`, `FirstMateFleetEntry`, `FirstMateLeadSummary`, `FirstMateLeadContext`, `FirstMateDefaultEmoji`, `FirstMateChatSteps`, `FirstMateMention`, `FirstMateStore`, `FirstMateClient`, `FirstMateSkimReader` and `FirstMatePalette` are all usable.
- **Mac-only, would need porting:** everything in ChatWindow, `FirstMateFleetIndex`, `FirstMateFleetHost`, `FirstMateFleetFeatureID`, `FirstMateLeadMachine`, `FirstMateAttention`, `FirstMateHudModel`, `FirstMateStatusColors`, the fleet driver, and the Dock badge controller.
- **Composer drafts:** `FirstMateStore.composerDrafts` (attachments, quotes, dictation) is macOS-only.
- **Theme:** iOS `Design/HerdrTheme.swift` is a 48-line older palette. It has no `inkFill`, text levels, `hairline`, `outline`, `firstMateAvatarFill`, `TextSize`, `Radius`, `ControlHeight` or `Glass`. It names the orange `attention` (#FF9F0A) instead of `attentionBadge`.
- **API client:** iOS `Infrastructure/HerdrAPIClient.swift` implements fleet, read and HUD calls. It does **not** implement `fetchFirstMateLead`, `ensureFirstMateLead`, `sendFirstMateMessage(context:)` (the default silently sends without the context), `uploadFirstMateAttachment`, `transcribeFirstMateVoice`, or the link calls. The protocol defaults for those throw `invalidResponse`.
- **Views iOS already has:** its own `PromptComposerView`, `FirstMateInspectorView`, `FirstMateComposerView` (a plain TextField composer), `FirstMateStatusLabel`, `FirstMateCreateSheet` and `PiMarkdownText`.

## 10. Tests

Test folder: `<root>/herdr-harness-mac/herdr-harness-macTests/`.

**Files that name ChatWindow, FirstMateChat or FirstMateConversation directly**

| File | Tests | Covers |
|---|---|---|
| `FirstMateChatConversationTests.swift` | 23 | Grouping and day breaks; typing takes the avatar and tail; the typing rule; checkpoint retention; dictation suffix and attachment chips; bubble a11y; file-card rule; suggested replies only when needed; @ trigger (24 chars), insert, options (5 features then crew), serialization, one-machine tagging, recovering a restored draft's picks; read-key re-marking; mic release; mention runs; your bubbles only tag picks; catalog; step bars; briefing flow gaps |
| `FirstMateChatShellTests.swift` | 27 | Fleet driver (start once, roster changes, keeps polling when windows close, resumes, demo, 10 s / 30 s, inert under tests); preferences; Dock badge label, demo, ownership, reassert, notifications, setting toggled; Dock menu (5 items, "emoji name: status"); open routing; "Open in window"; the main window's mark-read action |
| `FirstMateChatWindowSessionTests.swift` | 16 | Demo host; archiving (selected and not); independence from the main window; per-machine stores; list and badge come from the fleet; demo read; only the selected store refreshes and holds the lease; mutation refresh; fleet backstop observer; demo sends move to top; Dock request waits; rebuilt store keeps the chat; pointer focus vs keyboard; no machine to create; refresh wakes on selection |
| `FirstMateConversationListTests.swift` | 7 | Dot rule; fallback; sort; previews and skim; merging fleet and fallback; Markdown to one line; status words |
| `FirstMateChatWindowRenderTests.swift` | 15, in three suites | Renders (below); layout thresholds; width decides once; rail below 760; mention machine resolution; row a11y; lead Overview groups; create sheet opens the new feature / cancel; unlisted open request; resolvable snapshot |
| `FirstMateChatConversationRenderTests.swift` | 4 | Renders (below) |
| `FirstMateLeadBriefingTests.swift` | 11 | Briefing text, order, singular / plural, unknown step, nothing needs you, greetings, lead row and header subtitle, sidebar subtitle, `FirstMateChatTime` (labels, day pills, time zone) |
| `FirstMateHudTests.swift` | 25 | HUD roster, order, overflow and routing built on `FirstMateConversation` |
| `HerdrThemeAccessibilityTests.swift` | :192-239 | Capsule labels and row status words clear 4.5:1 over the dusk; breathing floor must equal 0.75 |
| `FirstMateChatTestSupport.swift` | — | Support only: `SyntheticChatFleetClient`, `ChatFixtures` |

**Closely related files**
- `FirstMateBadgeTests.swift` (6): mixed hosts, duplicates, archived, older hosts equal attention, failed host keeps its count, local read.
- `FirstMateReadStateTests.swift` (18): optimistic read and rollback; stale-failure guard; the companion's answer wins; no-post cases; read after the fleet stops observing; capability probing and 5-min reprobe; fleet route loss; backoff.
- `FirstMateLeadTests.swift` (12): machine choice, offline stand-in, home machine, pinning, lead context, `openLead`.
- `FirstMateFleetIndexTests.swift` (21).
- `FirstMateSidebarBadgeTests.swift` (7).
- `FirstMateSkimRenderTests.swift` (7).
- Shared: `<root>/HerdrFirstMateSharedTests/FirstMateMentionTests.swift` (14) and `FirstMateFleetDecodingTests.swift` (15: decoding, status fallback table, emoji hash vectors, demo invariants).

**Tests that write PNGs** (via `HerdrRenderHarness`, at scale 2)
- **Output folder:** `$HERDR_RENDER_DIR`, else `$TEST_RUNNER_HERDR_RENDER_DIR`, else the app sandbox's `~/Library/Containers/org.herdr.companion.macos/Data/tmp/herdr-renders` (`DemoScreenshotRenderTests.swift:775-808`).
- `FirstMateChatWindowRenderTests.swift`:
  - `fmchat-chrome-lead-1440.png` and `fmchat-chrome-receipts-1440.png` (1440×900)
  - `fmchat-chrome-overlay-1000.png` (1000×800)
  - `fmchat-chrome-rail-700.png` (700×800)
  - `fmchat-chrome-tab-{overview,agents,documents,workflow}.png`
- `FirstMateChatConversationRenderTests.swift`:
  - `fmchat-conversation-receipts.png`, `fmchat-conversation-lead.png`, `fmchat-conversation-composer.png` (900×860)
  - `fmchat-conversation-readout.png` (340×220)
- `FirstMateChatShellTests.swift:525`: `fmchat-shell-first-mate-open-in-window.png`.
- Also related: `first-mate-skim-*.png` (SkimRender) and `first-mate-sidebar-attention-*.png` / `first-mate-attention-N.png` (SidebarBadge).

**Accessibility identifiers worth keeping on iOS for UI-test parity**
`first-mate-chat-window`, `first-mate-chat-search`, `first-mate-chat-new-feature`, `first-mate-chat-row-lead`, `first-mate-chat-row-<id>`, `first-mate-chat-inspector-toggle`, `first-mate-lead-tab-overview`, `first-mate-window-pending-decision-<id>`, `first-mate-window-additional-replies-<id>`, `skim-toggle-/skim-sentence-/skim-rest-<id>`, `first-mate-model-controls`, `first-mate-context`, `first-mate-execution-notice`.