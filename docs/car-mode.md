# Car mode on iPhone

A distraction-free surface for a mounted phone: the agents that need you or are
working now, one glanceable status line each, and oversized controls for the two
things you do while driving — hear a summary, and answer by voice. Car mode has
no keyboard anywhere.

## What it shows

Up to four agents, ranked the way a driver needs them:

1. **Needs you** — an agent that asked a question and cannot continue.
2. **Ready** — an answer waiting to be reviewed.
3. **Working** — actively running.
4. **Idle** — nothing new.

Newest first inside each rank. The pool is the same newest-twenty Recents window
the Agents tab uses, so the two surfaces never disagree about what "recent"
means, and identically named workspaces on different machines stay separate.
Shells and non-agent panes never appear. The cap is a setting (2, 4, or 6;
default 4).

Each card carries:

- The fleet status as a chip whose symbol changes with the status as well as its
  color, so a glance works without relying on color alone.
- **One line of context**, the most useful sentence available: the blocking
  question, the running step ("Editing Sources/Garden/SeedPicker.swift"), a
  failure, compaction, the opening line of the newest answer, or "You asked: …".
- **TL;DR** — plays the same server-side summary audio the chat offers
  (`response-audio/prepare` + `speech`). Preparing, playing, and paused states
  are reflected in the button.
- **Respond** — starts a spoken reply aimed at that agent.

Landscape turns the cards into wide rows so the same four agents stay readable on
a dash mount without squeezing the targets. Tapping a card opens the agent.

## The agent view

The newest answer as **rendered markdown** — the same parser and inline styling
the chat uses, so headings, bold and italic, inline code and links, bullet,
numbered and task lists, quotes, tables, and fenced code blocks all appear as
they do in the chat, at car-sized typography. Fenced code gets a monospaced,
horizontally scrollable panel with its language and line count; tables scroll
horizontally rather than squeezing columns. Soft line breaks from the agent's own
column width are reflowed to the phone's width so prose does not show ragged
mid-sentence breaks, and VoiceOver labels never contain markdown markers
("Bullet, Winter reading first", not "Bullet, asterisk winter reading asterisk").

Above it: the last thing you asked, a playback control, and a 96-point **Reply by
voice** target. There is no text field and no text selection, by design: the
markdown renderer deliberately omits selecting and copying, so the surface has no
editing affordances at all. If transcription fails you get a large retry.

## Spoken replies

1. **Tap once to start, tap again to finish.** Press-and-hold is unreliable on a
   dashboard mount, so the recorder always starts in its locked form.
2. Transcription runs through the same pipeline as the rest of the app — your
   private Parakeet server when configured, Apple Speech otherwise.
3. The transcript is shown in large type and **confirmed before sending** unless
   you turn that off in Settings. Speech recognition mishears, and an accidental
   steer into a working agent is expensive to undo.
4. Delivery mirrors the chat composer: a working agent is **steered**, a finished
   agent gets a normal **prompt**, and a pane without a semantic bridge falls
   back to terminal text.
5. Starting the microphone stops summary playback first, so the phone never
   transcribes its own audio.

## Entering and leaving

- **Agents tab header** → the car button.
- **Home Screen quick action** → "Car mode".
- **Deep link** → `herdr://car` (also `herdr://car-mode`, or `?car=1` on any
  `herdr://` link; `car=0` opts out).
- **Settings → Car mode** → the same button, plus the agent count, transcript
  confirmation, and screen-awake preferences.

Leaving restores the idle timer and drops any in-progress recording. The setting
**Keep screen awake** is on by default while Car mode is open, so a mounted phone
does not sleep between glances.

## Refresh behavior

Fleet status comes from the normal app refresh. Transcript detail is polled as
one-shot Pi snapshots every five seconds while Car mode is on screen and the app
is active — deliberately cheaper than opening four live event streams in a car —
and it pauses when the app leaves the foreground. An agent whose transcript
cannot be read keeps its card with the rest of its row intact.

## Not included

- **No automatic "you are driving" trigger.** Bluetooth A2DP cannot distinguish a
  car from headphones, and a driving surface that appears unasked is worse than
  one you request. Use the quick action or the deep link from a Shortcut.
- **No daylight surface.** Night-only for now; a light, high-contrast variant for
  bright cabins is still an open decision.
- **No spoken announcements** when an agent finishes. The card re-ranks and the
  haptic vocabulary fires; nothing is read aloud unprompted.

## Verification

- `CarModeSelectionTests` — ranking, the Recents window, the cap, machine
  separation, and the exclusion of shells.
- `CarModeSummaryTests` — every rung of the headline ladder, priority between
  them, and markdown flattening and truncation.
- `CarModeMarkdownTests` — the agent view's markdown rendering: bold, italic,
  inline code, and link markers resolve while their intent survives, soft wraps
  reflow, VoiceOver text stays marker-free, and the demo fixtures really do carry
  markdown so a rendering regression cannot pass silently.
- `CarModePreferencesTests` — defaults, persistence, normalization, reply
  disposition and routing, and the `herdr://car` link forms.
- `CarModeStoreTests` — snapshot-derived summaries, partial failures, player
  reuse across reorders, agent departure, the demo fixture path, and the whole
  voice flow including auto-send, failure, and cancellation.
- `CarModeRenderTests` — native renders of the card, detail, and voice layer at
  320/375/430 points and both standard and accessibility text, asserting the
  action targets never fall below 60 points, the status line stays readable, and a
  markdown-heavy answer (headings, table, quote, fenced block) keeps the code
  block and the 96-point voice target intact.
- `HerdrCarModeUITests` — demo-mode hierarchy: four cards, driving-sized targets,
  the voice-only detail, no typeable field or keyboard in the area Car mode
  occupies, and no visible raw markdown marker anywhere in the agent view.

Build the app, widget, and tests without signing:

```bash
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```
