# Dual Command window capture

With the Mac HUD enabled, press the left and right Command keys together to add a PNG of the frontmost app window to the HUD's separate **New chat** composer. One physical press creates at most one capture; release either key before using the shortcut again.

Herdr snapshots the frontmost app and its foremost visible normal window before opening the HUD. It captures only that window with ScreenCaptureKit, never a whole display or a fallback window. Existing New chat text, attachments, machine, and working-folder choices remain unchanged. The image stays staged until you explicitly send or remove it; the shortcut does not create a run, upload a file, or change the clipboard.

If you navigate to another HUD chat while capture is finishing, Herdr keeps that selection and stages the image in the original New chat composer. If that composer is submitted first, Herdr discards the late capture and shows an error on the fresh composer rather than attaching it to the submitted conversation. Turning off the HUD cancels an in-flight capture and removes its temporary file.

## Permission and troubleshooting

Screen Recording permission is required. Herdr checks existing permission without displaying an unexpected system prompt. If access is unavailable, open **Herdr Settings → Screen & System Audio Recording**, then choose **Request Access** or **Open System Settings**, allow the running Herdr app, and quit and reopen it. The shortcut does not require Accessibility or Input Monitoring.

If Herdr cannot identify a visible app window, bring the intended standard window to the front and try again. Desktop elements, hidden or transparent windows, nonstandard window layers, and windows smaller than 64 × 64 points are not capture targets.

This Mac-only feature requires macOS 26 or later and does not require a companion server update.
