# First Mate HUD (Mac)

A floating First Mate panel that is separate from the agent HUD: First Mate's face with your First Mate features under it. [BUILD-SPEC.md](BUILD-SPEC.md) is the design spec and [reference.html](reference.html) is the playable prototype, made with synthetic data.

## Turn it on and off

The HUD has its own switch, place, and state; the agent HUD is unchanged. Turn it on or off in either place:

- **View → Show First Mate HUD** / **Hide First Mate HUD**
- **Settings → HUD → First Mate HUD**

Right-clicking the face also offers **Hide First Mate HUD**.

It is on by default, but it only appears once a connected companion answers with First Mate. In demo mode it appears only when you ask for it, by setting the switch or passing `-HerdrFirstMateHudDemoCount`, so UI tests and demo recordings stay clear.

## What it does

- **Face.** An 86 pt First Mate face that blinks and looks toward the pointer. Its count badge is the number of features that need you, in the color of the most urgent one.
  - Click it to open the chat with the [lead First Mate](../lead.md).
  - Press and hold it for 0.42 s to talk; let go to send your words to the lead.
  - Drag it to move the whole HUD anywhere on screen—left, right, middle, up or down. It stays exactly where you drop it, only adjusting to keep the face whole on screen.
  - First Mate's latest line opens right beside the face, above the collapsed orb row. Near the top of the screen, it opens past the row instead so it never covers the orbs.
- **Collapsed row.** At most six orbs. With more features, the five most urgent show and the sixth becomes "+N", even when more than five need you; "+N" carries their unread dot and lists them on hover, and the face's badge still counts every one.
- **Expanded list.** The list hangs from a lit line:
  - features that need you come first, ordered blocked, your turn, then ready;
  - a diamond marks the break, then moving features follow in start order;
  - at most six rows: with more features, five show and a summary row ("4 more · 2 need you") shows or hides the rest, all as compact rows.
- **Hover a row or orb** to see its readout: title, status, the "now" line, six labeled step bars, progress, **Open session**, and **Read message** or **Ask First Mate**.
- **Read a message.** Click an orb that has an unread dot, or a row's speech bubble, to open the newest message. The card has a reply box and a hold-to-talk mic that goes straight to that feature. Opening the card marks the message read, on this Mac and on the companion.
- **Talk or type to First Mate.** With a companion advertising `first-mate-lead-v1`, the chat is the lead First Mate's real, continuing conversation, in the chat window's bubbles with skims, and the same prompt composer as every other chat: attach, paste, code paste, voice, the model pill, and the context line. **Open in window** shows it in the First Mate chat window. A spoken message goes to the lead, and its answer shows beside the face when it lands; click it to open the chat. The lead lives on this Mac's own companion and reaches your other machines itself; while that companion is offline, another machine's lead stands in and the card's header says which machine is offline.
- **Failed sends keep your words.** A connection failure can happen after transcription succeeds, because transcription and the destination conversation use separate requests and can use different services. If opening the lead or sending fails, the HUD shows a persistent recovery card naming the destination and keeping the transcript, with **Retry send**, **Copy text**, and **Discard**. Closing the card or hiding the HUD does not discard it; click the face to reopen it. New recordings cannot replace an unresolved send. Recovery stays in memory while the app runs, not across relaunches. A retry uses the original machine, conversation, payload, and message request ID even if the fleet has selected another lead. Changing or removing that connection stops retries and leaves the text copyable. Neither reconnecting nor polling resends automatically. This Mac fix uses the existing APIs and needs no server update.
- **Without a lead** (older companions), the chat answers locally:
  - "What needs me?" and similar questions get an answer built from the fleet summary.
  - Words that name a feature are posted to that feature as your message.
  - Anything else gets a plain "I couldn't tell which feature that's for", with one of your own features as the example.
- **Open session.** It opens the First Mate chat window on that feature when the window's preview is on, otherwise the main window's First Mate screen.
- **Rename.** Right-click a row or orb to change its label (100 characters at most) or its emoji. This uses `POST /features/{id}/hud`.
- **Esc** steps back one layer at a time: the editor, then listening, then a card, then the chat, then the list.

## How it differs from the spec

- **It follows the approved First Mate chat window design:**
  - the chat window's violet emoji discs, status colors and words;
  - flat unread dots instead of a dashed spinning ring;
  - no corner brackets or leader lines on cards.
- **Status labels are still.** They do not breathe on the HUD, so nothing redraws while idle except the blink.
- **Some readout fields are left out:** time in the current step, agents, and pull request. The fleet summary does not carry them, and the HUD never fetches full snapshots.
- **No one-tap reply buttons.** The fleet summary has no reply choices.
- **No live words while you talk.** The HUD shows "Listening…" with a waveform, then the words it heard for half a second before sending, because the transcription pipeline returns only the final text.
- **No global push-to-talk hotkey.** ⌃⌥Space still belongs to the agent HUD.
- **Overflow is a hard cap.** The spec kept every feature that needs you on its own orb and row; with many of them that overwhelmed the HUD, so needs-you features are tucked past the fifth too.
- **Phase 2 is built** as the [lead First Mate](../lead.md). **Phase 3 is not:** motion extras such as signals, the scan beam, and drag-to-ask.

## Data and polling

The HUD reads the process-wide First Mate fleet index, which uses `first-mate-fleet-v1` from companion 0.54.0b1, the same data as the chat window and the Dock badge. The lead chat uses `first-mate-lead-v1` from companion 0.56.0b1: the fleet index polls the lead's small summary, and the chat card keeps its own store for the lead, refreshed every 2 s only while it shows.

- **Polling:** every 10 s while the HUD shows, even when another app is in front. Otherwise the fleet polls every 10 s while Herdr is the active app and every 30 s in the background.
  - The spec asks for 5 s, but each poll also fetches every machine's full feature list, not just the summary.
- **Older companions:** without the capability, the HUD falls back to the feature list, like the chat window does. A feature that needs you counts as unread, steps are unknown, and emoji are picked on this Mac.

## Code

- `herdr-harness-mac/herdr-harness-mac/FirstMate/Hud/`:
  - `FirstMateHudModel.swift`: order, overflow, badge, routing and spoken labels, all pure.
  - `FirstMateHudGeometry.swift`: the panel's layout around a fixed face point, pure.
  - `FirstMateHudController.swift`: the panel, state and actions.
  - the views.
  - `FirstMateHudDemo.swift`: the synthetic demo fleet.
- **Tests:** `herdr-harness-macTests/FirstMateHudTests.swift` (rules and geometry), `FirstMateHudPlacementGeometryTests.swift` (face-hugging cards, top-edge fallback, and panel-to-face conversion), `FirstMateHudControllerPlacementTests.swift` (free drag placement, late moves, and programmatic-move guards), `FirstMateHudRenderTests.swift` (offscreen renders), and `FirstMateHudDeliveryTests.swift` (connection refusal before opening a lead, uncertain sends, exact-request retry, duplicate suppression, cancellation, connection changes, feature replies, fleet fallback, and recovery-card rendering).
- **Demo:** launch with `-HerdrDemoMode -HerdrFirstMateHudDemoCount 6|10|14`.
