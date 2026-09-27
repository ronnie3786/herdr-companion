# Herdr Companion 0.52.1-beta.1

## HUD chat skims land, and the header stays still

A long HUD chat answer now switches from **Skimming…** to its skim a few seconds
after it finishes. In 0.52.0 the answer could stay on **Skimming…** until the
chat was reopened, and while it waited the header status flickered between
**Done** and **Loading…**.

- A skim that lands after its answer, or later on an earlier turn, now shows up
  in an open chat without reopening it.
- While a skim is being written, only that answer is checked again; the chat's
  history is not reloaded.
- Background checks of an open chat no longer show **Loading…** or briefly
  disable its buttons unless something actually changed. A chat you open while
  a check is in flight shows the chat you opened.

This build also includes everything in 0.52.0-beta.2, including the dusk glass.

## Compatibility and installation

Install this preview through **Herdr Companion → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

This fix is in the Mac app only; no companion change is needed. Skims still come
from a companion advertising `first-mate-skim-v1` (0.52.0b1 or later).

## Check the changes

- Ask a HUD chat something with a long answer and keep the card open. Expect
  **Skimming…**, then the skim within a few seconds.
- Watch the header status while the card stays open: it keeps showing **Done**
  and never flickers to **Loading…**.
