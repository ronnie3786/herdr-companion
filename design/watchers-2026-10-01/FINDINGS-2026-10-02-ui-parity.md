# Findings, 2026-10-02: Mac UI parity with the approved prototype

A layer on top of the plan and earlier findings. It records what was measured and
changed when the shipped Watchers screen was brought to the approved
`avatars-v1-chips.html` ("Dusk glass"); treat it as reference, not a spec.

## How it was compared

- The prototype was captured headless at 1440×900 and 1280×800 (2×), with element
  boxes and computed styles read from the DOM, so the Swift values are measured,
  not estimated. CSS pixels map 1:1 to points.
- `WatchersWindowRenderTests` renders the production window (sidebar, title bar,
  dusk) against a stub companion serving the prototype's twelve sample watchers in
  the list payload's shape, plus tall content renders at 1520, 1190, 880 and 600.
- **Offscreen renders cannot show SwiftUI color filters.** The harness snapshots with
  `cacheDisplay`, which skips Core Animation filters, so `.saturation` and
  `.colorMultiply` on resting avatars look unfiltered there. On screen they work; check
  resting avatars on screen (a demo build with `-HerdrDemoMode -HerdrWatchersDemo`
  under its own bundle identifier) rather than trusting the PNG.

## What was off, and the rule now in code

- Summary lines were 26pt with chips and about 21pt without. `WatcherSummaryLayout`
  now places every run in fixed `size × 2` line boxes with a CSS-style baseline.
- The first story line began 24pt below the "who" line instead of 18pt. The status row
  sat at the card's inset instead of reaching 8pt into it (CSS `margin: 0 -8px`), and
  status text was 10pt instead of 9pt.
- Avatar drawings had 5% padding and a translucent face. The prototype fills an opaque
  `color-mix(tone 15%, #211E28)` face clipped to its shape. `bolt` and `atlas` were
  missing their periwinkle tone.
- Chips used one tint for text, wash and border, colored inbox text with the accent,
  and used SF symbols where the prototype has First Mate's mini face and a bare
  terminal prompt. Per-kind fills, strokes and text now follow `v2-core.css`.
- Asset-catalog SVG ignores CSS `transform` in `style` attributes, so the gauge needle
  and metronome arm drew upright. `export-avatars.cjs` now writes SVG `transform`
  attributes, and a test keeps `style=` out of the drawings.
- System `.pink` and `.mint` replaced the theme's rose and mint. "Needs you" appeared as
  a card status, although the prototype shows attention only through the alert line
  (and the plan's "!" flag).
- Breakpoints: the prototype keys on the viewport beside a 168pt rail. `WatchersMetrics`
  keys on the detail column, so 1190 and 1650 become 1022 and 1482. The column
  thresholds (950, 650) are unchanged.

## Deliberate differences

- The avatar keeps the "!" attention flag from the plan's design table. The prototype's
  `card()` never passes `flag`, but `.av-flag` defines how it looks.
- Inbox and New watcher sit in the window title bar. The prototype's toolbar has no
  inbox. New watcher keeps its two-item menu (agent or manual setup) instead of opening
  the builder directly.
- The prototype's simulated parts (clock, time-based progress, one run at a time) are
  not reproduced. Progress is steps done.
