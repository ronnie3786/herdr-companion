# macOS 0.75.0-beta.1

First Mate can show the iOS Simulator builds its agents save along the way, and open
any of them in a live simulator window.

- A feature's **Builds** section lists **simulator checkpoints** next to its Mobile
  App Hub builds, with the checkpoint label, app version, stage, and the agent that
  saved it. A Mobile App Hub build with a simulator copy gets **Open in Simulator**
  right under it. In **Workflow**, a stage that saved builds gets a **Simulator** chip
  (a menu when it has several).
- **Open in Simulator** opens a native window for that exact build. It shows the
  feature, its machine, the checkpoint, and the app version on top, SimPortal's start
  steps while a simulator starts, and the screen as soon as iOS boots, while the app
  is still installing. Tap, drag, scroll, type, paste (⌘V), and use Home (⇧⌘H) and
  Lock (⌘L). Opening the same build again shows the running simulator.
- The window never changes SimPortal's focused simulator. **Open in Browser** opens
  that exact simulator's page in SimPortal and asks first, because SimPortal's browser
  viewer does make it the focused simulator.
- Closing the window doesn't stop anything. **Shut Down** stops the simulator now,
  keeping its data. Otherwise the companion shuts it down after an hour with no
  viewer, and a hidden window pauses its picture after a minute. Up to four Herdr
  simulators run per machine; opening a fifth shuts down the one watched least
  recently.
- A simulator deleted on SimPortal's **Machines** page shows as **Simulator deleted**,
  with its build kept. **Start Again** opens a fresh simulator.

Requires companion **0.68.0b1** (`first-mate-simulator-previews-v1`), SimPortal on
the machine that compiles the builds, and a `[simportal]` section in that companion's
private configuration. Without them nothing new appears. The Mac updater does not
install companion packages.

With preview updates enabled, use **Settings → Updates → Check for Updates…**. Then
open a First Mate feature whose agents saved a simulator build, go to **Overview →
Builds**, and choose **Open in Simulator**. Demo mode (`-HerdrDemoMode`) shows
synthetic checkpoints and a synthetic simulator window.
