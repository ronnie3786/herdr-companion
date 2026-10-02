# First Mate chat window: build spec

A new First Mate, built as a standalone macOS window that runs **alongside** the current First Mate screen. It is a chat app:
- a conversation list;
- a chat with inline smart capsules;
- the existing First Mate inspector.

The Dock icon gets a badge showing how many conversations need you.

**Design reference:** `reference.html` in this folder. It is a playable HTML prototype with made-up data.
- Open it in a browser and try it: switch chats, hover a capsule, type `@` in the composer, hold the mic, tap a suggested reply, and open each inspector tab.
- Match its look, sizes and behavior. Where this spec and the prototype disagree, this spec wins.

---

## 1. Scope

| Phase | Scope | Ships when |
|---|---|---|
| **1. Preview window + Dock badge** | The window, conversation list, chat, capsules, @ tagging, hold-to-talk, suggested replies, the inspector, read markers, and the Dock badge | You can use it all day beside the current First Mate |
| **2. Lead First Mate** | "My First Mate" becomes a real cross-feature chat. This is the same lead as HUD Phase 2 (`../first-mate-hud-2026-09-26/BUILD-SPEC.md`). | Phase 1 is in use |
| **3. Promote** | Make it the default First Mate, as the window or as the main window's First Mate mode | You decide after using it |

Build Phase 1 only. Leave clean seams for Phase 2. Don't fake lead behavior in production code.

**The current First Mate stays exactly as it is.** The new window is additive, lives behind a setting, and can be turned off.

---

## 2. Where things live today (`origin/main`)

**Windows** (`herdr-harness-mac/herdr-harness-mac/App/HerdrHarnessMacApp.swift`)
- Scenes are declared in `body`. `Window("Active Work", id: HerdrWindowID.activeWorkBoard)` is the pattern to copy for a single, reopenable window.
- Add `HerdrWindowID.firstMateChat` and open it with `openWindow(id:)`.

**Glass** (`Design/HerdrGlass.swift`, `Design/HerdrWindowChrome.swift`, `Design/HerdrTheme.swift`)
- `HerdrMainWindowChromeModifier` draws `HerdrDuskBackdrop` and sets `herdrGlassActive` and `herdrHazeActive`. Reuse it so this window gets the same dusk, the same 80% glass (`HerdrTheme.Glass.sidebar`/`.pane`), and the Haze band (`HerdrHazeBand`) at the top of the chat.
- The window is **dark only**: `.preferredColorScheme(.dark)`. No light variant.

**First Mate state** (`Views/Root/AppRootView.swift` → `HerdrShellState`)
- `shell.firstMate` is the active `FirstMateStore`, with one store per machine in `firstMateStores`.
- The store keeps **UI state and data together**: `selectedFeatureID`, `inspector`, `documentsMode`, `graphMode` and `draft`. `send`, `perform` and `saveModelSettings` act on `selectedFeatureID`.
- **Don't share the main window's store instance.** Selecting a chat in the new window would move the main window's selection.
- **Precedent:** `Dashboard/AgentBoardColumnState.swift` builds its own `FirstMateStore()` and calls `configure(client:demo:)` with the same client. Do the same, with one store per machine, owned by the window.
- `shell.firstMateFleet` (`FirstMate/FirstMateFleetIndex.swift`) polls every machine's feature list every 10 s. It is driven by `observe(sources:connectionGeneration:)` in `Views/Workspace/WorkspaceNavigationView.swift`, so **it only runs while the main window's navigation is on screen.**
- `FirstMate/FirstMateAttention.swift` counts features waiting on a human (`awaiting_direction`, `blocked`), de-duplicated by machine and feature. The main window's First Mate nav badge uses it.

**Reusable First Mate views** (`FirstMate/`)
- `FirstMateInspectorView` and its tabs: `FirstMateOverviewView`, `FirstMateAgentsView`, `FirstMateDocumentsView` and `FirstMateWorkflowView`.
- Markdown: `FirstMateMarkdownContentView` and `PiMarkdownText`.
- Feedback (rate a response), attachments (`store.uploadAttachment`), voice (`store.transcribeVoice`, `HerdrQuickVoiceCapture.beginHold`, `VoiceTranscriptionPipeline`).
- Opening sessions: `FirstMateOpenRequest` (`herdr://first-mate?feature_id=…`).
- Demo data: `HerdrFirstMateShared/FirstMateDemo.swift`. Launch with `-HerdrDemoMode`.

