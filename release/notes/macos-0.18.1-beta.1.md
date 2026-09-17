# macOS 0.18.1-beta.1

## Dual Command detection fix

- Fixed the left-and-right Command shortcut so Herdr reads each Command key independently from macOS's combined-session key state.
- Press both Command keys while the HUD is enabled to capture the frontmost app window and stage its PNG in the separate **New chat** composer.
- Existing New chat text, attachments, selected machine, and working folder remain in place. The shortcut never sends automatically; release either Command key before pressing both again.

## Permission and compatibility

Screen Recording permission is still required to capture the window. The shortcut does not require Accessibility or Input Monitoring. If capture access is unavailable, open **Herdr Settings → Screen & System Audio Recording**, choose **Request Access** or **Open System Settings**, allow Herdr, then quit and reopen the app.

This Mac-only preview requires macOS 26 or later and does not require a companion server upgrade. The Mac updater does not install or restart companion server packages and does not update iPhone clients.

## Install and try it

In **Settings → App updates**, enable **Include preview builds**, then choose **Herdr Companion → Check for Updates…**. Review the update, confirm installation, and let Sparkle relaunch the app.

Enable the HUD, place a harmless app window in front, and press both Command keys together. Confirm **New chat** opens with the staged PNG while its draft remains unchanged, and confirm nothing is sent until you explicitly submit it.
