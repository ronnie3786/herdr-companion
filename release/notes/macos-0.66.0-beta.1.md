# macOS 0.66.0-beta.1

## HUD morph and hover

The ultra-compact resting circle now morphs in place into the orb and agent chips, and back. With Reduce Motion enabled, it snaps in both directions. A resting HUD expanded by hover stays open for two seconds after the pointer leaves; re-entering any HUD control cancels the collapse. The panel keeps the orb's frame until the circle lands. Other HUD modes retain their short hover grace. [Issue #95](https://github.com/ronnie3786/herdr-companion/issues/95) · [PR #109](https://github.com/ronnie3786/herdr-companion/pull/109)

## Companion compatibility

No companion update is required. This release updates the Mac app only; the companion server, CLI and Pi package are published separately.

## Install and verify

With previews enabled, install through **Settings → Updates → Check for Updates…**. Hover over the resting circle and confirm it morphs into the orb and chips; leave and re-enter a HUD control within two seconds to confirm it stays open. Let it collapse and confirm the panel holds its frame until the circle lands. Enable Reduce Motion and confirm both transitions snap.