**Server** (`herdr_harness/`): routes live in `server.py` `_first_mate_route`, and storage in `first_mate_store.py`.

**Contract rules** (`docs/first-mate/build-contract.md`):
- snake_case JSON.
- New behavior sits behind a capability flag.
- Older clients ignore new fields.
- The server, Mac, iOS and web stay compatible.

---

## 3. Shared server data (build once with the HUD)

The window needs the same fleet data the HUD spec defines: a short label, emoji, a status that separates your turn from ready for review, a step, a one-line "now", and **per-feature read markers**. None of it is on `origin/main` yet.

- Build it exactly as **HUD spec sections 3 and 4** describe: `GET /api/v1/first-mate/fleet`, `POST …/features/{id}/read`, `POST …/features/{id}/hud`, and the `hud_status` and step mapping.
- Advertise it as capability **`first-mate-fleet-v1`**. The HUD uses the same capability; whichever lands first builds it, and the other reuses it.
- Poll the fleet endpoint on the same cadence as `FirstMateFleetIndex` (10 s), per machine, and fold the result into the fleet index. Don't fetch full snapshots for the list.

**Fallback when a server lacks `first-mate-fleet-v1`.** The window must still work against older companions:

| Field | Fallback |
|---|---|
| status | `blocked` → blocked; `awaiting_direction` → your turn; `running`/`coordinating`/`recovering` → working; `ready`/`paused` → ready to plan; `completed` → complete |
| emoji | Picked client-side from a small fixed set by hashing the feature id, so it stays stable |
| step | Unknown: show "Working" instead of "Building" or "In review" |
| unread | Unknown: treat every needs-you feature as unread, so the dot and badge equal `FirstMateAttention` |

---

## 4. The window

- **Scene:** `Window("First Mate", id: HerdrWindowID.firstMateChat)`, default size 1320 × 860, minimum 960 × 620, `.windowStyle(.hiddenTitleBar)` like the main window.
- **Open it from:**
  - Window ▸ First Mate (⌥⌘F if free; otherwise pick one and say which);
  - an "Open in window" button in the current First Mate screen's title bar;
  - the Dock icon's menu.

  All three appear only when the setting is on.
- **Setting:** Settings ▸ General ▸ "First Mate chat window (preview)", off by default. Turning it off closes the window.
- **Layout:** three columns, matching the reference:
  - the sidebar, 320 pt;
  - the chat, flexible;
  - the inspector, 360 pt, toggled with ⌘I and a header button. It opens by default when the window is at least 1280 pt wide.
  - Below 1140 pt the inspector overlays the chat. Below 760 pt the sidebar collapses to a rail of avatars and dots.
- **Background:** the dusk behind every column, with sidebar and pane glass at 0.80 and the Haze band at the top of the chat.

### 4.1 Conversation list (sidebar)
- **Header:** the First Mate face orb, "First Mate", a subtitle ("7 features, 3 need you"), and a **＋** that starts a new feature (section 4.4).
- **Search field:** filters by title and latest message.
- **My First Mate:** the first row, always at the top, with no "Pinned" label. See section 4.4.
- **A "Conversations" label**, then every non-archived feature across **all machines**, newest activity first. Archived features stay out of this list, and the current screen's archive toggle still works there.
- **Row layout:** unread dot column (10 pt), avatar (48 pt), then the text.
  - **Avatar:** the emoji on a dark violet disc (`#2A2244`), with a faint lavender top highlight and a 1 pt lavender edge at 20%. **No ring, no status badge.**
  - **Text:** the name (13.5 pt semibold) and time; one line of preview (the latest message as plain text, with "You: " when you sent it); and the status label.
