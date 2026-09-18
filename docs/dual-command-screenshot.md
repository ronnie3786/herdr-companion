# App Shots: window capture from the Mac HUD

Press the left and right Command keys together to add a PNG of the frontmost app window to the
HUD's separate **New chat** composer. Herdr reads each Command key independently rather than the
generic Command bit, so one physical press creates at most one capture; release either key before
using the shortcut again. Turning the HUD off no longer disables the shortcut: a trigger enables
the HUD and stages the image in a new chat.

Herdr snapshots the frontmost app and its foremost visible normal window before opening the HUD,
and prefers the last non-Herdr app when the HUD itself is frontmost, so pressing the shortcut
while the panel has focus still captures what you were looking at. It captures only that window
with ScreenCaptureKit, never a whole display or a fallback window. Existing New chat text,
attachments, machine, and working-folder choices remain unchanged. The image stays staged until you
explicitly send or remove it; the shortcut does not create a run, upload a file, or change the
clipboard.

If you navigate to another HUD chat while capture is finishing, Herdr keeps that selection and
stages the image in the original New chat composer. If that composer is submitted first, Herdr
discards the late capture and shows an error on the fresh composer rather than attaching it to the
submitted conversation. Turning off the HUD cancels an in-flight capture and removes its temporary
file.

## Every trigger is visible

A detected trigger is never silent. Herdr shows a notice on the HUD for the whole capture —
**Capturing frontmost window…**, then **Screenshot added to New chat** or the actionable error — and,
when the HUD panel was not on screen at the moment of the trigger, posts a macOS notification for
both the start and the outcome of that capture. The notification is controlled by
**Settings → HUD → App Shots → Notify when a capture starts or fails** and only ever uses
notification permission you already granted; the capture path never raises a permission prompt of
its own.

## Detection signals and diagnostics

Herdr combines two permission-free signals and treats either one as a press:

- the Quartz per-key state for the left Command key (55) and the right Command key (54);
- the device-dependent modifier bits (`NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK`) of the
  combined-session flag table, which AppKit's `modifierFlags` masks out.

When **Input Monitoring** is already granted, a global `flagsChanged` monitor becomes the
authoritative source and the polls act as its cross-check. Herdr never requests keyboard access on
its own: **Settings → HUD → App Shots → Grant keyboard access…** is the only control that asks, and
it is a deliberate click.

Settings → HUD → App Shots shows what is actually happening:

- a live readout of both Command keys and the signal that most recently observed a press — hold one
  Command key and watch it change;
- whether the shortcut and the ⌃⌥C hot key registered;
- the last trigger's route, time, and outcome;
- **Test capture now**, which runs the real capture path.

## Permission and troubleshooting

Screen Recording permission is required for the window image, but not for detecting the two Command
keys. Herdr checks existing permission without displaying an unexpected system prompt. If access is
unavailable, open **Herdr Settings → Screen & System Audio Recording**, then choose **Request
Access** or **Open System Settings**, allow the running Herdr app, and quit and reopen it.
Accessibility is never required.

If the live readout never changes while you hold a Command key, grant keyboard access, or use one of
the routes below. If Herdr cannot identify a visible app window, bring the intended standard window
to the front and try again. Desktop elements, hidden or transparent windows, nonstandard window
layers, and windows smaller than 64 × 64 points are not capture targets.

## Capture without the chord

Four equivalent routes use the same capture path and need no keyboard permission:

- **⌃⌥C**, a Carbon hot key that works while any app is frontmost;
- **File → Capture Frontmost Window**;
- **Capture frontmost window** in the HUD orb's context menu;
- **Test capture now** in Settings.

## Dropping screenshots instead

A file that already exists on disk can be dragged into the open HUD chat or the collapsed orb. The
same drop target now also accepts a drag straight out of the system screenshot preview: that drag is
a macOS *file promise* rather than a real file, and Herdr materializes it through
`NSFilePromiseReceiver` before validating and storing it. Image data dragged from a browser or
editor keeps working, and validated limits (4 attachments, 20 MB each, 21 MB combined) are
unchanged.

This Mac-only feature requires macOS 26 or later and does not require a companion server update.
