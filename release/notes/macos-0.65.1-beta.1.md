# macOS 0.65.1-beta.1

## Completion sounds

Fixed the misleading agent-finished chime when a chat starts and duplicate chimes on completion. The Mac companion now plays one completion cue; notification banners remain silent. Sound settings for a separately installed upstream Herdr app are configured independently. [Issue #85](https://github.com/ronnie3786/herdr-companion/issues/85) · [PR #94](https://github.com/ronnie3786/herdr-companion/pull/94)

## Companion compatibility

No companion server update is required for this fix. This release updates the Mac app only; the companion server, CLI and Pi package are published separately.

## Install and verify

With previews enabled, install through **Settings → Updates → Check for Updates…**. Start a chat and confirm no completion chime plays; finish a chat and confirm exactly one completion cue, with no sound from notification banners.
