# Herdr Companion 0.45.0-beta.1

## A faster, calmer Dashboard and Agent view

Agent view no longer freezes. Each column used to re-download a First Mate's whole history, often 15–20 MB of agent telemetry, every few seconds, then sort it on the main thread. Columns now load a small, bounded board, skip polls when nothing changed, and prepare everything off the main thread. The full First Mate view also downloads only the journal it shows.

- **Agent view** columns fill the window, with the next one peeking in when there are more. Replies use compact type without nested bubbles, markdown renders properly, and agent telemetry never appears in the chat. One amber banner shows what a feature needs from you; **Reply** jumps to the composer. You can type a reply before a column finishes loading. Columns stay in place while you work. Open it with **⇧⌘A**.
- **Dashboard** cards size to the window (three wide cards with a fourth peeking in) and show plain-text previews with no stray `**` or `&amp;`. Cards are ordered by real conversation activity, and a First Mate that is parked until you reply now shows **Your turn**. PR Reviews collapses to one line when there is nothing to review, and you can choose the review host right there. Recent chats leave out PR Review worker sessions. **⌘F** searches everything.
- The home screen is quieter: no spinners or per-second timers, one color for "needs you," a single Dashboard button in the toolbar, and a sidebar that remembers whether you showed or hid it.
- Background polling no longer re-renders the app when nothing changed, and saved credentials are no longer re-read from Keychain on every screen update.

## Companion compatibility

Install companion **0.45.0b1** on each machine for the bounded board, journal-only snapshots, activity ordering, and **Your turn**. With older companions, the app still works: it falls back to less frequent snapshot polling, converted off the main thread. The Mac updater installs only the app.

## Install and verify

In **Settings → Updates**, enable **Include preview builds** if needed, then choose **Herdr Companion → Check for Updates…**. Open **Agent view** (⇧⌘A) with a long-running First Mate: columns should appear within a second or two, scroll smoothly, and show the conversation without telemetry rows. On the Dashboard, check that cards fill the window width and that Focus mode leaves only work waiting for you.

This is an Apple Development-signed preview distributed through the signed updater. It is not notarized.
