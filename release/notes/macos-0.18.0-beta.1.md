# macOS 0.18.0-beta.1

## Dual Command window capture

- Press left and right Command together while the HUD is enabled to capture the frontmost app's foremost visible window and add a PNG to the separate **New chat** composer.
- Existing New chat text, attachments, selected machine, and working folder remain in place. The capture is staged only: Herdr does not send a run, upload automatically, replace the clipboard, or attach to the selected saved chat.
- One physical chord creates at most one capture. Switching HUD chats while capture finishes keeps your selection; submitting the original New chat first safely discards the late image instead of attaching it to the submitted conversation.
- Screen Recording permission is required. The shortcut does not require Accessibility or Input Monitoring. If needed, open **Herdr Settings → Screen & System Audio Recording**, then choose **Request Access** or **Open System Settings**.

## Compatibility and limits

This Mac-only preview requires macOS 26 or later and no companion server update. Herdr captures only the selected app window through ScreenCaptureKit, never a whole display or fallback window. Hidden, transparent, tiny, desktop, and nonstandard-layer windows are excluded.

## Install and try it

In **Settings → App updates**, enable **Include preview builds**, then choose **Herdr Companion → Check for Updates…**. Review the update, confirm installation, and let Sparkle relaunch the app. Signed update verification remains enabled. This preview uses Apple Development signing and is not notarized; normal macOS approval may be required on first installation.

Enable the HUD, place a harmless app window in front, and press both Command keys together. Confirm **New chat** opens with a PNG alongside any existing draft and attachments, then explicitly remove or send it. Hold the keys to confirm there is no repeat, release either key, and press both again for a second capture. Also verify that switching to a saved HUD chat during capture does not steal focus.

The Mac updater does not install or restart companion server packages and does not update iPhone clients.
