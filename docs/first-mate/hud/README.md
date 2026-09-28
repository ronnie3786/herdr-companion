# First Mate HUD (Mac)

A floating First Mate panel that is separate from the agent HUD: First Mate's face with your First Mate features under it. [BUILD-SPEC.md](BUILD-SPEC.md) is the design spec and [reference.html](reference.html) is the playable prototype, made with synthetic data.

## Turn it on and off

The HUD has its own switch, place, and state; the agent HUD is unchanged. Turn it on or off in either place:

- **View → Show First Mate HUD** / **Hide First Mate HUD**
- **Settings → HUD → First Mate HUD**

Right-clicking the face also offers **Hide First Mate HUD**.

It is on by default, but it only appears once a connected companion answers with First Mate. In demo mode it appears only when you ask for it, by setting the switch or passing `-HerdrFirstMateHudDemoCount`, so UI tests and demo recordings stay clear.

## What Phase 1 does

- **Face.** An 86 pt First Mate face that blinks and looks toward the pointer. Its count badge is the number of features that need you, in the color of the most urgent one.
  - Click it to type.
  - Press and hold it for 0.42 s to talk; let go to send.
  - Drag it to move the whole HUD.
- **Collapsed row.** Up to six orbs, the last one "+N" when more features are running. Features that need you are never tucked behind "+N".
- **Expanded list.** The list hangs from a lit line:
  - features that need you come first, ordered blocked, your turn, then ready;
  - a diamond marks the break, then moving features follow in start order;
  - with more than four moving features, three show and a summary row shows or hides the rest as compact rows.
- **Hover a row or orb** to see its readout: title, status, the "now" line, six labeled step bars, progress, **Open session**, and **Read message** or **Ask First Mate**.
- **Read a message.** Click an orb that has an unread dot, or a row's speech bubble, to open the newest message. The card has a reply box and a hold-to-talk mic that goes straight to that feature. Opening the card marks the message read, on this Mac and on the companion.
- **Talk or type to First Mate.**
  - "What needs me?" and similar questions get an answer built from the fleet summary.
  - Words that name a feature are posted to that feature as your message.
  - Anything else gets a plain "I couldn't tell which feature that's for."
- **Open session.** It opens the First Mate chat window on that feature when the window's preview is on, otherwise the main window's First Mate screen.
- **Rename.** Right-click a row or orb to change its label (24 characters at most) or its emoji. This uses `POST /features/{id}/hud`.
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
- **Phase 2 and Phase 3 are not built:** the lead First Mate, and motion extras such as signals, the scan beam, and drag-to-ask.

## Data and polling

The HUD adds no server API. It reads the process-wide First Mate fleet index, which uses `first-mate-fleet-v1` from companion 0.54.0b1, the same data as the chat window and the Dock badge.

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
- **Tests:** `herdr-harness-macTests/FirstMateHudTests.swift` (rules and geometry) and `FirstMateHudRenderTests.swift` (offscreen renders).
- **Demo:** launch with `-HerdrDemoMode -HerdrFirstMateHudDemoCount 6|10|14`.
