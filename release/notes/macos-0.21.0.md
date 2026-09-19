# macOS 0.21.0

## App Shots: reliable capture, and you can see what happens

Pressing the left and right Command keys together captures the frontmost app window into the HUD's
**New chat** composer. That shortcut used to fail silently — a shortcut that never fired looked
exactly like a capture that failed. Both halves are fixed, and every trigger is now visible.

- **A detected trigger is never silent.** The HUD shows **Capturing frontmost window…**, then
  **Screenshot added to New chat** or the actionable error. When the HUD panel was not on screen at
  the moment you pressed the keys, Herdr posts a macOS notification for the start and the outcome of
  that capture. The notification is a toggle in **Settings → HUD → App Shots**.
- **Two permission-free signals, checked independently.** Herdr reads the Quartz per-key state for
  the left Command key (55) and the right Command key (54) and the device-dependent modifier bits
  (`NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK`) of the combined-session flag table, and treats
  either one as a press. When Input Monitoring is already granted, a global `flagsChanged` monitor
  becomes the authoritative source. Herdr never asks for keyboard access by itself: **Settings → HUD
  → App Shots → Grant keyboard access…** is the only control that requests it.
- **Diagnostics that answer "is it detection or capture?"** Settings → HUD → App Shots shows a live
  readout of both Command keys and the signal that observed them, whether the shortcut and hot key
  registered, the last trigger's route/time/outcome, and a **Test capture now** button.
- **Four ways to capture.** ⌃⌥C, **File → Capture Frontmost Window**, **Capture frontmost window**
  in the orb's context menu, and the Settings test button all use the same path. The Carbon hot key
  needs no Accessibility or Input Monitoring permission at all.
- **The right window is captured.** When the HUD itself is frontmost, Herdr captures the last
  non-Herdr app you were using instead of its own panel.
- **The HUD no longer has to be on** for the shortcut to work: a trigger turns it back on and stages
  the image. Turning the HUD off still cancels an in-flight capture.

Screen Recording permission is still required for the window image and is unchanged. Accessibility
is never required.

## Screenshot previews can be dropped straight into the HUD

Dragging the temporary thumbnail from the system screenshot preview into the HUD previously did
nothing — that drag is a macOS *file promise*, not a real file, and the HUD only accepted files that
already existed on disk (which is why saving to the Desktop first worked). The HUD now materializes
promised files, so the thumbnail can be dropped on the open chat or the collapsed orb without saving
it first. Files from Finder and image data from browsers behave exactly as before, including the
4-attachment, 20 MB, and 21 MB limits.

## Updates are visible in the window

- A newer release now shows as a **clickable version badge in the window's top bar**, so updating no
  longer starts from the menu bar. **Later** on the banner hides the banner only; the badge stays
  until the update is installed or superseded.
- **Background checks run every ten minutes** while Herdr is running, with the first about two
  minutes after launch. Sparkle's own scheduled timer cannot go below an hour; Herdr asks for a
  background check on its own cadence instead, and still never downloads or installs anything
  without your explicit confirmation.
- **Preview builds are now included by default** for a build with no stored preference. Every
  published Herdr release is currently on the preview channel, and a stable-only setting filtered
  the entire feed away — a fresh install could never see an update at all. Turn the toggle off in
  **Settings → Updates** to stay on stable releases only.
- **Settings → Updates** shows the active channel, the cadence, and the last and next check.

## Install

This is a **stable-channel** release: it is offered to every installed Herdr app, including builds
that have preview builds turned off. Choose **Herdr Companion → Check for Updates…**, review the
update, and let Sparkle install and relaunch.

This release changes only the Mac app. The companion server, CLI, Pi package, and iPhone/iPad apps
are unaffected, their API contracts are unchanged, and no server update is required. Use ⌃⌥C or
**File → Capture Frontmost Window** to try App Shots even before granting any new permission.

This preview uses Apple Development signing and is **not notarized**. It may require normal macOS
approval on first installation; do not disable Gatekeeper or other protections.
