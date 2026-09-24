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

## Dropping screenshots and files instead

The open HUD card and the collapsed orb are drop targets for files and images. AppKit resolves the drop
to one destination and the HUD imports it through one validated path, so a drag that carries several
representations cannot attach twice:

- a file that already exists on disk keeps its real path and filename;
- raw image data dragged from a browser, editor, or screenshot tool is staged from the pasteboard's own
  PNG, JPEG, TIFF, or other declared image representation, so AppKit's synthesized conversion never
  replaces the original bytes;
- a drag straight out of the system screenshot preview is a macOS *file promise* rather than a real file,
  and Herdr materializes it through `NSFilePromiseReceiver` before validating and storing it;
- a browser image drag that also carries the image's web URL still attaches the pixels; only real file
  URLs take the file path, so the URL never shadows the image data;
- a drop over the prompt editor counts too. It becomes an attachment instead of inserting the file path
  as draft text;
- a drag with several items keeps one attachment per item: two image items each import their own bytes,
  and a file item no longer hides an image item beside it. A single item that advertises several image
  representations still attaches only once, using its lossless-preferred representation.

Each dropped item is copied into the session's durable attachment store before its staging copy is
removed, so the attachment stays readable after the source file is deleted. Promised files of one drop
share one staging directory, and that directory is removed only after every receiver has delivered
every promised file; a receiver that finishes first cannot delete files a sibling is still writing,
and one failed promise does not remove a sibling's delivery. Dropping never starts a run
or uploads anything: the composer waits for an explicit send. A card drop belongs to that chat; a
dropped item on the collapsed orb opens the HUD on the separate **New chat** composer. Removing an
attachment deletes its durable copy, and another chat never receives the dropped image.

Validated limits (4 attachments, 20 MB each, 21 MB combined) are unchanged. An unreadable file, an
empty or oversized image, an unsupported type, or a failed promise reports a recoverable error and
leaves the existing draft and attachments intact.

This Mac-only feature requires macOS 26 or later and does not require a companion server update.

### Regression checklist

Automated Mac regression tests cover the production drop callbacks with synthetic pasteboards and
promised files: real encoded PNG/JPEG/TIFF fixtures, Finder file URLs, raw provider data with
asynchronous background completions, PNG/TIFF/JPEG pasteboards, browser URL-plus-image drags,
multi-item pasteboards that mix files and images, successful and failed promises, delayed promise
siblings, a failure beside an awaiting sibling delivery, a multi-file promise, three consecutive
drop/remove cycles, durable bytes after the source is removed, explicit submission, one import per
item, target-state reset, session isolation, and the existing 4-file, 20 MB, and 21 MB limits. A
dropped image is also rendered through the composer's attachment chip so its thumbnail path is
exercised.

Perform these checks against an installed build before publishing; they exercise the real drag system
that unit tests cannot drive:

1. Drag a Finder PNG and a Finder JPEG onto the open HUD card; drag one over the prompt editor
   specifically. Each drop adds one attachment chip with a usable thumbnail and leaves the app
   responsive.
2. Drag an image out of a browser into the card. The image attaches; no error is shown and the
   editor's draft is unchanged.
3. Open the system screenshot preview and drag its thumbnail into the card, then repeat onto the
   collapsed orb. The first stages in the current chat, the second opens the HUD on **New chat**.
4. Repeat drop/remove three times in a row without restarting the HUD. Every cycle accepts, shows one
   chip, remains editable, and removal clears the chip.
5. Type a draft and add an attachment, then drop another image. The draft and the first attachment stay
   untouched, and a second chat shows no attachment.
6. Remove an attachment, drop the same image again, and explicitly send. One run starts only after the
   send, and the attachment is still readable in the sent turn.
7. Try a text drag, a web link, an unsupported file, and an oversized image. Nothing highlights the HUD
   for text or a link, and the unsupported or oversized item reports an actionable error without losing
   the draft.

**Installed-UI status:** the real-drag checks above were not run in this environment; they are pending
until an installed build is exercised. The automated Mac regression suites named above did run.
