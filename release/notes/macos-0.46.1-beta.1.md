# macOS 0.46.1-beta.1

## Floating chat HUD image drops

Dropping an image onto the floating chat HUD no longer crashes the app. Supported Finder files, raw image data, and system screenshot previews stage as attachments, one per dropped item, and stay staged until you explicitly send them. Drops over the prompt editor and onto the collapsed orb both work, repeated drop/remove cycles keep working, and the open draft and other chats are left unchanged ([#60](https://github.com/ronnie3786/herdr-companion/issues/60), [#62](https://github.com/ronnie3786/herdr-companion/pull/62)).

## Companion compatibility

This release updates the Mac app only. It uses the existing HUD chat attachment support, so no companion update is required. The companion server, CLI, and Pi package are published separately, and the Mac updater does not install or restart them.

## Install and verify

In **Settings → Updates**, enable **Include preview builds** if needed, then choose **Herdr Companion → Check for Updates…** and let the signed feed install the preview. Open the floating chat HUD and drag an image onto the card, including over the prompt editor, and onto the collapsed orb. Confirm the app stays responsive, each accepted drop adds exactly one attachment chip, and nothing is sent until you send it; repeat the drop/remove cycle a few times.

This preview is Apple Development-signed and distributed through the signed updater. It is not notarized.
