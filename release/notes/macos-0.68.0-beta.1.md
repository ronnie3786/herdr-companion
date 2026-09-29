# macOS 0.68.0-beta.1

## First Mate sidebar status

- In the standalone First Mate chat window, sending a prompt to a **Blocked**, **Your turn**, or **Ready for review** chat immediately switches its sidebar row to working: a breathing step word and **typing…**, with no status dot. The chat also leaves the “need you” count until First Mate replies; if the send is rejected, its waiting badge returns immediately. [Issue #111](https://github.com/ronnie3786/herdr-companion/issues/111) · [PR #114](https://github.com/ronnie3786/herdr-companion/pull/114).

## Companion compatibility

This is a Mac app-only presentation change; no companion update is required. The companion server, CLI, and Pi package are published separately and are not installed by the Mac updater.

## Install and verify

With preview updates enabled, install via **Settings → Updates → Check for Updates…**. In the standalone First Mate window, send a prompt from a waiting chat and confirm its sidebar row shows working without a dot or “need you” count; confirm the waiting badge returns after a reply or immediately if the send is rejected.