- **Conversation name and emoji:** show the user-set fleet label as the name, otherwise the feature title; on older companions without `label_source`, recognize a user label by comparing it with the title and the server's word-boundary-clipped default label. Right-click a row or rail avatar (also the header or transcript), or click the feature header's avatar/name, to open a window-modal **Rename or Change Emoji…** editor. Its Title section edits a 100-code-point presentation name or resets to the feature title; its Emoji section offers a quick palette, an emoji field and macOS Character Viewer, or resets to the default. The row keeps its existing avatar, time, preview and status geometry; the main-window feature title is unchanged. Only edited fields are posted to the owning companion; a failed save keeps the sheet open.
- **Status label**, in its own color with no leading dot:
  - Blocked, Your turn and Ready for review use their HUD colors (`alert`, `attentionBadge`, `signal`).
  - Working shows its step ("Planning", "Building", "In review", "In QA", "PR open", "Merging") in `working` yellow and **breathes**: opacity 1 → 0.4 → 1 over 2.4 s. Reduce Motion stops the animation.
  - Ready to plan and Complete are quiet, in tertiary text.
- **Reply in progress:** while First Mate is working on a reply — from a prompt just submitted in this window (in flight or with an unanswered queued/processing echo) or when the fleet summary reports `working_on_reply` — the row shows the breathing Working word (the step's doing word when known) and a “typing…” preview, hides its unread dot, and leaves the window's “need you” count. When the fleet reports the reply and a waiting status, its own waiting word and dot return; a failed send restores them immediately. This is a window-local presentation rule: the Dock badge and HUD continue to use the fleet's status.
- **Unread dot:** 9 pt, flat, **no glow**. It shows only when the feature needs you (blocked, your turn, ready for review) **and** has an unread message. Its color is the reason. It clears when you read the chat. Working, ready-to-plan and complete features never show a dot.
- **Dividers:** a 1 pt hairline between rows, starting at the text column. It hides next to the hovered or selected row.
- **More than one machine:** add the machine name to the chat header's subtitle. The list itself stays unlabeled. Searching by machine name works.

### 4.2 Chat
- **Header (60 pt):** the avatar, the name, the status label, "Step 4 of 6, QA" (hidden when the step is unknown), the machine name when there are several, and the inspector toggle. The 38 pt avatar is vertically centered in the bar; the name and status line form one leading-aligned column 2 pt apart, centered beside it.
- **Bubbles:**
  - First Mate's are ink at 6% with a hairline; yours are accent at 20% with an accent edge.
  - 17 pt radius, and the tail corner is 5 pt on the last bubble of a group.
  - The small avatar (26 pt) and the speaker name sit on the first and last bubble of a group.
  - Messages from a crew agent show the agent's name and role.
- **Rendering:** use the existing Markdown renderer inside bubbles. Keep today's per-message actions (rate a response, copy) on hover or in a context menu. Don't drop them.
- **File cards** for documents referenced in a message open the Documents tab.
- **Typing indicator** while First Mate is working on a reply (`isSending`, or a queued or processing message).
- **Suggested replies:** when a feature is waiting on you and the server offers choices, show them as chips above the composer. If there are no structured choices, show none. **Don't invent choices on the client.**

### 4.3 Smart capsules and @ tagging
A capsule is an inline pill: a 17 pt emoji disc, the name, and a 6 pt status dot, on a tint of its status color. Hovering it for 200 ms shows a readout card:
- **Feature:** avatar, name, status, the "now" line, six step bars, "Step n of 6", and "Open chat".
- **Crew agent:** role and feature, its latest note, status, and "Show in inspector".

Clicking a feature capsule opens its chat. Clicking an agent capsule opens that feature's inspector on the Agents tab and highlights the row.

- **Wire format:** the composer turns a tag into a Markdown link, so iOS, the web and the coordinator all see readable text:
  - feature: `[Receipt export](herdr://first-mate?feature_id=fm_123)`
  - agent: `…&assignment_id=as_9`

  The renderer turns `herdr://first-mate` links into capsules.
- **Plain names in First Mate's messages** also become capsules when they exactly match a feature label or title, or an agent title in the same feature. Match whole words, longest names first, and never inside code.
- **Composer:** a rich text input.
  - Typing `@` opens a picker listing features, then the current feature's crew, filtered as you type.
  - Arrow keys move, Enter or Tab picks, Esc closes.
  - The pick becomes an uneditable capsule token, and Backspace removes it whole.
  - Pasting inserts plain text.

### 4.4 My First Mate (Phase 1)
The lead chat needs the Phase 2 lead First Mate. Until then:
- **The row and chat show a live briefing**, built on the client from the fleet data, for example: "Good morning. 3 features need you: [capsule] is blocked in QA, …". It refreshes as the data changes. It is labeled as a summary, not as a message from an agent.
- **The composer here starts a new feature.** Sending opens the existing new-feature flow (`store.create`), with the text as the goal. Say so in the placeholder: "Describe a new feature".
- **The inspector for My First Mate** shows only the Overview tab: pull requests across features, then features grouped under Needs you, Moving and Done, then usage and the latest journal line per feature. Agents, Documents and Workflow across features wait for Phase 2.

### 4.5 Composer
- The pill has three parts: **＋** for attachments (`uploadAttachment`), the input, and a mic that becomes **send** when there's text.
- **Hold the mic 300 ms to talk:** the words stream into the input, and letting go sends with a "Sent by voice" note. Use `HerdrQuickVoiceCapture`/`transcribeVoice`. A quick tap shows "Hold the mic to talk". Esc cancels.
- Enter sends, and Shift+Enter adds a new line.
- Drafts are per feature and per window. They survive switching chats.

### 4.6 Inspector
**Reuse `FirstMateInspectorView`:** underline tabs Overview, Agents, Documents and Workflow, and the 32 pt sync footer. Bind it to the window's own store, so its tab and selection are independent of the main window's. The reference HTML reproduces it only to show placement.

For a selected feature only, add a compact trailing Git icon button after the tabs. Its tooltip and accessibility label are **Open Git in New Window**, with accessibility identifier `first-mate-inspector-open-git`. It opens that feature's own machine/feature Git window on the recommended checkout, with the checkout picker; reopening focuses the same window. My First Mate and the main-window inspector have no new button. Tab-bar height and padding stay unchanged. This is Mac-only and needs no companion update beyond existing Git support.

The `FirstMateResourceButtons` chips say "1 agent" and "1 document". Pluralize them there, since it fixes both screens.

---

## 5. Read markers
- A feature's chat **counts as read** when it is showing in a key window (this one or the current First Mate screen) and scrolled to its newest message. Then post `…/read` with the newest message id.
- **Update locally first,** so the dot and badge clear at once. Roll back if the post fails.
- **The current First Mate screen marks read too,** so you never have to clear things twice.
- iOS and the web can adopt read markers later. They ignore the field for now.

---

## 6. Dock badge
- **What it shows:** `NSApp.dockTile.badgeLabel` is the **number of conversations showing an unread dot**: features across all machines that need you (blocked, your turn, ready for review) **and** are unread. Empty when zero.
- **One pure function,** used by the Dock, the window sidebar's header subtitle and the main window's First Mate nav badge, so every number agrees:

  ```swift
  enum FirstMateBadge {
      static func count(hosts: [FirstMateFleetHost], readState: FirstMateReadState) -> Int
  }
  ```
  - De-duplicate by machine and feature (`FirstMateFleetFeatureID`). Skip archived features.
  - A host without `first-mate-fleet-v1` counts all of its needs-you features, which equals `FirstMateAttention`.
  - A host whose last refresh failed keeps its last successful count, as `FirstMateAttention` does today.
- **Always current:** the Dock badge must update while the app is running, **even with every window closed**. Move fleet observation out of `WorkspaceNavigationView` into an app-level owner started from `HerdrHarnessMacApp`, for example `HerdrShellState` or a small `FirstMateBadgeController`. Keep the main window's existing behavior. Poll every 10 s while the app is active and every 30 s while it's in the background.
- **Setting:** Settings ▸ General ▸ "Show First Mate count on the Dock icon". **On by default, and independent of the preview window setting.**
- **Dock menu:** list up to five conversations with a dot ("🧾 Receipt export: Blocked"). Choosing one opens the chat window on that feature, or the current First Mate screen when the preview is off.
- **No sounds, bounces or notifications** in this phase.

---

## 7. Keep the two First Mates in sync
- After a send, action, archive or read in the new window, refresh that machine's store in the main window and the fleet index (and the reverse). A message sent in one window should appear in the other within about a second.
- Composer drafts are **not** shared between windows. Say so in a code comment.
- One connection per machine: reuse the configured client, and don't open a second socket or poller per window.

---

## 8. Visual tokens (dark only)
All tokens come from `HerdrTheme`. Add only `firstMateAvatarFill` (`#2A2244`) and the capsule tint rule.

| Element | Value |
|---|---|
| Glass | base `#151519` at 0.80 over `HerdrDuskBackdrop`; Haze at 0.06 |
| Text | ink `#E9E9EC`, prose 78%, secondary and tertiary 70%, icons 50% |
| Status | blocked `alert #E2A7B6` · your turn `attentionBadge #FF9F0A` · ready for review `signal #9CCDB9` · working `working #E4C386` · quiet `tertiaryText` |
| Accent | `#AAA6F4` (your bubbles, links, chips, the face) |
| Avatar | 48 pt in the list, 38 pt in the header, 26 pt beside messages; emoji at 50% of the diameter |
| Unread dot | 9 pt, flat |
| Capsule | 21 pt tall, 11 pt radius; fill = status color 11% over ink 6%; edge = status color 36% |
| Radii | 17 pt bubbles, 22 pt composer, 12 pt cards, 10 pt rows |

Contrast: every text level must still pass the existing `HerdrThemeAccessibilityTests` over the dusk's brightest point, including the breathing label at its dimmest (opacity 0.4). If it fails, raise the floor to 0.55.

---

## 9. Accessibility
- **Rows:** "Receipt export, Blocked, new message".
- **Capsules:** "Receipt export, Blocked. Opens its chat."
- **Dot:** covered by the row's label, not announced on its own.
- **Keyboard:**
  - ⌘K focuses search, and ↑/↓ moves through the list.
  - ⌘I toggles the inspector.
  - Tab reaches capsules, and a focused capsule shows its readout.
  - The mic hold also works with Space held while the mic has focus.
- **Reduce Motion:** stops the breathing label and the typing dots.
- **Reduce Transparency:** turns off the glass, as the main window does.

---

## 10. Testing and delivery
- **Unit tests:**
  - `FirstMateBadge.count` for mixed hosts, duplicates, archived features, failed hosts and servers without the capability;
  - the dot rule;
  - the client-side status fallback and emoji hashing;
  - mention serialization and parsing, including plain-name matching edge cases;
  - read-marker rollback;
  - the server's fleet, read and hud routes, and the status and step mapping (as the HUD spec lists).
- **Demo mode:** extend `FirstMateDemo` to match the reference: seven features with emoji, needs-you and unread states, one agent message and one document card. Use synthetic names only.
- **Render tests:** the window at 1440 × 900 (lead and a blocked feature), 1000 pt (inspector overlay) and 700 pt (rail). The dusk is drawn by Herdr, so offscreen renders are representative. Still check once on screen before calling it done.
- **Focused checks while building:**
  - `.venv/bin/python -m unittest` on the touched test modules;
  - `xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`;
  - the targeted Swift tests.

  Run the full matrix once, on the final candidate.
- **Before every commit:** `.venv/bin/python scripts/check-public-source.py`. No AI attribution or Co-Authored-By lines.
- **Delivery:** the read markers and fleet summary need a companion server release as well as the Mac app. The Mac app must behave well against an older server, using the section 3 fallback. Don't push, open a PR, publish or deploy without asking.

---

## 11. Open decisions (use the default and list it in your report)
1. **Lead chat before Phase 2:** briefing plus a new-feature composer (default), or hide My First Mate until the lead exists.
2. **Mention wire format:** Markdown `herdr://` links (default). Confirm the coordinator doesn't choke on them; if it does, send `@Name` text and rely on name matching.
3. **Dock badge scope:** First Mate conversations only (default), or also agent sessions that need attention.
4. **Window shortcut:** ⌥⌘F (default) if nothing else uses it.
5. **Your turn vs ready for review:** use the HUD spec's split rule (open decision 2 there). The inspector's native status labels keep today's wording ("Your direction").
6. **When a chat counts as read:** visible in a key window and scrolled to the newest message (default), or simply opened.
