# macOS 0.70.1-beta.1

## Longer First Mate conversation names

First Mate conversation names entered in the Mac chat window’s rename sheet or the HUD rename card can now be up to 100 characters instead of 24. [Issue #118](https://github.com/ronnie3786/herdr-companion/issues/118) · [PR #120](https://github.com/ronnie3786/herdr-companion/pull/120).

## Companion compatibility

This release updates the Mac app only. Names longer than 24 characters require the matching companion package; older companions reject them with an error shown in the rename sheet. The companion server, CLI, and Pi package are published separately and are not installed by the Mac updater.

## Install and verify

With preview updates enabled, install via **Settings → Updates → Check for Updates…**. Rename a First Mate conversation to a name between 25 and 100 characters in the Mac chat window or HUD; with a matching companion, confirm the new name is saved. With an older companion, confirm the rename sheet shows the rejection error.
