# Herdr Companion 0.8.1-beta.1

## Paste code fixes

- Fixed the HUD crash when using **Paste code** or **Command-Shift-V**. Native text insertion no longer overlaps an exclusive write to the observable draft.
- Fixed the Paste code button losing its insertion during a SwiftUI update. Both button and shortcut now edit after that transaction finishes, through the same safe path.
- Paste targets the originating composer, even when clicking the button changes focus. An unrelated field with matching text cannot receive the clipboard content.
- The fenced block still appends after the entire draft without replacing selected text. The caret moves to the end, the editor scrolls to it, and native undo/redo works. Clipboard whitespace and embedded fences remain intact.

## Synchronized HUD labels

All session bubbles now switch between **model** and **cost** together every five seconds, using one shared clock. Newly mounted, revealed, or recreated bubbles immediately join the current phase; fetching metadata no longer starts an independent timer. If one value is missing, that phase shows an honest placeholder instead of the opposite label type. Reduce Motion still disables the fade.

## Test this update

1. In both Chat and HUD, type a draft and select some of it. Click **Paste code**, then repeat with **Command-Shift-V**. Each action should append once, preserve the original draft, and not crash.
2. Undo and redo the paste. Try the button after moving focus away from the prompt; the correct composer should still receive the fenced text.
3. Watch several HUD bubbles for at least ten seconds. Their model/cost label types should switch together. Reveal more sessions or start another one and check that it joins the same phase.

Verified with 1,054 Mac tests, including real composer mouse/keyboard actions, focus changes, undo/redo, rendered labels, and late/recreated rows on the live shared clock.

Enable preview builds and choose **Herdr Companion → Check for Updates…**. Mac-only patch; no server, Pi-extension, or iOS deployment is required. Bundle, Keychain, preferences, and signed update identities are unchanged. Personal-testing preview, development-signed and not notarized; signed update verification remains enabled.
